#!/usr/bin/env python3
"""Install the host CLI from a source checkout without an Elixir toolchain."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import tempfile

MARKER = '# Managoat host CLI launcher\n'


def install(prefix):
    source = Path(__file__).resolve().parent
    prefix = prefix.expanduser().resolve()
    launcher = prefix / 'bin/managoat'
    if launcher.exists() or launcher.is_symlink():
        if launcher.is_symlink() or MARKER not in launcher.read_text():
            raise RuntimeError('managoat already exists at this prefix; choose a different --prefix')
    files = ['managoat.py', 'provision.py', 'provision_remote.py']
    digest = hashlib.sha256(b''.join((source / name).read_bytes() for name in files)).hexdigest()[:16]
    library = prefix / 'lib/managoat-cli' / digest
    library.parent.mkdir(parents=True, exist_ok=True)
    if not library.exists():
        stage = Path(tempfile.mkdtemp(prefix='.install-', dir=library.parent))
        try:
            for name in files:
                shutil.copyfile(source / name, stage / name)
            os.rename(stage, library)
        finally:
            if stage.exists():
                shutil.rmtree(stage)
    launcher.parent.mkdir(parents=True, exist_ok=True)
    content = ('#!/usr/bin/env python3\n' + MARKER + 'import sys\n'
               + 'sys.path.insert(0, ' + repr(str(library)) + ')\n'
               + 'from managoat import entrypoint\nentrypoint()\n')
    fd, name = tempfile.mkstemp(dir=launcher.parent)
    try:
        with os.fdopen(fd, 'w') as file:
            file.write(content)
            os.fchmod(file.fileno(), 0o755)
        os.replace(name, launcher)
    finally:
        if os.path.exists(name):
            os.unlink(name)
    print(f'Installed {launcher}')
    print(f'Add {launcher.parent} to PATH, then run managoat sprite create --file agent.json')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, default=Path.home() / '.local')
    args = parser.parse_args()
    try:
        install(args.prefix)
    except (RuntimeError, OSError) as error:
        parser.exit(1, f'managoat: {error}\n')
