import hashlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
VERSION = (REPO / 'scripts/CLI_VERSION').read_text().strip()


class CLIReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_root = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build_root.cleanup)
        cls.dist = Path(cls.build_root.name)
        subprocess.run([sys.executable, str(REPO / 'scripts/build-cli.py'), '--output', str(cls.dist)],
                       check=True, capture_output=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.prefix = self.root / 'prefix with spaces'
        self.archive = self.dist / 'managoat-cli.tar.gz'

    def install(self, *args):
        return subprocess.run(['sh', str(self.dist / 'install-cli.sh'), '--prefix', str(self.prefix), *args],
            env={**os.environ, 'MANAGOAT_CLI_ARCHIVE': str(self.archive)},
            cwd=self.root, text=True, capture_output=True, timeout=15)

    def version(self):
        return subprocess.run([str(self.prefix / 'bin/managoat'), '--version'],
            cwd=self.root, text=True, capture_output=True, timeout=15)

    def rewrite(self, change):
        path = self.root / 'candidate.tar.gz'
        with tarfile.open(self.archive) as source, tarfile.open(path, 'w:gz') as target:
            for member in source.getmembers():
                data = source.extractfile(member).read()
                member, data = change(member, data)
                member.size = len(data)
                target.addfile(member, io.BytesIO(data))
        self.archive = path
        self.checksum()

    def checksum(self):
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        Path(str(self.archive) + '.sha256').write_text(digest + '  managoat-cli.tar.gz\n')

    def test_archive_installs_outside_checkout_and_reinstalls_without_touching_state(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.version().stdout.strip(), 'managoat CLI ' + VERSION)
        state = self.prefix / 'share/managoat-client/keep'
        state.parent.mkdir(parents=True)
        state.write_text('preserve local state')
        for command in [('prompt', '--help'), ('sprite', 'create', '--help'), ('watch', '--help')]:
            result = subprocess.run([str(self.prefix / 'bin/managoat'), *command], cwd=self.root, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        before = (self.prefix / 'bin/managoat').read_bytes()
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual((self.prefix / 'bin/managoat').read_bytes(), before)
        self.assertEqual(state.read_text(), 'preserve local state')
        self.assertEqual(len(list((self.prefix / 'lib/managoat-cli').iterdir())), 1)

    def test_updated_archive_atomically_selects_new_cli_version(self):
        self.assertEqual(self.install().returncode, 0)
        def update(member, data):
            return member, b'0.1.99\n' if member.name == 'CLI_VERSION' else data
        self.rewrite(update)
        result = self.install('--version', '0.1.99')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.version().stdout.strip(), 'managoat CLI 0.1.99')
        self.assertEqual(len(list((self.prefix / 'lib/managoat-cli').iterdir())), 2)

    def test_bad_checksum_preserves_installed_launcher(self):
        self.assertEqual(self.install().returncode, 0)
        before = (self.prefix / 'bin/managoat').read_bytes()
        self.archive = self.root / 'corrupt.tar.gz'
        self.archive.write_bytes(b'corrupted archive')
        Path(str(self.archive) + '.sha256').write_text('0' * 64 + '  managoat-cli.tar.gz\n')
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum mismatch', result.stderr)
        self.assertEqual((self.prefix / 'bin/managoat').read_bytes(), before)
        self.assertEqual(self.version().returncode, 0)

    def test_unsafe_archive_is_rejected_before_installing(self):
        def unsafe(member, data):
            if member.name == 'chat.py':
                member.type = tarfile.SYMTYPE
                member.linkname = '/tmp/not-a-cli-module'
            return member, data
        self.rewrite(unsafe)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Invalid CLI archive contents', result.stderr)
        self.assertFalse(self.prefix.exists())

    def test_wrong_version_and_foreign_executable_are_preserved(self):
        result = self.install('--version', '0.0.99')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('version mismatch', result.stderr)
        self.assertFalse(self.prefix.exists())
        launcher = self.prefix / 'bin/managoat'
        launcher.parent.mkdir(parents=True)
        launcher.write_text('unrelated executable')
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already exists', result.stderr)
        self.assertEqual(launcher.read_text(), 'unrelated executable')

    def test_build_is_reproducible_and_contains_only_release_files(self):
        other = self.root / 'second'
        subprocess.run([sys.executable, str(REPO / 'scripts/build-cli.py'), '--output', str(other)],
                       check=True, capture_output=True)
        self.assertEqual(self.archive.read_bytes(), (other / self.archive.name).read_bytes())
        with tarfile.open(self.archive) as archive:
            self.assertEqual(set(archive.getnames()), {'managoat.py', 'provision.py', 'provision_remote.py',
                'chat.py', 'install-cli.py', 'CLI_VERSION', 'LICENSE'})


if __name__ == '__main__':
    unittest.main()
