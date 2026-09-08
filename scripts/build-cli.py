#!/usr/bin/env python3
"""Build a reproducible, platform-independent host CLI archive."""
import argparse
import gzip
import hashlib
import io
from pathlib import Path
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]
FILES = ('manasprites.py', 'provision.py', 'provision_remote.py', 'chat.py', 'install-cli.py', 'CLI_VERSION')


def build(output):
    version = (ROOT / 'scripts/CLI_VERSION').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('CLI_VERSION must be a release version')
    output.mkdir(parents=True, exist_ok=True)
    archive = output / 'manasprites.tar.gz'
    with archive.open('wb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode='w') as tar:
            for name in (*FILES, 'LICENSE'):
                source = ROOT / 'LICENSE' if name == 'LICENSE' else ROOT / 'scripts' / name
                data = source.read_bytes()
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = 0o644
                tar.addfile(info, io.BytesIO(data))
    installer = output / 'install-cli.sh'
    installer.write_bytes((ROOT / 'install-cli.sh').read_bytes())
    for path in (archive, installer):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        path.with_name(path.name + '.sha256').write_text(f'{digest}  {path.name}\n')
    print(f'Built CLI {version}: {archive}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/cli')
    build(parser.parse_args().output)
