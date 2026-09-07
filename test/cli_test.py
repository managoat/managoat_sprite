import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('managoat_cli', Path(__file__).parents[1] / 'scripts/managoat.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


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


if __name__ == '__main__':
    unittest.main()
