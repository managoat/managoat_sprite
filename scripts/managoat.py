#!/usr/bin/env python3
"""Local installation/operator CLI. Secret material is read from files or named env vars."""
import argparse
import contextlib
import fcntl
import json
import os
import re
from pathlib import Path
import secrets
import shutil
import signal
import socket
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


def api(path, method='GET', body=None, allow_status=()):
    c = config()
    key = (ROOT / 'config/client.key').read_text().strip()
    req = urllib.request.Request(f'http://127.0.0.1:{c["port"]}{path}',
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'}, method=method)
    try:
        response = urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as error:
        if error.code not in allow_status:
            raise
        response = error
    with response:
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


def check_port(port, host='0.0.0.0'):
    family = socket.AF_INET6 if ':' in host else socket.AF_INET
    with socket.socket(family, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            listener.bind((host, port))
        except OSError:
            raise RuntimeError(f'port_unavailable: cannot bind {host}:{port}; choose --port or stop its owner') from None


def preflight(workspace, port, reserve=268435456, host='0.0.0.0'):
    check_port(port, host)
    for label, destination in [('application', ROOT), ('workspace', workspace)]:
        ancestor = destination
        while not ancestor.exists():
            ancestor = ancestor.parent
        if not ancestor.is_dir():
            raise RuntimeError(f'{label}_invalid: path is not a directory')
        if shutil.disk_usage(ancestor).free < reserve:
            raise RuntimeError(f'{label}_disk_reserve_exhausted: free at least {reserve} bytes before installing')
        try:
            with tempfile.TemporaryFile(dir=ancestor) as probe:
                probe.write(b'managoat preflight')
                probe.flush()
                os.fsync(probe.fileno())
        except OSError:
            raise RuntimeError(f'{label}_not_writable: choose a writable directory') from None


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
    own = next((s for s in definitions if s.get('name') == 'managoat'), None)
    if own and own.get('cmd') != str(ROOT / 'service'):
        raise RuntimeError('service_name_conflict: managoat is registered to another command')
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
        if own:
            try:
                recovered = api('/readyz')['ready']
            except (OSError, ValueError):
                recovered = False
            if recovered:
                write_private(ROOT / 'state/installed.json', json.dumps({'version': (CURRENT / 'VERSION').read_text().strip()}))
                status(args)
                return
            service('stop', 'managoat')
        preflight(Path(c['workspace']), c['port'], c.get('disk_reserve_bytes',268435456), c.get('host','0.0.0.0'))
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
        preflight(workspace, args.port)
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
        create.extend(['--http-port', str(c['port'])])
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
            'key_file': str(ROOT / 'config/client.key'), 'external_access': 'unverified',
            'installed': (ROOT / 'state/installed.json').exists(), 'process_running': None,
            'api_ready': False, 'agent_initialization': 'unverified'}
    try:
        data.update(api('/readyz', allow_status=(503,)))
        data['process_running'] = True
        data['api_ready'] = data['ready']
    except (OSError, ValueError):
        data['ready'] = False
        data['reason'] = 'api_unreachable'
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
        if (ROOT / 'config/instructions.md').exists():
            shutil.copy2(ROOT / 'config/instructions.md', stage / 'instructions.md')
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
    if not re.fullmatch(r'[0-9][0-9A-Za-z.-]*', args.version or ''):
        raise RuntimeError('upgrade requires a valid --version')
    with operation_lock():
        previous = CURRENT.resolve()
        source = f'https://raw.githubusercontent.com/managoat/managoat_sprite/v{args.version}/install.sh'
        with urllib.request.urlopen(source, timeout=30) as response:
            script = response.read()
        with tempfile.NamedTemporaryFile() as handle:
            handle.write(script)
            handle.flush()
            run(['sh', handle.name, '--version', args.version, '--stage-only'])
        candidate = ROOT / 'releases' / args.version
        manifest = json.loads((candidate / 'manifest.json').read_text())
        old_manifest = json.loads((previous / 'manifest.json').read_text())
        if (manifest.get('schema') != 1 or old_manifest.get('schema') != 1 or
                1 not in manifest.get('reads_schemas', []) or
                1 not in old_manifest.get('rollback_schemas', [])):
            raise RuntimeError('incompatible migration; automatic upgrade supports schema 1 only')
        with offline():
            backups = ROOT / 'state/upgrade-backups'
            backups.mkdir(mode=0o700, exist_ok=True)
            saved = backups / f'{time.time_ns()}.sqlite3'
            source_db = sqlite3.connect(ROOT / 'state/managoat.sqlite3')
            backup_db = sqlite3.connect(saved)
            try:
                source_db.backup(backup_db)
            finally:
                source_db.close()
                backup_db.close()
            saved.chmod(0o600)
            def activate(path):
                link = ROOT / f'.current-{secrets.token_hex(8)}'
                link.symlink_to(path)
                os.replace(link, CURRENT)
            try:
                activate(candidate)
                release('eval', 'Managoat.Sprite.Release.install()')
                service('start', 'managoat')
                wait_ready()
            except Exception:
                service('stop', 'managoat')
                activate(previous)
                database = ROOT / 'state/managoat.sqlite3'
                for suffix in ('-wal', '-shm'):
                    Path(str(database) + suffix).unlink(missing_ok=True)
                shutil.copy2(saved, database)
                raise
    print(f'Upgraded to {args.version}')


def restore(args):
    if (ROOT / 'state/managoat.sqlite3').exists() or CONFIG.exists():
        raise RuntimeError('restore requires an empty installation state and configuration')
    credential = Path(args.credential_file).read_text().strip()
    if not credential:
        raise RuntimeError('restore requires an inference credential')
    with operation_lock(), tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp)
        with tarfile.open(args.input) as archive:
            archive.extractall(stage, filter='data')
        manifest = json.loads((stage / 'manifest.json').read_text())
        if manifest.get('schema') != 1:
            raise RuntimeError('unsupported backup schema')
        c = json.loads((stage / 'config.json').read_text())
        if args.workspace:
            c['workspace'] = str(Path(args.workspace).resolve())
        workspace = Path(c['workspace'])
        if (stage / 'workspace').exists() and workspace.exists() and any(workspace.iterdir()):
            raise RuntimeError('restore will not overwrite an existing workspace')
        check = sqlite3.connect(stage / 'managoat.sqlite3')
        try:
            if check.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                raise RuntimeError('backup database integrity check failed')
            if check.execute('SELECT count(*) FROM turns WHERE active=1').fetchone()[0]:
                raise RuntimeError('backup contains active work and cannot be restored automatically')
        finally:
            check.close()
        (ROOT / 'state').mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.copy2(stage / 'managoat.sqlite3', ROOT / 'state/managoat.sqlite3')
        if (stage / 'runtime_home').exists():
            shutil.copytree(stage / 'runtime_home', ROOT / 'runtime/home', symlinks=True, dirs_exist_ok=True)
        if (stage / 'workspace').exists():
            shutil.copytree(stage / 'workspace', workspace, symlinks=True, dirs_exist_ok=True)
        name = 'OPENAI_API_KEY' if c['runtime'] == 'codex' else 'ANTHROPIC_API_KEY'
        write_private(ROOT / 'config/credentials.json', json.dumps({name: credential}))
        write_private(ROOT / 'config/client.key', 'mgt_' + secrets.token_urlsafe(32) + '\n')
        if (stage / 'instructions.md').exists():
            write_private(ROOT / 'config/instructions.md', (stage / 'instructions.md').read_text())
        write_private(CONFIG, json.dumps(c, indent=2))
        install(argparse.Namespace(runtime=c['runtime'], workspace=c['workspace'],
            credential_env=None, credential_file=None, port=c.get('port',8080),
            model=c.get('model'), cors_origin=c.get('cors_origins',[]), no_http_route=args.no_http_route, json=True))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'sprite':
        from provision import main as provision_main
        return provision_main(sys.argv[2:])
    if len(sys.argv) > 1 and sys.argv[1] in ('prompt', 'conversations', 'watch'):
        from chat import main as chat_main
        return chat_main(sys.argv[1:])
    parser = argparse.ArgumentParser(prog='managoat')
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('sprite', help='create or inspect a Sprite from your computer')
    sub.add_parser('prompt', help='send a prompt and stream the response')
    sub.add_parser('conversations', help='list conversations on your Sprite')
    sub.add_parser('watch', help='stream the latest turn of a conversation')
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
    p = sub.add_parser('restore')
    p.add_argument('--input', required=True)
    p.add_argument('--credential-file', required=True)
    p.add_argument('--workspace')
    p.add_argument('--no-http-route', action='store_true')
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
        os.execvp('tail', ['tail', '-n', '100', '-f', str(ROOT / 'logs/service.log')])
    elif args.command in ('restart', 'stop', 'start'):
        print(service(args.command, 'managoat').strip())
    elif args.command == 'backup':
        backup(args)
    elif args.command == 'restore':
        restore(args)
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


def entrypoint():
    try:
        main()
    except (RuntimeError, OSError, ValueError, sqlite3.Error) as exc:
        print(f'managoat: {exc}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    entrypoint()
