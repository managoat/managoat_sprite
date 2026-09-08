#!/usr/bin/env python3
"""Exercise native WebKit forms against two real local ACP service processes.

Requires compiled test dependencies, but the tested app is the production bundle.
All credentials, prompts and state are synthetic and removed afterward.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import time
import urllib.request


def run(app, screenshots=None):
    desktop = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location('native_smoke', desktop / 'scripts/smoke-macos.py')
    smoke = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(smoke)
    paths = sorted((desktop / '_build/test/lib').glob('*/ebin'))
    assert any(path.parent.name == 'managoat_sprite' for path in paths), 'Run mix check first'
    with tempfile.TemporaryDirectory(prefix='manasprites-native-', dir='/tmp') as directory:
        root = Path(directory).resolve()
        services = []
        log_handles = []
        native = None
        backend = None
        try:
            ports = []
            for name in ('Alpha', 'Beta', 'Gamma'):
                ready = root / (name + '.json')
                argv = ['elixir', '--erl', '+S 2:2']
                for path in paths:
                    argv.extend(['-pa', str(path)])
                if name == 'Gamma':
                    argv.extend([str(desktop / 'test/support/platform_node.exs'), str(root / name), str(ready)])
                else:
                    argv.extend([str(desktop / 'test/support/service_node.exs'), str(root / name), str(ready), name])
                env = os.environ.copy()
                env.update(HOME=str(root), SHELL='/bin/sh', ERL_CRASH_DUMP='/dev/null')
                log = (root / (name + '.log')).open('w')
                log_handles.append(log)
                process = subprocess.Popen(argv, cwd=desktop, env=env, stdout=log, stderr=log, start_new_session=True)
                services.append(process)
                def service_ready():
                    assert process.poll() is None, 'Local ACP service exited during startup'
                    return smoke.read(ready)
                metadata = smoke.wait_for(service_ready)
                assert int(metadata['pid']) == process.pid
                ports.append(metadata['port'])
            env = {key: os.environ[key] for key in ('HOME', 'USER', 'LOGNAME', 'TMPDIR') if key in os.environ}
            ready, proof = root / 'native-ready.json', root / 'native-proof.json'
            vm_args = root / 'fixture.vm.args'
            vm_args.write_text('-eval \'application:set_env(manasprites_desktop, platform_url, <<"http://127.0.0.1:' + str(ports[2]) + '">>).\'\n')
            env.update(RELEASE_VM_ARGS=str(vm_args), PATH='/usr/bin:/bin', MANASPRITES_DESKTOP_ROOT=str(root / 'state'),
                       MANASPRITES_DESKTOP_READY_FILE=str(ready), MANASPRITES_DESKTOP_SMOKE_FILE=str(proof),
                       MANASPRITES_DESKTOP_SMOKE_FLEET=json.dumps([f'http://127.0.0.1:{port}' for port in ports]))
            if screenshots:
                screenshots.mkdir(parents=True, exist_ok=True)
                for name in ('desktop-fleet.png', 'desktop-files.png', 'desktop-changes.png'):
                    (screenshots / name).unlink(missing_ok=True)
                env['MANASPRITES_DESKTOP_SMOKE_SCREENSHOTS'] = str(screenshots.resolve())
            native = subprocess.Popen([str(app.resolve() / 'Contents/MacOS/manasprites')], cwd=root,
                                      env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 150
            previous = None
            while time.monotonic() < deadline:
                assert native.poll() is None, 'Native app exited during UI walkthrough'
                metadata = smoke.read(ready)
                if metadata:
                    backend = int(metadata['pid'])
                result = smoke.read(proof)
                name = result.get('workspace') if result else None
                if name and name != previous:
                    previous = name
                    print(name, flush=True)
                assert not (name and name.startswith('Native fleet failed:')), name
                if name == 'Native fleet passed':
                    break
                time.sleep(.1)
            else:
                raise AssertionError('Native UI walkthrough timed out')
            clipboard = subprocess.run(['/usr/bin/pbpaste'], text=True, capture_output=True, check=True).stdout
            assert clipboard == 'https://agent.example/.well-known/agent-card.json', 'Native Copy URL clipboard mismatch'
            if screenshots:
                for name in ('desktop-fleet.png', 'desktop-files.png', 'desktop-changes.png'):
                    smoke.wait_for(lambda: (screenshots / name).is_file())
            native.terminate()
            native.wait(timeout=15)
            smoke.wait_for(lambda: not smoke.alive(backend), 15)
            database = sqlite3.connect(root / 'state/fleet.sqlite3')
            try:
                assert database.execute('SELECT name FROM agents ORDER BY name').fetchall() == [('Beta',), ('Gamma',)]
                caches = database.execute('SELECT turns FROM conversation_cache').fetchall()
                assert len(caches) == 2
                histories = [json.loads(row[0])['data'] for row in caches]
                assert sorted(map(len, histories)) == [1, 2]
                assert all(turn['status'] == 'completed' for turns in histories for turn in turns)
                assert database.execute('SELECT COUNT(*) FROM credentials WHERE name = ?', ('openai',)).fetchone()[0] == 0
            finally:
                database.close()
            # Removing a local connection must leave the remote service alive.
            req = urllib.request.Request(f'http://127.0.0.1:{ports[0]}/api/capabilities',
                                         headers={'Authorization': 'Bearer synthetic-Alpha'})
            with urllib.request.urlopen(req, timeout=5) as response:
                assert json.load(response)['contract'] == 'fountain-conversations-v1'
            ready.unlink()
            proof.unlink()
            env.pop('MANASPRITES_DESKTOP_SMOKE_FLEET')
            native = subprocess.Popen([str(app.resolve() / 'Contents/MacOS/manasprites')], cwd=root,
                                      env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            metadata = smoke.wait_for(lambda: smoke.read(ready))
            backend = int(metadata['pid'])
            result = smoke.wait_for(lambda: smoke.read(proof))
            assert result['workspace'] == 'Native fleet passed'
            print('PASS: native UI settings, attachment, parallel approvals, continuation, interruption, private creation, file/Git inspection, local removal and restart', flush=True)
        finally:
            if native:
                if native.poll() is None:
                    native.terminate()
                try:
                    native.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    native.kill()
                    native.wait(timeout=15)
            if backend:
                smoke.wait_for(lambda: not smoke.alive(backend), 15)
            for process in services:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=15)
            for log in log_handles:
                log.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path, nargs='?', default=Path('src-tauri/target/release/bundle/macos/Manasprites.app'))
    parser.add_argument('--screenshots', type=Path, help='Save synthetic native WebKit snapshots for documentation')
    args = parser.parse_args()
    run(args.app, args.screenshots)
