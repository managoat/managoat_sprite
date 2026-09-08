"""Host-side, resumable Sprite provisioning using the operator's Sprite CLI login."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

RELEASE = '0.1.0'
SAFE_NAME = re.compile(r'[a-z0-9][a-z0-9-]{0,62}')
ENV_NAME = re.compile(r'[A-Z_][A-Z0-9_]*')
RESERVED_ENV = {'HOME', 'PATH', 'SHELL', 'USER', 'LOGNAME', 'TMPDIR', 'ENV', 'BASH_ENV',
                'CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'NODE_OPTIONS', 'PYTHONPATH', 'PYTHONHOME',
                'LD_PRELOAD', 'LD_LIBRARY_PATH', 'SPRITE_TOKEN', 'SPRITES_TOKEN', 'SPRITES_API_URL'}


def fail(code, detail):
    raise RuntimeError(f'{code}: {detail}')


def private_write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.parent.chmod(0o700)
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as file:
            os.fchmod(file.fileno(), 0o600)
            file.write(value)
            file.flush()
            os.fsync(file.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def save(path, value):
    private_write(path, json.dumps(value, sort_keys=True, indent=2) + '\n')


@contextlib.contextmanager
def lock(directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    with (directory / 'operation.lock').open('a') as file:
        try:
            fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            fail('provision_busy', 'another provisioning operation owns this Sprite')
        yield


def fields(value, allowed, label):
    if not isinstance(value, dict) or value.keys() - set(allowed):
        fail('invalid_config', f'{label} must be an object with only supported fields')


def text(value, label):
    if not isinstance(value, str) or not value.strip() or '\x00' in value:
        fail('invalid_config', f'{label} must be a nonempty string without NUL bytes')
    return value


def load_config(path):
    path = Path(path).resolve()
    try:
        c = json.loads(path.read_text())
    except (OSError, ValueError):
        fail('invalid_config', 'cannot read the JSON configuration file')
    fields(c, ['name', 'org', 'release', 'agent', 'workspace', 'repository', 'env',
               'bootstrap', 'bootstrap_timeout_seconds', 'url_auth', 'cors_origins', 'port'], 'configuration')
    for key in ('name', 'org'):
        if not SAFE_NAME.fullmatch(text(c.get(key), key)):
            fail('invalid_config', f'{key} must contain lowercase letters, digits, or hyphens')
    # An explicit setting in the file makes platform exposure part of the request.
    if c.get('url_auth') not in ('public', 'sprite'):
        fail('invalid_config', 'url_auth must explicitly be public or sprite')
    c.setdefault('release', RELEASE)
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?', text(c['release'], 'release')):
        fail('invalid_config', 'release must be a version without a v prefix')
    c.setdefault('workspace', '/home/sprite/project')
    workspace = PurePosixPath(text(c['workspace'], 'workspace'))
    if not workspace.is_absolute() or '..' in workspace.parts or workspace in (PurePosixPath('/'), PurePosixPath('/home/sprite')):
        fail('invalid_config', 'workspace must be an absolute project directory')
    if workspace == PurePosixPath('/home/sprite/.local') or PurePosixPath('/home/sprite/.local') in workspace.parents:
        fail('invalid_config', 'workspace must not contain Managoat application state')
    c['workspace'] = str(workspace)
    agent = c.get('agent')
    fields(agent, ['runtime', 'model', 'name', 'instructions_file', 'permissions'], 'agent')
    if agent.get('runtime') not in ('codex', 'claude'):
        fail('invalid_config', 'agent.runtime must be codex or claude')
    agent.setdefault('name', 'Workspace agent')
    text(agent['name'], 'agent.name')
    agent.setdefault('model', None)
    provider = 'openai/' if agent['runtime'] == 'codex' else 'anthropic/'
    if agent['model'] is not None and (not text(agent['model'], 'agent.model').startswith(provider) or agent['model'] == provider):
        fail('invalid_config', 'agent.model must name the runtime provider and model')
    agent.setdefault('permissions', {'default': 'auto_allow'})
    if not isinstance(agent['permissions'], dict) or any(not isinstance(k, str) or not k or v not in ('auto_allow', 'ask', 'auto_deny') for k, v in agent['permissions'].items()):
        fail('invalid_config', 'agent.permissions must use auto_allow, ask, or auto_deny')
    instruction_file = agent.pop('instructions_file', None)
    try:
        agent['instructions'] = (path.parent / text(instruction_file, 'instructions_file')).read_text() if instruction_file is not None else None
    except OSError:
        fail('invalid_config', 'cannot read agent.instructions_file relative to the config')
    c.setdefault('repository', None)
    if c['repository'] is not None:
        repository = c['repository']
        fields(repository, ['url', 'ref', 'token_env', 'username'], 'repository')
        url = urllib.parse.urlsplit(text(repository.get('url'), 'repository.url'))
        if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment:
            fail('invalid_config', 'repository.url must be an HTTPS URL without embedded credentials')
        if 'token_env' in repository:
            name = repository['token_env']
            if not isinstance(name, str) or not ENV_NAME.fullmatch(name) or name in RESERVED_ENV or name.startswith(('MANAGOAT_', 'SPRITE_', 'SPRITES_')):
                fail('invalid_config', 'repository.token_env must name a non-platform credential variable')
        if 'username' in repository:
            text(repository['username'], 'repository.username')
        repository.setdefault('ref', 'HEAD')
        if text(repository['ref'], 'repository.ref').startswith('-'):
            fail('invalid_config', 'repository.ref cannot begin with a dash')
    c.setdefault('env', [])
    if not isinstance(c['env'], list) or any(not isinstance(n, str) or not ENV_NAME.fullmatch(n) or n in RESERVED_ENV or n.startswith(('MANAGOAT_', 'SPRITE_', 'SPRITES_', 'DYLD_', 'LD_')) for n in c['env']):
        fail('invalid_config', 'env must list variable names, excluding process controls and platform credentials')
    c['env'] = sorted(set(c['env']))
    c.setdefault('bootstrap', [])
    if not isinstance(c['bootstrap'], list):
        fail('invalid_config', 'bootstrap must be a list of shell commands')
    for command in c['bootstrap']:
        text(command, 'bootstrap command')
    for key, default, upper in [('port', 8080, 65535), ('bootstrap_timeout_seconds', 900, 86400)]:
        c.setdefault(key, default)
        if type(c[key]) is not int or not 1 <= c[key] <= upper:
            fail('invalid_config', f'{key} must be an integer between 1 and {upper}')
    c.setdefault('cors_origins', [])
    if not isinstance(c['cors_origins'], list):
        fail('invalid_config', 'cors_origins must be a list of exact browser origins')
    for origin in c['cors_origins']:
        u = urllib.parse.urlsplit(text(origin, 'cors origin'))
        if u.scheme not in ('http', 'https') or not u.hostname or u.username or u.password or u.path or u.query or u.fragment or '*' in origin:
            fail('invalid_config', 'cors_origins must contain exact http(s) origins')
    return c


def fingerprint(c):
    return hashlib.sha256(json.dumps(c, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def directory(c):
    root = Path(os.environ.get('MANAGOAT_CLIENT_ROOT', Path.home() / '.local/share/managoat-client'))
    return root / c['org'] / c['name']


def command(args, payload=None, timeout=120):
    try:
        result = subprocess.run(args, input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, timeout=timeout)
    except FileNotFoundError:
        fail('sprite_cli_missing', 'install the Sprites CLI and run sprite login')
    except subprocess.TimeoutExpired:
        fail('transport_timeout', 'retry the same command; inspect remote bootstrap state before retrying a started step')
    if result.returncode:
        # Output may include credentials, bootstrap text or platform account details.
        fail('sprite_command_failed', f'command exited {result.returncode}; check Sprite login/connectivity and retry')
    return result.stdout


class Platform:
    def __init__(self, c):
        self.c = c

    def api(self, path, method='GET', body=None, allowed=(200,)):
        args = ['sprite', 'api', '-o', self.c['org'], path, '--', '-sS', '--max-time', '60',
                '-X', method, '-w', '\n%{http_code}']
        if body is not None:
            args += ['-H', 'Content-Type: application/json', '--data-binary', '@-']
        raw = command(args, json.dumps(body) if body is not None else None)
        try:
            raw, status = raw.rstrip('\n').rsplit('\n', 1)
            status = int(status)
            result = json.loads(raw) if raw.strip() else {}
        except (ValueError, TypeError):
            fail('platform_response_invalid', 'expected a JSON Sprite API response')
        if status not in allowed:
            fail('platform_request_failed', f'{method} returned HTTP {status}; check organization access and retry')
        return status, result

    def info(self):
        status, result = self.api('/v1/sprites/' + self.c['name'], allowed=(200, 404))
        return result if status == 200 else None

    def remote(self, payload):
        helper = Path(__file__).with_name('provision_remote.py')
        # Only public helper code is uploaded. Secret values travel over stdin.
        args = ['sprite', 'exec', '-o', self.c['org'], '-s', self.c['name'],
                '--file', str(helper) + ':/home/sprite/.managoat-provision/runner.py',
                '--', 'bash', '-lc', 'exec python3 /home/sprite/.managoat-provision/runner.py']
        raw = command(args, json.dumps(payload), timeout=self.c['bootstrap_timeout_seconds'] * max(1, len(self.c['bootstrap'])) + 1200)
        try:
            result = json.loads(raw)
        except ValueError:
            fail('remote_response_invalid', 'retry to recover durable provisioning state')
        if not result.get('ok'):
            fail(result.get('error', 'remote_setup_failed'), result.get('message', 'inspect remote setup state'))
        return result


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def verify_endpoint(url, key, runtime, timeout=60):
    opener = urllib.request.build_opener(NoRedirect)
    deadline = time.monotonic() + timeout
    while True:
        try:
            try:
                with opener.open(url + '/api/agents', timeout=10):
                    fail('endpoint_auth_missing', 'the external API accepted an unauthenticated request')
            except urllib.error.HTTPError as error:
                if error.code != 401:
                    raise
            headers = {'Authorization': 'Bearer ' + key}
            with opener.open(urllib.request.Request(url + '/readyz', headers=headers), timeout=10) as response:
                ready = json.load(response)
            with opener.open(urllib.request.Request(url + '/api/agents', headers=headers), timeout=10) as response:
                agents = json.load(response)
            if not ready.get('ready') or agents['data'][0]['runtime'] != runtime:
                raise ValueError('wrong service or unready')
            with opener.open(urllib.request.Request(url + '/api/events/stream?wait=false', headers=headers), timeout=10) as response:
                if response.headers.get_content_type() != 'text/event-stream' or response.readline(1024).strip() != b': connected':
                    raise ValueError('SSE unavailable')
            return
        except (OSError, ValueError, KeyError, IndexError):
            if time.monotonic() >= deadline:
                fail('external_readiness_failed', 'service is installed; check Sprite routing and retry the same command')
            time.sleep(min(1, max(0, deadline - time.monotonic())))


def connection(c, platform, state, key, location):
    info = platform.info()
    validate_identity(c, info, state)
    url = info.get('url', '').rstrip('/')
    u = urllib.parse.urlsplit(url)
    if u.scheme != 'https' or not u.hostname or u.username or u.password or u.query or u.fragment or u.path:
        fail('sprite_url_unavailable', 'platform did not return a valid HTTPS origin')
    remote = platform.remote({'action': 'status', 'config': c, 'operation_id': state['operation_id'],
                              'client_key_hash': hashlib.sha256(key.encode()).hexdigest()})
    if not remote.get('ready'):
        fail('local_readiness_failed', 'run managoat status inside the Sprite')
    result = {'sprite': c['name'], 'organization': c['org'], 'url': url, 'api_url': url + '/api',
              'api_key_file': str(location / 'client.key'), 'agent_id': 'default',
              'release': c['release'], 'local_ready': True, 'inference_verified': False,
              'external_access': 'unverified', 'url_auth': c['url_auth']}
    if info.get('url_settings', {}).get('auth') != c['url_auth']:
        fail('url_auth_changed', 'platform URL authentication differs; rerun create to apply the config')
    if c['url_auth'] == 'public':
        verify_endpoint(url, key, c['agent']['runtime'])
        result['external_access'] = 'verified'
    else:
        result['proxy_command'] = f"sprite proxy -o {c['org']} -s {c['name']} {c['port']}"
    return result


def validate_identity(c, info, state):
    if info is None:
        fail('sprite_missing', 'the recorded Sprite is gone; choose a new name to provision a replacement')
    if info.get('name') != c['name'] or info.get('organization') != c['org'] or not info.get('id'):
        fail('sprite_identity_mismatch', 'platform resource does not match the requested organization and name')
    if state.get('sprite_id') and info['id'] != state['sprite_id']:
        fail('sprite_identity_mismatch', 'a different Sprite now has this name; refusing to adopt it')
    if 'managoat:' + state['operation_id'] not in info.get('labels', []):
        fail('sprite_name_conflict', 'this Sprite was not created by this provisioning operation')


def provision(c, action, retry_bootstrap=False):
    location = directory(c).resolve()
    digest = fingerprint(c)
    with lock(location):
        path = location / 'state.json'
        state = json.loads(path.read_text()) if path.exists() else None
        if state and state.get('config_hash') != digest:
            fail('configuration_changed', 'use the original config to resume, or a new Sprite name')
        if action == 'status' and not state:
            fail('not_provisioned', 'run managoat sprite create --file with this configuration first')
        if state and not (location / 'client.key').is_file():
            fail('client_key_missing', 'restore the local client key; it will not be silently regenerated')
        if not state:
            state = {'config_hash': digest, 'operation_id': secrets.token_hex(16), 'stage': 'validated'}
            private_write(location / 'client.key', 'mgt_' + secrets.token_urlsafe(32) + '\n')
            save(path, state)
        key = (location / 'client.key').read_text().strip()
        platform = Platform(c)
        if action == 'create':
            # Validate secret availability before the first remote mutation.
            values = {}
            git_auth = None
            if state['stage'] != 'complete':
                credential = 'OPENAI_API_KEY' if c['agent']['runtime'] == 'codex' else 'ANTHROPIC_API_KEY'
                for name in set(c['env']) | {credential}:
                    value = os.environ.get(name)
                    if not value or '\x00' in value:
                        fail('environment_missing', f'export {name} before provisioning; values are not read from the config')
                    values[name] = value
                repository = c['repository'] or {}
                if repository.get('token_env'):
                    token = os.environ.get(repository['token_env'])
                    if not token or '\x00' in token:
                        fail('environment_missing', f"export {repository['token_env']} for the private repository")
                    git_auth = {'username': repository.get('username', 'x-access-token'), 'token': token}
            info = platform.info()
            if info is None:
                if state.get('sprite_id'):
                    fail('sprite_missing', 'the recorded Sprite is gone; use a new name for a replacement')
                state['stage'] = 'creating'
                save(path, state)
                print('Creating Sprite...', file=sys.stderr)
                platform.api('/v1/sprites', 'POST', {'name': c['name'], 'labels': ['managoat:' + state['operation_id']]}, allowed=(200, 201))
                info = platform.info()
            validate_identity(c, info, state)
            state['sprite_id'] = info['id']
            save(path, state)
            if state['stage'] != 'complete':
                print('Preparing workspace, bootstrap, and service...', file=sys.stderr)
                setup = platform.remote({'action': 'setup', 'config': c, 'operation_id': state['operation_id'],
                                 'env': values, 'git_auth': git_auth, 'client_key': key, 'retry_bootstrap': retry_bootstrap})
                if not setup.get('ready'):
                    fail('local_readiness_failed', 'setup is incomplete; URL access was not changed')
                state['stage'] = 'installed'
                save(path, state)
            if info.get('url_settings', {}).get('auth') != c['url_auth']:
                print('Applying configured URL access...', file=sys.stderr)
                platform.api('/v1/sprites/' + c['name'], 'PUT', {'url_settings': {'auth': c['url_auth']}}, allowed=(200,))
        print('Verifying connection...', file=sys.stderr)
        result = connection(c, platform, state, key, location)
        state['stage'] = 'complete'
        save(path, state)
        save(location / 'connection.json', result)
        return result


def main(argv=None):
    parser = argparse.ArgumentParser(prog='managoat sprite', description='Provision an agent on a Sprite from your computer.')
    sub = parser.add_subparsers(dest='action', required=True)
    for name in ('create', 'status'):
        p = sub.add_parser(name)
        p.add_argument('--file', required=True, help='agent JSON configuration')
        p.add_argument('--json', action='store_true', help='print connection metadata, never secret values')
        if name == 'create':
            p.add_argument('--retry-bootstrap', action='store_true', help='explicitly retry the unfinished bootstrap command after inspecting its effects')
    args = parser.parse_args(argv)
    result = provision(load_config(args.file), args.action, getattr(args, 'retry_bootstrap', False))
    if args.json:
        print(json.dumps(result))
    else:
        print('Managoat ready' if result['external_access'] == 'verified' else 'Managoat ready through a private Sprite tunnel')
        print('URL:       ' + result['url'])
        print('API:       ' + result['api_url'])
        print('API key:   saved to ' + result['api_key_file'])
        if 'proxy_command' in result:
            print('Connect:   ' + result['proxy_command'])
        print('Inference: not probed (readiness makes no paid model request)')
