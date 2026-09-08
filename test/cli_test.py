import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import sqlite3
import socket
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('managoat_cli', Path(__file__).parents[1] / 'scripts/managoat.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
real_check_port = cli.check_port
real_api = cli.api


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.originals = cli.ROOT, cli.CONFIG, cli.CURRENT
        cli.ROOT, cli.CONFIG, cli.CURRENT = self.root, self.root / 'config/config.json', self.root / 'current'
        cli.CURRENT.mkdir()
        (cli.CURRENT / 'VERSION').write_text('0.1.0')
        self.key = self.root / 'inference.key'
        self.key.write_text('test-inference-secret')
        self.args = argparse.Namespace(runtime='codex', credential_env=None, credential_file=str(self.key),
            workspace=str(self.root / 'project'), no_http_route=False, port=8080, cors_origin=[], model=None, json=True)
        real_exists = Path.exists
        self.socket = patch.object(Path, 'exists', lambda path: True if str(path) == '/.sprite/api.sock' else real_exists(path))
        self.socket.start()
        self.service = patch.object(cli, 'service', return_value='[]').start()
        self.release = patch.object(cli, 'release', return_value='{}').start()
        self.port_check = patch.object(cli, 'check_port').start()
        patch.object(cli, 'wait_ready').start()
        patch.object(cli, 'api', return_value={'ready': True, 'inference_verified': False}).start()
        self.environment = patch.dict(os.environ, {'MANAGOAT_API_KEY': 'test-client-key-with-at-least-24-characters'})
        self.environment.start()

    def tearDown(self):
        patch.stopall()
        cli.ROOT, cli.CONFIG, cli.CURRENT = self.originals
        self.tmp.cleanup()

    def install(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            cli.install(self.args)
        return output.getvalue()

    def test_install_imports_only_selected_credentials_and_starts_http_service(self):
        output = self.install()
        self.assertTrue(json.loads(output)['ready'])
        self.assertNotIn('test-inference-secret', output)
        self.assertNotIn(os.environ['MANAGOAT_API_KEY'], output)
        self.assertEqual(json.loads((cli.ROOT / 'config/credentials.json').read_text()), {'OPENAI_API_KEY': 'test-inference-secret'})
        self.assertEqual((cli.ROOT / 'config/client.key').stat().st_mode & 0o777, 0o600)
        self.service.assert_any_call('create', 'managoat', '--cmd', str(cli.ROOT / 'service'), '--no-stream', '--http-port', '8080')

    def test_repeat_install_keeps_identity_configuration_and_key(self):
        self.install()
        before = cli.CONFIG.read_bytes(), (cli.ROOT / 'config/client.key').read_bytes()
        self.key.unlink()
        self.args.credential_file = None
        self.install()
        after = cli.CONFIG.read_bytes(), (cli.ROOT / 'config/client.key').read_bytes()
        self.assertEqual(before, after)
        self.assertEqual(self.release.call_count, 1)

    def test_interrupted_setup_retries_without_losing_credentials(self):
        self.release.side_effect = RuntimeError('setup failed')
        with self.assertRaisesRegex(RuntimeError, 'setup failed'):
            self.install()
        key = (cli.ROOT / 'config/client.key').read_bytes()
        self.release.side_effect = None
        self.args.credential_file = None
        self.install()
        self.assertEqual(key, (cli.ROOT / 'config/client.key').read_bytes())
        self.assertTrue((cli.ROOT / 'state/installed.json').exists())

    def test_foreign_http_service_is_preserved(self):
        self.service.return_value = json.dumps([{'name': 'existing', 'http_port': 3000}])
        with self.assertRaisesRegex(RuntimeError, 'http_service_conflict'):
            self.install()
        self.assertFalse(cli.CONFIG.exists())
        self.release.assert_not_called()

    def test_invalid_api_key_fails_before_persisting_configuration(self):
        with patch.dict(os.environ, {'MANAGOAT_API_KEY': 'short'}):
            with self.assertRaisesRegex(RuntimeError, 'at least 24'):
                self.install()
        self.assertFalse(cli.CONFIG.exists())

    def test_operation_lock_refuses_concurrent_installer(self):
        with cli.operation_lock():
            with self.assertRaisesRegex(RuntimeError, 'in progress'):
                with cli.operation_lock():
                    self.fail('second operation acquired lock')

    def test_bound_port_is_detected_without_interrupting_its_owner(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            with self.assertRaisesRegex(RuntimeError, 'port_unavailable'):
                real_check_port(listener.getsockname()[1], host='127.0.0.1')
            self.assertGreater(listener.fileno(), 0)

    def test_preflight_failure_does_not_persist_credentials(self):
        self.port_check.side_effect = RuntimeError('port_unavailable')
        with self.assertRaisesRegex(RuntimeError, 'port_unavailable'):
            self.install()
        self.assertFalse((cli.ROOT/'config/credentials.json').exists())
        self.assertFalse(cli.CONFIG.exists())
        self.release.assert_not_called()

    def test_disk_reserve_failure_does_not_persist_credentials(self):
        usage = type('DiskUsage', (), {'free': 0})()
        with patch.object(cli.shutil, 'disk_usage', return_value=usage):
            with self.assertRaisesRegex(RuntimeError, 'disk_reserve_exhausted'):
                self.install()
        self.assertFalse(cli.CONFIG.exists())
        self.release.assert_not_called()

    def test_workspace_file_is_preserved_and_rejected(self):
        Path(self.args.workspace).write_text('existing user file')
        with self.assertRaisesRegex(RuntimeError, 'workspace_invalid'):
            self.install()
        self.assertEqual(Path(self.args.workspace).read_text(), 'existing user file')
        self.assertFalse(cli.CONFIG.exists())

    def test_existing_service_name_cannot_be_taken_over(self):
        self.service.return_value = json.dumps([{'name': 'managoat', 'cmd': '/some/other/app'}])
        with self.assertRaisesRegex(RuntimeError, 'service_name_conflict'):
            self.install()
        self.release.assert_not_called()

    def test_status_preserves_authenticated_degraded_readiness(self):
        self.install()
        body = {'ready': False, 'reason': 'storage_reserve_exhausted', 'schema_ready': True}
        error = cli.urllib.error.HTTPError('http://localhost/readyz',503,'unavailable',{},io.BytesIO(json.dumps(body).encode()))
        with patch.object(cli, 'api', side_effect=real_api), \
                patch.object(cli.urllib.request, 'urlopen', side_effect=error), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            cli.status(self.args)
        status = json.loads(output.getvalue())
        self.assertTrue(status['process_running'])
        self.assertFalse(status['api_ready'])
        self.assertEqual(status['reason'], 'storage_reserve_exhausted')

    def test_backup_restore_preserves_history_and_workspace_but_rotates_credentials(self):
        self.install()
        database = cli.ROOT / 'state/managoat.sqlite3'
        with contextlib.closing(sqlite3.connect(database)) as db:
            db.executescript('CREATE TABLE turns (active INTEGER, prompt TEXT);'
                'CREATE TABLE api_keys (digest TEXT);'
                "INSERT INTO turns VALUES(0, 'retained history');"
                "INSERT INTO api_keys VALUES('old-key-digest');")
            db.commit()
        workspace = Path(self.args.workspace)
        (workspace/'keep.txt').write_text('project contents')
        home = cli.ROOT/'runtime/home'
        home.mkdir(parents=True)
        (home/'session.json').write_text('retained runtime session')
        (home/'auth.json').write_text('private provider login')
        (cli.ROOT/'config/instructions.md').write_text('Preserved agent instructions')
        target = self.root/'backup.tar.gz'
        with patch.object(cli, 'offline', contextlib.nullcontext), contextlib.redirect_stdout(io.StringIO()):
            cli.backup(argparse.Namespace(output=str(target), workspace=True))
        new_root = self.root/'restored'
        new_root.mkdir()
        cli.ROOT, cli.CONFIG = new_root, new_root/'config/config.json'
        (new_root/'state').mkdir()  # Bootstrap has already created this directory.
        with contextlib.redirect_stdout(io.StringIO()):
            cli.restore(argparse.Namespace(input=str(target), credential_file=str(self.key),
                workspace=str(new_root/'project'), no_http_route=True))
        with contextlib.closing(sqlite3.connect(new_root/'state/managoat.sqlite3')) as db:
            self.assertEqual(db.execute('SELECT prompt FROM turns').fetchone()[0], 'retained history')
            self.assertEqual(db.execute('SELECT count(*) FROM api_keys').fetchone()[0], 0)
        self.assertEqual((new_root/'project/keep.txt').read_text(), 'project contents')
        self.assertEqual((new_root/'runtime/home/session.json').read_text(), 'retained runtime session')
        self.assertFalse((new_root/'runtime/home/auth.json').exists())
        self.assertEqual((new_root/'config/instructions.md').read_text(), 'Preserved agent instructions')
        self.assertNotEqual((new_root/'config/client.key').read_text().strip(), os.environ['MANAGOAT_API_KEY'])

    def prepare_upgrade(self):
        self.install()
        previous = self.root/'releases/0.1.0'
        previous.parent.mkdir()
        cli.CURRENT.rename(previous)
        cli.CURRENT.symlink_to(previous)
        manifest = {'schema': 1, 'reads_schemas': [1], 'rollback_schemas': [1]}
        (previous/'manifest.json').write_text(json.dumps(manifest))
        candidate = self.root/'releases/0.1.1'
        candidate.mkdir()
        (candidate/'manifest.json').write_text(json.dumps(manifest))
        database = self.root/'state/managoat.sqlite3'
        with contextlib.closing(sqlite3.connect(database)) as db:
            db.executescript('CREATE TABLE turns (active INTEGER); CREATE TABLE history(value TEXT);'
                "INSERT INTO history VALUES('before upgrade');")
        self.service.reset_mock()
        return previous.resolve(), database

    def test_failed_download_leaves_running_release_untouched(self):
        previous, _ = self.prepare_upgrade()
        with patch.object(cli.urllib.request, 'urlopen', side_effect=OSError('download failed')):
            with self.assertRaisesRegex(OSError, 'download failed'):
                cli.upgrade(argparse.Namespace(version='0.1.1'))
        self.assertEqual(cli.CURRENT.resolve(), previous)
        self.service.assert_not_called()

    def test_failed_migration_restores_previous_database_and_service(self):
        previous, database = self.prepare_upgrade()
        def migrate(*_):
            with contextlib.closing(sqlite3.connect(database)) as db:
                db.execute("UPDATE history SET value='candidate mutation'")
                db.commit()
            raise RuntimeError('migration failed')
        self.release.side_effect = migrate
        with patch.object(cli.urllib.request, 'urlopen', return_value=io.BytesIO(b'# installer')), \
                patch.object(cli, 'run'), patch.object(cli, 'ensure_idle'):
            with self.assertRaisesRegex(RuntimeError, 'migration failed'):
                cli.upgrade(argparse.Namespace(version='0.1.1'))
        self.assertEqual(cli.CURRENT.resolve(), previous)
        with contextlib.closing(sqlite3.connect(database)) as db:
            self.assertEqual(db.execute('SELECT value FROM history').fetchone()[0], 'before upgrade')
        self.service.assert_any_call('start', 'managoat')

    def test_failed_candidate_health_check_restores_previous_release(self):
        previous, _ = self.prepare_upgrade()
        with patch.object(cli.urllib.request, 'urlopen', return_value=io.BytesIO(b'# installer')), \
                patch.object(cli, 'run'), patch.object(cli, 'ensure_idle'), \
                patch.object(cli, 'wait_ready', side_effect=[RuntimeError('health failed'), None]):
            with self.assertRaisesRegex(RuntimeError, 'health failed'):
                cli.upgrade(argparse.Namespace(version='0.1.1'))
        self.assertEqual(cli.CURRENT.resolve(), previous)
        self.assertTrue(list((self.root/'state/upgrade-backups').glob('*.sqlite3')))


if __name__ == '__main__':
    unittest.main()
