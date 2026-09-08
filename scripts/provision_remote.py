#!/usr/bin/env python3
"""Private remote setup worker. JSON in/out; bootstrap output stays in private logs."""
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


class SetupError(Exception):
    def __init__(self, code, message):
        self.code, self.message = code, message


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as file:
            os.fchmod(file.fileno(), 0o600)
            json.dump(value, file)
            file.flush()
            os.fsync(file.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@contextlib.contextmanager
def locked(root):
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700)
    with (root / 'operation.lock').open('a') as file:
        try:
            fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SetupError('remote_setup_busy', 'a setup process is still running on this Sprite')
        yield


def run_step(args, log_path, cwd=None, env=None, timeout=900, output_limit=10 * 1024 * 1024):
    """Execute real commands with a deadline, bounded private logs and group cleanup."""
    log_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'wb') as log:
        try:
            process = subprocess.Popen(args, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       start_new_session=True)
        except OSError:
            raise SetupError('command_unavailable', f'cannot start {log_path.stem}; inspect installed prerequisites')
        deadline = time.monotonic() + timeout
        total = 0
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    if time.monotonic() >= deadline:
                        raise SetupError('command_timeout', f'{log_path.stem} timed out; log: {log_path}')
                    for event, _ in selector.select(timeout=min(0.2, max(0, deadline - time.monotonic()))):
                        data = os.read(event.fileobj.fileno(), 65536)
                        if not data:
                            selector.unregister(event.fileobj)
                        else:
                            total += len(data)
                            if total > output_limit:
                                raise SetupError('command_output_limit', f'{log_path.stem} exceeded its log budget; log: {log_path}')
                            log.write(data)
                code = process.wait(timeout=max(0.01, deadline - time.monotonic()))
            if code:
                raise SetupError('command_failed', f'{log_path.stem} exited {code}; inspect private log: {log_path}')
        except subprocess.TimeoutExpired:
            raise SetupError('command_timeout', f'{log_path.stem} timed out; log: {log_path}')
        finally:
            # Bootstrap commands are foreground jobs, not a way to launch services.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            process.stdout.close()


def prepare_workspace(c, root, state, git_auth=None):
    workspace = Path(c['workspace'])
    if state.get('workspace_ready'):
        if not workspace.is_dir():
            raise SetupError('workspace_missing', 'the prepared workspace is gone; no replacement was created')
        return
    repository = c['repository']
    if repository:
        owner = {'operation_id': state['operation_id'], 'repository': repository}
        marker = workspace / '.git/managoat-provision.json'
        # The marker travels with the atomic rename, closing its crash/commit gap.
        if marker.is_file() and json.loads(marker.read_text()) == owner:
            state['workspace_ready'] = True
            save(root / 'state.json', state)
            return
        if workspace.exists():
            raise SetupError('workspace_conflict', 'refusing to replace an existing directory with a clone')
        workspace.parent.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix='.managoat-clone-', dir=workspace.parent))
        try:
            git_env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
            if git_auth:
                askpass = root / 'git-askpass.py'
                askpass.write_text("#!/usr/bin/env python3\nimport os,sys\np=sys.argv[1].lower()\n"
                                   "if p.startswith('username'): print(os.environ['MANAGOAT_GIT_USERNAME'])\n"
                                   "elif p.startswith('password'): print(os.environ['MANAGOAT_GIT_TOKEN'])\n"
                                   "else: sys.exit(1)\n")
                askpass.chmod(0o700)
                git_env.update(GIT_ASKPASS=str(askpass), MANAGOAT_GIT_USERNAME=git_auth['username'],
                               MANAGOAT_GIT_TOKEN=git_auth['token'])
            run_step(['git', '-c', 'credential.helper=', '-c', 'http.followRedirects=false',
                      'clone', '--no-checkout', '--', repository['url'], str(stage)],
                     root / 'logs/clone.log', env=git_env)
            run_step(['git', '-C', str(stage), 'checkout', '--detach', repository['ref']], root / 'logs/checkout.log')
            save(stage / '.git/managoat-provision.json', owner)
            # Never replace a directory that appeared while cloning.
            if workspace.exists():
                raise SetupError('workspace_conflict', 'workspace appeared while cloning; it was preserved')
            os.rename(stage, workspace)
        finally:
            if stage.exists():
                shutil.rmtree(stage)
    else:
        workspace.mkdir(parents=True, exist_ok=True)
    state['workspace_ready'] = True
    save(root / 'state.json', state)


def bootstrap(c, root, state, values, retry=False):
    active = state.get('bootstrap_active')
    if active is not None and not retry:
        raise SetupError('bootstrap_needs_review', f'bootstrap step {active + 1} may have changed files; inspect its private log and any running Sprite sessions, then use --retry-bootstrap')
    env = dict(os.environ)
    env.update({name: values[name] for name in c['env']})
    for index, script in enumerate(c['bootstrap']):
        if index < state.get('bootstrap_completed', 0):
            continue
        state['bootstrap_active'] = index
        save(root / 'state.json', state)
        run_step(['bash', '-lc', script], root / f'logs/bootstrap-{index + 1}.log',
                 cwd=c['workspace'], env=env, timeout=c['bootstrap_timeout_seconds'])
        state['bootstrap_completed'] = index + 1
        state['bootstrap_active'] = None
        save(root / 'state.json', state)


def management():
    source = Path.home() / '.local/share/managoat/current/managoat.py'
    spec = importlib.util.spec_from_file_location('installed_managoat', source)
    cli = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cli)
    return cli


def install_service(c, root, state, values, client_key):
    app = Path.home() / '.local/share/managoat'
    instruction = c['agent']['instructions']
    if not state.get('installed'):
        if instruction is not None:
            (app / 'config').mkdir(parents=True, exist_ok=True, mode=0o700)
            file = app / 'config/instructions.md'
            file.write_text(instruction)
            file.chmod(0o600)
        script = root / 'install.sh'
        run_step(['curl', '-fsSL', '--proto', '=https', '--tlsv1.2',
                  f"https://raw.githubusercontent.com/managoat/manasprites/v{c['release']}/install.sh",
                  '-o', str(script)], root / 'logs/download.log', timeout=120)
        credential = 'OPENAI_API_KEY' if c['agent']['runtime'] == 'codex' else 'ANTHROPIC_API_KEY'
        env = dict(os.environ, MANAGOAT_API_KEY=client_key)
        env[credential] = values[credential]
        # Do not let an inherited local archive/root override change the pinned install.
        for name in ('MANAGOAT_ROOT', 'MANAGOAT_ARCHIVE'):
            env.pop(name, None)
        args = ['sh', str(script), '--version', c['release'], '--runtime', c['agent']['runtime'],
                '--credential-env', credential, '--workspace', c['workspace'], '--port', str(c['port']), '--json']
        if c['agent']['model']:
            args += ['--model', c['agent']['model']]
        for origin in c['cors_origins']:
            args += ['--cors-origin', origin]
        run_step(args, root / 'logs/install.log', env=env, timeout=1200)
        state['installed'] = True
        save(root / 'state.json', state)
    cli = management()
    if (cli.ROOT / 'config/client.key').read_text().strip() != client_key:
        raise SetupError('client_key_changed', 'installed client key differs; refusing to overwrite it')
    if not state.get('configured'):
        with cli.operation_lock(), cli.offline():
            # Persist only explicitly selected values in the release's private env store.
            candidate = dict(cli.config(), name=c['agent']['name'], permissions=c['agent']['permissions'],
                             cors_origins=c['cors_origins'])
            previous = cli.CONFIG.read_text()
            cli.write_private(cli.CONFIG, json.dumps(candidate))
            try:
                cli.release('eval', 'Managoat.Sprite.Config.load!()')
            except Exception:
                cli.write_private(cli.CONFIG, previous)
                raise
            cli.write_private(cli.ROOT / 'config/credentials.json', json.dumps(values))
        state['configured'] = True
        save(root / 'state.json', state)


def check_service(c):
    cli = management()
    config = cli.config()
    expected = {'runtime': c['agent']['runtime'], 'workspace': c['workspace'], 'port': c['port'],
                'model': c['agent']['model'], 'name': c['agent']['name'],
                'permissions': c['agent']['permissions'], 'cors_origins': c['cors_origins']}
    if any(config.get(k) != v for k, v in expected.items()):
        raise SetupError('service_configuration_changed', 'installed agent differs from the provisioning config')
    if (cli.CURRENT / 'VERSION').read_text().strip() != c['release']:
        raise SetupError('service_version_changed', 'installed release differs from the provisioning config')
    if c['agent']['instructions'] is not None and (cli.ROOT / 'config/instructions.md').read_text() != c['agent']['instructions']:
        raise SetupError('service_configuration_changed', 'installed instructions differ from the provisioning config')
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{c['port']}/api/agents", timeout=10):
            raise SetupError('local_auth_missing', 'local API accepted an unauthenticated request')
    except urllib.error.HTTPError as error:
        if error.code != 401:
            raise SetupError('local_readiness_failed', 'local API returned an unexpected status')
    ready = cli.api('/readyz')
    return bool(ready.get('ready') and ready.get('runtime_available'))


def execute(payload, root=None):
    root = root or Path.home() / '.managoat-provision'
    c = payload['config']
    with locked(root):
        path = root / 'state.json'
        state = json.loads(path.read_text()) if path.exists() else None
        if state and (state['operation_id'] != payload['operation_id'] or state['config_hash'] != digest(c)):
            raise SetupError('remote_configuration_changed', 'the Sprite belongs to another provisioning configuration')
        if payload['action'] == 'status':
            if not state or not state.get('configured'):
                raise SetupError('setup_incomplete', 'rerun create with the original configuration')
            key = (Path.home() / '.local/share/managoat/config/client.key').read_text().strip()
            if hashlib.sha256(key.encode()).hexdigest() != payload.get('client_key_hash'):
                raise SetupError('client_key_changed', 'local client key no longer matches the installed key')
            return {'ok': True, 'ready': check_service(c)}
        values = payload['env']
        key = payload['client_key']
        secret_hash = digest({'env': values, 'client_key': key})
        if state and state['secret_hash'] != secret_hash:
            raise SetupError('environment_changed', 'resume with the original environment values; setup does not rotate credentials')
        if not state:
            app = Path.home() / '.local/share/managoat'
            if (app / 'config/config.json').exists():
                raise SetupError('installation_conflict', 'refusing to adopt a preexisting Managoat installation')
            state = {'operation_id': payload['operation_id'], 'config_hash': digest(c), 'secret_hash': secret_hash}
            save(path, state)
        prepare_workspace(c, root, state, payload.get('git_auth'))
        bootstrap(c, root, state, values, payload.get('retry_bootstrap', False))
        install_service(c, root, state, values, key)
        return {'ok': True, 'ready': check_service(c)}


if __name__ == '__main__':
    os.umask(0o077)
    try:
        payload = json.load(sys.stdin)
        print(json.dumps(execute(payload)))
    except SetupError as error:
        print(json.dumps({'ok': False, 'error': error.code, 'message': error.message}))
    except Exception:
        # Never serialize exception arguments that may include credentials or command output.
        print(json.dumps({'ok': False, 'error': 'remote_setup_failed',
                          'message': 'inspect private logs under ~/.managoat-provision/logs and retry'}))
