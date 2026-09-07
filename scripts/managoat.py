#!/usr/bin/env python3
"""Local installation/operator CLI. Secret material is read from files or named env vars."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(os.environ.get('MANAGOAT_ROOT', Path.home() / '.local/share/managoat')).resolve()
CONFIG = ROOT / 'config/config.json'
CURRENT = ROOT / 'current'


def write_private(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def run(args, capture=False, env=None):
    result = subprocess.run([str(x) for x in args], env=env, text=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if result.returncode:
        raise RuntimeError(f'{Path(args[0]).name} failed (exit {result.returncode})')
    return result.stdout if capture else None


def config():
    return json.loads(CONFIG.read_text())


def service(*args):
    return run(['sprite-env', 'services', *args], capture=True)


def release(command, expression):
    env = dict(os.environ, MANAGOAT_ROOT=str(ROOT), RELEASE_NODE='managoat', SHELL='/bin/sh')
    return run([CURRENT / 'bin/managoat', command, expression], capture=True, env=env)


def api(path, method='GET', body=None):
    c = config()
    key = (ROOT / 'config/client.key').read_text().strip()
    req = urllib.request.Request(f'http://127.0.0.1:{c["port"]}{path}',
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'}, method=method)
    with urllib.request.urlopen(req, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None


def wait_ready():
    for _ in range(60):
        try:
            if api('/readyz')['ready']:
                return
        except (OSError, ValueError):
            pass
        time.sleep(1)
    raise RuntimeError('service did not become ready; inspect managoat logs')


@contextlib.contextmanager
def operation_lock():
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (ROOT / 'operation.lock').open('a') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('another install or management operation is in progress')
        yield


def ensure_idle():
    conversations = api('/api/conversations')['data']
    if any(c['status'] in ('pending', 'running') for c in conversations):
        raise RuntimeError('a turn is active; finish or interrupt it first')


@contextlib.contextmanager
def offline():
    ensure_idle()
    # Stopping closes the admission race. Recheck the durable slot after stop.
    service('stop', 'managoat')
    try:
        db = sqlite3.connect(ROOT / 'state/managoat.sqlite3')
        try:
            if db.execute('SELECT count(*) FROM turns WHERE active=1').fetchone()[0]:
                raise RuntimeError('work was admitted while stopping; restart and reconcile before retrying')
        finally:
            db.close()
        yield
    finally:
        service('start', 'managoat')
        wait_ready()


def install(args):
    if not Path('/.sprite/api.sock').exists():
        raise RuntimeError('installation requires a Sprite with /.sprite/api.sock')
    definitions = json.loads(service('list'))
    if isinstance(definitions, dict):
        definitions = definitions.get('services', [])
    others = [s for s in definitions if s.get('http_port') and s.get('name') != 'managoat']
    if others and not args.no_http_route:
        raise RuntimeError('http_service_conflict: another Sprite service owns HTTP routing')
    if CONFIG.exists():
        c = config()
        if args.runtime and args.runtime != c['runtime']:
            raise RuntimeError('existing runtime differs; install preserves configuration')
        if args.workspace and str(Path(args.workspace).resolve()) != c['workspace']:
            raise RuntimeError('existing workspace differs; install preserves configuration')
        if (ROOT / 'state/installed.json').exists():
            service('start', 'managoat')
            wait_ready()
            status(args)
            return
    else:
        runtime = args.runtime or 'claude'
        credential_name = args.credential_env or ('OPENAI_API_KEY' if runtime == 'codex' else 'ANTHROPIC_API_KEY')
        expected = 'OPENAI_API_KEY' if runtime == 'codex' else 'ANTHROPIC_API_KEY'
        if credential_name != expected:
            raise RuntimeError('credential type does not match runtime')
        credential = Path(args.credential_file).read_text().strip() if args.credential_file else os.environ.get(credential_name, '')
        if not credential:
            raise RuntimeError(f'missing {credential_name}; use --credential-file or export the variable')
        key = os.environ.get('MANAGOAT_API_KEY') or 'mgt_' + secrets.token_urlsafe(32)
        if len(key) < 24 or any(ch.isspace() for ch in key):
            raise RuntimeError('MANAGOAT_API_KEY must have at least 24 characters and no whitespace')
        if not 0 < args.port < 65536:
            raise RuntimeError('invalid port')
        workspace = Path(args.workspace or Path.home() / 'project').resolve()
        workspace.mkdir(parents=True, exist_ok=True)
        for path in [ROOT / 'config', ROOT / 'state', ROOT / 'runtime']:
            path.mkdir(parents=True, exist_ok=True, mode=0o700)
            path.chmod(0o700)
        c = {'runtime': runtime, 'workspace': str(workspace), 'port': args.port,
             'cors_origins': args.cors_origin or []}
        if args.model:
            c['model'] = args.model
        write_private(ROOT / 'config/credentials.json', json.dumps({credential_name: credential}))
        write_private(ROOT / 'config/client.key', key + '\n')
        # Config is the durable commit point for restartable setup.
        write_private(CONFIG, json.dumps(c, indent=2))
    release('eval', 'Managoat.Sprite.Release.install()')
    create = ['create', 'managoat', '--cmd', str(ROOT / 'service'), '--no-stream']
    if not args.no_http_route:
        create.extend(['--http-port', str(args.port)])
    if any(d.get('name') == 'managoat' for d in definitions):
        service('start', 'managoat')
    else:
        service(*create)
    wait_ready()
    write_private(ROOT / 'state/installed.json', json.dumps({'version': (CURRENT / 'VERSION').read_text().strip()}))
    status(args)


def status(args):
    data = {'version': (CURRENT / 'VERSION').read_text().strip(), 'service': 'managoat',
            'agent_id': 'default', 'runtime': config()['runtime'], 'workspace': config()['workspace'],
            'local_api': f'http://127.0.0.1:{config()["port"]}/api',
            'key_file': str(ROOT / 'config/client.key'), 'external_access': 'unverified'}
    try:
        data.update(api('/readyz'))
    except (OSError, ValueError):
        data['ready'] = False
    if args.json:
        print(json.dumps(data))
    else:
        print('Managoat ready' if data['ready'] else 'Managoat installed; service is not ready')
        for k, v in data.items():
            print(f'{k}: {v}')
        print('Retrieve the application key with: managoat key show')
        print('For direct URL access, configure Sprite URL auth at provisioning; otherwise use sprite proxy 8080.')


def backup(args):
    target = Path(args.output).resolve()
    if target.exists():
        raise RuntimeError('backup output already exists')
    with operation_lock(), offline(), tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp)
        db = sqlite3.connect(ROOT / 'state/managoat.sqlite3')
        copy = sqlite3.connect(stage / 'managoat.sqlite3')
        try:
            db.backup(copy)
            # Credentials are intentionally not part of a transferable backup.
            copy.execute('DELETE FROM api_keys')
            copy.commit()
        finally:
            copy.close()
            db.close()
        shutil.copy2(CONFIG, stage / 'config.json')
        runtime_home = ROOT / 'runtime/home'
        if runtime_home.exists():
            shutil.copytree(runtime_home, stage / 'runtime_home', symlinks=True,
                ignore=shutil.ignore_patterns('auth.json', '.credentials.json', 'credentials.json', '.local', '.npm'))
        if args.workspace:
            shutil.copytree(config()['workspace'], stage / 'workspace', symlinks=True)
        (stage / 'manifest.json').write_text(json.dumps({'schema': 1, 'version': (CURRENT / 'VERSION').read_text().strip(),
            'excluded': ['api_keys', 'inference_credentials', 'runtime_auth'], 'workspace': bool(args.workspace)}))
        target.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(target, 'x:gz') as archive:
            for path in stage.iterdir():
                archive.add(path, arcname=path.name)
        target.chmod(0o600)
    print(f'Backup written: {target}')


def configure(args):
    candidate = json.loads(Path(args.file).read_text())
    with operation_lock(), offline():
        current = config()
        db = sqlite3.connect(ROOT / 'state/managoat.sqlite3')
        count = db.execute('SELECT count(*) FROM conversations').fetchone()[0]
        db.close()
        if count and any(candidate.get(k) != current.get(k) for k in ('runtime', 'workspace')):
            raise RuntimeError('retained conversations require the current runtime and workspace')
        previous = CONFIG.read_text()
        write_private(CONFIG, json.dumps(candidate, indent=2))
        try:
            release('eval', 'Managoat.Sprite.Config.load!()')
        except Exception:
            write_private(CONFIG, previous)
            raise
    print('Configuration applied')


def upgrade(args):
    if not args.version:
        raise RuntimeError('upgrade requires --version')
    with operation_lock(), offline():
        previous = CURRENT.resolve()
        source = f'https://raw.githubusercontent.com/managoat/managoat_sprite/v{args.version}/install.sh'
        with urllib.request.urlopen(source, timeout=30) as response:
            script = response.read()
        with tempfile.NamedTemporaryFile() as handle:
            handle.write(script)
            handle.flush()
            try:
                run(['sh', handle.name, '--version', args.version, '--download-only'])
                release('eval', 'Managoat.Sprite.Release.install()')
            except Exception:
                CURRENT.unlink()
                CURRENT.symlink_to(previous)
                raise
    print(f'Upgraded to {args.version}')


def main():
    parser = argparse.ArgumentParser(prog='managoat')
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('install')
    p.add_argument('--version')
    p.add_argument('--runtime', choices=['claude', 'codex'])
    p.add_argument('--workspace')
    p.add_argument('--credential-env')
    p.add_argument('--credential-file')
    p.add_argument('--model')
    p.add_argument('--port', type=int, default=8080)
    p.add_argument('--cors-origin', action='append')
    p.add_argument('--no-http-route', action='store_true')
    p.add_argument('--json', action='store_true')
    p = sub.add_parser('status')
    p.add_argument('--json', action='store_true')
    p = sub.add_parser('doctor')
    p.add_argument('--inference', action='store_true')
    sub.add_parser('logs')
    for command in ('restart', 'stop', 'start', 'uninstall'):
        sub.add_parser(command)
    p = sub.add_parser('key')
    p.add_argument('action', choices=['show', 'rotate'])
    p = sub.add_parser('backup')
    p.add_argument('--output', required=True)
    p.add_argument('--workspace', action='store_true')
    p = sub.add_parser('configure')
    p.add_argument('--file', required=True)
    p = sub.add_parser('upgrade')
    p.add_argument('--version', required=True)
    args = parser.parse_args()
    if args.command == 'install':
        with operation_lock():
            install(args)
    elif args.command == 'status':
        status(args)
    elif args.command == 'doctor':
        print(release('eval', 'Managoat.Sprite.Release.doctor()').strip())
        if args.inference:
            c = api('/api/conversations', 'POST', {'prompt': 'Reply with exactly MANAGOAT_OK. Do not use tools.'})['data']
            for _ in range(180):
                turns = api(f'/api/conversations/{c["id"]}/turns')['data']
                if turns and turns[-1]['status'] not in ('pending', 'running'):
                    print(json.dumps({'conversation_id': c['id'], 'status': turns[-1]['status'], 'usage': turns[-1]['usage']}))
                    if turns[-1]['status'] != 'completed':
                        raise RuntimeError('inference probe failed; inspect the conversation events')
                    break
                time.sleep(1)
            else:
                api(f'/api/conversations/{c["id"]}/interrupt', 'POST')
                raise RuntimeError('inference probe timed out')
    elif args.command == 'key':
        if args.action == 'show':
            print((ROOT / 'config/client.key').read_text().strip())
        else:
            release('rpc', 'Managoat.Sprite.Release.rotate_key()')
            print('API key rotated; retrieve it with managoat key show')
    elif args.command == 'logs':
        os.execvp('tail', ['tail', '-n', '100', '-f', '/.sprite/logs/services/managoat.log'])
    elif args.command in ('restart', 'stop', 'start'):
        print(service(args.command, 'managoat').strip())
    elif args.command == 'backup':
        backup(args)
    elif args.command == 'configure':
        configure(args)
    elif args.command == 'upgrade':
        upgrade(args)
    elif args.command == 'uninstall':
        with operation_lock():
            ensure_idle()
            service('stop', 'managoat')
            service('delete', 'managoat')
            launcher = Path.home() / '.local/bin/managoat'
            if launcher.exists() and str(ROOT) in launcher.read_text():
                launcher.unlink()
            if CURRENT.is_symlink():
                CURRENT.unlink()
            shutil.rmtree(ROOT / 'releases')
            print('Uninstalled service and releases; configuration, history and workspace are retained')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, sqlite3.Error) as exc:
        print(f'managoat: {exc}', file=sys.stderr)
        sys.exit(1)
