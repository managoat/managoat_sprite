import copy
import contextlib
import importlib.util
from http.server import BaseHTTPRequestHandler, SimpleHTTPRequestHandler, ThreadingHTTPServer
import base64
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
import provision as host
import provision_remote as remote


class ProvisionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.file = self.root / 'agent.json'
        self.raw = {'name': 'test-agent', 'org': 'test-org', 'url_auth': 'sprite',
                    'agent': {'runtime': 'codex'}, 'workspace': str(self.root / 'project')}
        self.file.write_text(json.dumps(self.raw))
        self.config = host.load_config(self.file)

    def tearDown(self):
        self.tmp.cleanup()

    def test_config_loads_relative_instructions_and_rejects_invalid_input(self):
        (self.root / 'instructions.md').write_text('Use the workspace.')
        raw = copy.deepcopy(self.raw)
        raw['agent']['instructions_file'] = 'instructions.md'
        self.file.write_text(json.dumps(raw))
        self.assertEqual(host.load_config(self.file)['agent']['instructions'], 'Use the workspace.')
        bad = [dict(self.raw, typo=True), dict(self.raw, url_auth=None),
               dict(self.raw, workspace='/'), dict(self.raw, port=True),
               dict(self.raw, env={'TOKEN': 'secret'}), dict(self.raw, env=['HOME']),
               dict(self.raw, env=['SPRITES_TOKEN']), dict(self.raw, env=['MANAGOAT_API_KEY']),
               dict(self.raw, repository={'url': 'https://user:password@example.test/repo'}),
               dict(self.raw, repository={'url': 'https://example.test/repo', 'ref': '--help'}),
               dict(self.raw, release='../main'), dict(self.raw, cors_origins=['https://*.example.test'])]
        for value in bad:
            with self.subTest(value=value):
                self.file.write_text(json.dumps(value))
                with self.assertRaisesRegex(RuntimeError, 'invalid_config'):
                    host.load_config(self.file)

    def test_bootstrap_executes_environment_and_cwd_and_skips_completed_steps(self):
        c = self.config
        c.update(env=['APP_VALUE'], bootstrap=["printf '%s' \"$APP_VALUE\" > value.txt", "printf done >> runs.txt"])
        root = self.root / 'remote'
        state = {'operation_id': 'operation'}
        with remote.locked(root):
            remote.prepare_workspace(c, root, state)
            remote.bootstrap(c, root, state, {'APP_VALUE': 'value with spaces and $dollars'})
            remote.bootstrap(c, root, state, {'APP_VALUE': 'changed'})
        workspace = Path(c['workspace'])
        self.assertEqual((workspace / 'value.txt').read_text(), 'value with spaces and $dollars')
        self.assertEqual((workspace / 'runs.txt').read_text(), 'done')
        self.assertEqual((root / 'state.json').stat().st_mode & 0o777, 0o600)

    def test_failed_bootstrap_requires_explicit_retry_and_preserves_prior_steps(self):
        c = self.config
        c['bootstrap'] = ['printf first >> runs.txt', 'test -f allow && printf second >> runs.txt']
        root = self.root / 'remote'
        state = {'operation_id': 'operation'}
        with remote.locked(root):
            remote.prepare_workspace(c, root, state)
            with self.assertRaises(remote.SetupError):
                remote.bootstrap(c, root, state, {})
            persisted = json.loads((root / 'state.json').read_text())
            with self.assertRaisesRegex(remote.SetupError, 'bootstrap_needs_review'):
                remote.bootstrap(c, root, persisted, {})
            (Path(c['workspace']) / 'allow').touch()
            remote.bootstrap(c, root, persisted, {}, retry=True)
        self.assertEqual((Path(c['workspace']) / 'runs.txt').read_text(), 'firstsecond')

    def test_interrupted_bootstrap_is_not_automatically_dispatched(self):
        c = self.config
        c['bootstrap'] = ['touch should-not-exist']
        root = self.root / 'remote'
        state = {'operation_id': 'operation', 'bootstrap_active': 0}
        with remote.locked(root):
            remote.prepare_workspace(c, root, state)
            with self.assertRaises(remote.SetupError) as error:
                remote.bootstrap(c, root, state, {})
        self.assertEqual(error.exception.code, 'bootstrap_needs_review')
        self.assertFalse((Path(c['workspace']) / 'should-not-exist').exists())

    def test_timeout_stops_real_child_process_and_output_is_bounded(self):
        marker = self.root / 'late'
        with self.assertRaises(remote.SetupError) as error:
            remote.run_step(['bash', '-c', 'sleep 1; touch "$1"', 'test', str(marker)],
                            self.root / 'logs/timeout.log', timeout=0.1)
        self.assertEqual(error.exception.code, 'command_timeout')
        time.sleep(1.1)
        self.assertFalse(marker.exists())
        with self.assertRaises(remote.SetupError) as error:
            remote.run_step(['yes', 'output'], self.root / 'logs/output.log', output_limit=4096)
        self.assertEqual(error.exception.code, 'command_output_limit')
        self.assertLessEqual((self.root / 'logs/output.log').stat().st_size, 4096)

    def test_clone_is_real_preserves_edits_and_recovers_after_rename(self):
        origin = self.root / 'origin'
        origin.mkdir()
        subprocess.run(['git', 'init', '-q', str(origin)], check=True)
        (origin / 'README').write_text('original')
        subprocess.run(['git', '-C', str(origin), 'add', 'README'], check=True)
        subprocess.run(['git', '-C', str(origin), '-c', 'user.name=Test', '-c', 'user.email=test@example.test',
                        'commit', '-qm', 'fixture'], check=True)
        c = self.config
        # Remote clone tests use a local fixture; public CLI validates HTTPS repositories.
        c['repository'] = {'url': str(origin), 'ref': 'HEAD'}
        root = self.root / 'remote'
        state = {'operation_id': 'operation'}
        with remote.locked(root):
            remote.prepare_workspace(c, root, state)
            (Path(c['workspace']) / 'README').write_text('user edit')
            state.pop('workspace_ready')  # Simulate a crash between rename and journal commit.
            remote.prepare_workspace(c, root, state)
        self.assertEqual((Path(c['workspace']) / 'README').read_text(), 'user edit')
        self.assertTrue(state['workspace_ready'])

    def test_private_git_clone_uses_askpass_without_saving_token_in_origin(self):
        origin = self.root / 'origin'
        origin.mkdir()
        subprocess.run(['git', 'init', '-q', str(origin)], check=True)
        (origin / 'README').write_text('private fixture')
        subprocess.run(['git', '-C', str(origin), 'add', 'README'], check=True)
        subprocess.run(['git', '-C', str(origin), '-c', 'user.name=Test', '-c', 'user.email=test@example.test',
                        'commit', '-qm', 'fixture'], check=True)
        subprocess.run(['git', '-C', str(origin), 'update-server-info'], check=True)
        expected = 'Basic ' + base64.b64encode(b'x-access-token:synthetic-git-value').decode()
        directory = str(self.root)
        class Handler(SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=directory, **kwargs)
            def log_message(self, *args):
                pass
            def do_GET(self):
                if self.headers.get('Authorization') != expected:
                    self.send_response(401)
                    self.send_header('WWW-Authenticate', 'Basic realm="fixture"')
                    self.end_headers()
                    return
                super().do_GET()
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        root = self.root / 'remote'
        self.config['repository'] = {'url': f'http://127.0.0.1:{server.server_port}/origin/.git', 'ref': 'HEAD'}
        try:
            with remote.locked(root):
                remote.prepare_workspace(self.config, root, {'operation_id': 'operation'},
                                         {'username': 'x-access-token', 'token': 'synthetic-git-value'})
            workspace = Path(self.config['workspace'])
            self.assertEqual((workspace / 'README').read_text(), 'private fixture')
            self.assertNotIn('synthetic-git-value', (workspace / '.git/config').read_text())
            self.assertNotIn('synthetic-git-value', (root / 'state.json').read_text())
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_clone_refuses_foreign_workspace(self):
        c = self.config
        c['repository'] = {'url': str(self.root / 'unused'), 'ref': 'HEAD'}
        Path(c['workspace']).mkdir()
        marker = Path(c['workspace']) / 'keep'
        marker.write_text('user files')
        with self.assertRaises(remote.SetupError) as error:
            remote.prepare_workspace(c, self.root / 'remote', {'operation_id': 'operation'})
        self.assertEqual(error.exception.code, 'workspace_conflict')
        self.assertEqual(marker.read_text(), 'user files')

    def test_remote_lock_refuses_concurrent_process(self):
        root = self.root / 'remote'
        program = 'from pathlib import Path; import provision_remote as r; r.locked(Path(__import__("sys").argv[1])).__enter__()'
        with remote.locked(root):
            result = subprocess.run([sys.executable, '-c', program, str(root)],
                                    env=dict(os.environ, PYTHONPATH=str(SCRIPTS)), capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'remote_setup_busy', result.stderr)

    def test_host_resumes_creation_without_duplicate_sprite_or_secret_output(self):
        c = self.config
        calls = []
        resources = {}
        class Platform:
            def __init__(self, config):
                pass
            def info(self):
                return resources.get('sprite')
            def api(self, path, method='GET', body=None, allowed=()):
                calls.append((method, body))
                resources['sprite'] = {'id': 'identity', 'name': c['name'], 'organization': c['org'],
                                       'labels': body['labels'], 'url': 'https://test.sprites.app',
                                       'url_settings': {'auth': 'sprite'}}
                if len(calls) == 1:
                    raise RuntimeError('network lost after create')
                return 201, resources['sprite']
            def remote(self, payload):
                if payload['action'] == 'setup':
                    self_test.assertEqual(payload['env'], {'OPENAI_API_KEY': 'synthetic-provider-value'})
                    self_test.assertTrue(payload['client_key'].startswith('mgt_'))
                return {'ok': True, 'ready': True}
        self_test = self
        env = {'MANASPRITES_ROOT': str(self.root / 'client'), 'OPENAI_API_KEY': 'synthetic-provider-value', 'UNRELATED_SECRET': 'must-not-import'}
        output = io.StringIO()
        with patch.dict(os.environ, env), patch.object(host, 'Platform', Platform), contextlib.redirect_stderr(output):
            with self.assertRaisesRegex(RuntimeError, 'network lost'):
                host.provision(c, 'create')
            result = host.provision(c, 'create')
            key = (host.directory(c) / 'client.key').read_text()
            host.provision(c, 'create')
            host.provision(c, 'status')
            self.assertEqual((host.directory(c) / 'client.key').read_text(), key)
            self.assertEqual((host.directory(c) / 'client.key').stat().st_mode & 0o777, 0o600)
            state_text = (host.directory(c) / 'state.json').read_text()
        self.assertEqual(len(calls), 1)
        self.assertEqual(result['external_access'], 'unverified')
        self.assertNotIn('synthetic-provider-value', json.dumps(result) + output.getvalue() + state_text)
        self.assertNotIn(key.strip(), json.dumps(result) + output.getvalue() + state_text)

    def test_public_access_waits_for_local_readiness_then_verifies_endpoint(self):
        c = copy.deepcopy(self.config)
        c['url_auth'] = 'public'
        events = []
        resources = {}
        class Platform:
            ready = False
            def __init__(self, config):
                pass
            def info(self):
                return resources.get('sprite')
            def api(self, path, method='GET', body=None, allowed=()):
                if method == 'POST':
                    events.append('create')
                    resources['sprite'] = {'id': 'identity', 'name': c['name'], 'organization': c['org'],
                                           'labels': body['labels'], 'url': 'https://test.sprites.app',
                                           'url_settings': {'auth': 'sprite'}}
                elif method == 'PUT':
                    events.append('publish')
                    resources['sprite']['url_settings'] = body['url_settings']
                return 200, resources['sprite']
            def remote(self, payload):
                events.append(payload['action'])
                return {'ok': True, 'ready': self.ready}
        with patch.dict(os.environ, {'MANASPRITES_ROOT': str(self.root / 'client'), 'OPENAI_API_KEY': 'synthetic-provider-value'}), \
                patch.object(host, 'Platform', Platform), \
                patch.object(host, 'verify_endpoint', side_effect=lambda *args: events.append('verify')), \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, 'local_readiness_failed'):
                host.provision(c, 'create')
            self.assertNotIn('publish', events)
            Platform.ready = True
            result = host.provision(c, 'create')
        self.assertEqual(events, ['create', 'setup', 'setup', 'publish', 'status', 'verify'])
        self.assertEqual(result['external_access'], 'verified')

    def test_remote_status_detects_a_rotated_key_before_reporting_readiness(self):
        root = self.root / 'remote'
        host.save(root / 'state.json', {'operation_id': 'ours', 'config_hash': remote.digest(self.config), 'configured': True})
        key = self.root / '.local/share/managoat/config/client.key'
        host.private_write(key, 'replacement-key')
        with patch.object(Path, 'home', return_value=self.root), patch.object(remote, 'check_service') as check:
            with self.assertRaises(remote.SetupError) as error:
                remote.execute({'action': 'status', 'config': self.config, 'operation_id': 'ours', 'client_key_hash': 'old-key-digest'}, root)
            self.assertEqual(error.exception.code, 'client_key_changed')
            check.assert_not_called()

    def test_host_refuses_unowned_or_replaced_resource(self):
        state = {'operation_id': 'ours', 'sprite_id': 'original'}
        info = {'name': self.config['name'], 'organization': self.config['org'], 'id': 'replacement', 'labels': ['managoat:ours']}
        with self.assertRaisesRegex(RuntimeError, 'sprite_identity_mismatch'):
            host.validate_identity(self.config, info, state)
        info['id'] = 'original'
        info['labels'] = []
        with self.assertRaisesRegex(RuntimeError, 'sprite_name_conflict'):
            host.validate_identity(self.config, info, state)

    def test_host_missing_environment_fails_before_platform_mutation(self):
        with patch.dict(os.environ, {'MANASPRITES_ROOT': str(self.root / 'client')}, clear=True), patch.object(host, 'Platform') as platform:
            with self.assertRaisesRegex(RuntimeError, 'environment_missing'):
                host.provision(self.config, 'create')
            platform.return_value.info.assert_not_called()

    def test_changed_config_does_not_mutate_platform(self):
        location = self.root / 'client' / self.config['org'] / self.config['name']
        host.save(location / 'state.json', {'config_hash': 'different'})
        with patch.dict(os.environ, {'MANASPRITES_ROOT': str(self.root / 'client')}), patch.object(host, 'Platform') as platform:
            with self.assertRaisesRegex(RuntimeError, 'configuration_changed'):
                host.provision(self.config, 'create')
            platform.assert_not_called()

    def test_public_endpoint_checks_auth_readiness_and_real_sse_without_redirects(self):
        requests = []
        class Handler(BaseHTTPRequestHandler):
            mode = 'normal'
            def log_message(self, *args):
                pass
            def do_GET(self):
                requests.append((self.path, self.headers.get('Authorization')))
                if self.mode == 'redirect':
                    self.send_response(302)
                    self.send_header('Location', '/must-not-follow')
                    self.end_headers()
                    return
                if self.headers.get('Authorization') != 'Bearer synthetic-client-key':
                    self.send_response(401)
                    self.end_headers()
                    return
                self.send_response(200)
                stream = '/stream' in self.path
                self.send_header('Content-Type', 'text/event-stream' if stream else 'application/json')
                self.end_headers()
                body = b': connected\n\n' if stream else json.dumps({'ready': True} if self.path == '/readyz' else {'data': [{'runtime': 'codex'}]}).encode()
                self.wfile.write(body)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f'http://127.0.0.1:{server.server_port}'
            host.verify_endpoint(url, 'synthetic-client-key', 'codex', timeout=0)
            self.assertEqual(requests[-1][0], '/api/events/stream?wait=false')
            Handler.mode = 'redirect'
            with self.assertRaisesRegex(RuntimeError, 'external_readiness_failed'):
                host.verify_endpoint(url, 'synthetic-client-key', 'codex', timeout=0)
            self.assertNotIn('/must-not-follow', [r[0] for r in requests])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_platform_transport_uses_stdin_and_parses_status_via_real_subprocess(self):
        executable = self.root / 'sprite'
        observed = self.root / 'observed.json'
        executable.write_text('#!' + sys.executable + '\nimport json,sys,os\n'
                              'open(os.environ["OBSERVED"],"w").write(json.dumps({"argv":sys.argv,"stdin":sys.stdin.read()}))\n'
                              'print(\'{"id":"created"}\\n201\')\n')
        executable.chmod(0o700)
        with patch.dict(os.environ, {'PATH': str(self.root) + os.pathsep + os.environ['PATH'], 'OBSERVED': str(observed)}):
            status, result = host.Platform(self.config).api('/v1/sprites', 'POST', {'name': 'test'}, allowed=(201,))
        self.assertEqual((status, result), (201, {'id': 'created'}))
        sent = json.loads(observed.read_text())
        self.assertEqual(json.loads(sent['stdin']), {'name': 'test'})
        self.assertIn('@-', sent['argv'])

    def test_installed_host_cli_runs_without_source_checkout_and_preserves_foreign_launcher(self):
        prefix = self.root / 'installed'
        subprocess.run([sys.executable, str(SCRIPTS / 'install-cli.py'), '--prefix', str(prefix)], check=True, capture_output=True)
        result = subprocess.run([str(prefix / 'bin/manasprites'), 'sprite', 'create', '--help'], check=True, capture_output=True)
        self.assertIn(b'--file', result.stdout)
        self.assertIn(b'--retry-bootstrap', result.stdout)
        (prefix / 'bin/manasprites').write_text('operator-owned executable')
        result = subprocess.run([sys.executable, str(SCRIPTS / 'install-cli.py'), '--prefix', str(prefix)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((prefix / 'bin/manasprites').read_text(), 'operator-owned executable')


if __name__ == '__main__':
    unittest.main()
