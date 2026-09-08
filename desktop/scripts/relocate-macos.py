#!/usr/bin/env python3
"""Bundle non-system Mach-O dependencies, fix install names, and sign inside out.

Build tooling only. The installed app needs neither Python nor Homebrew.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def macho(path):
    return path.is_file() and not path.is_symlink() and 'Mach-O' in run('/usr/bin/file', '-b', str(path))


def dependencies(path):
    return [line.strip().split(' (', 1)[0] for line in run('/usr/bin/otool', '-L', str(path)).splitlines()[1:]]


def relocate(root):
    root = root.resolve()
    target = root / 'native'
    target.mkdir(exist_ok=True)
    binaries = [p for p in root.rglob('*') if macho(p)]
    queue = list(binaries)
    copied = {}
    for path in queue:
        path.chmod(path.stat().st_mode | 0o200)
        # Precompiled NIFs may retain a build-machine LC_ID_DYLIB. That is
        # this library's identity, not a dependency to copy from the builder.
        identities = run('/usr/bin/otool', '-D', str(path)).splitlines()[1:]
        if identities:
            run('/usr/bin/install_name_tool', '-id', '@rpath/' + path.name, str(path))
        for dep in dependencies(path):
            if dep.startswith(('/usr/lib/', '/System/Library/', '@')):
                continue
            source = Path(dep).resolve(strict=True)
            if root in source.parents:
                continue
            destination = target / source.name
            if destination.name in copied and copied[destination.name] != source:
                raise RuntimeError('Native dependency filename collision')
            if destination.name not in copied:
                shutil.copy2(source, destination)
                destination.chmod(destination.stat().st_mode | 0o200)
                copied[destination.name] = source
                queue.append(destination)
                run('/usr/bin/install_name_tool', '-id', '@rpath/' + destination.name, str(destination))
            relative = os.path.relpath(destination, path.parent)
            run('/usr/bin/install_name_tool', '-change', dep, '@loader_path/' + relative, str(path))
    identity = os.environ.get('APPLE_SIGNING_IDENTITY', '-')
    entitlements = Path(__file__).resolve().parents[1] / 'src-tauri/Runtime.entitlements'
    for path in queue:
        for dep in dependencies(path):
            if dep.startswith('/') and not dep.startswith(('/usr/lib/', '/System/Library/')):
                raise RuntimeError('Release still depends on an external native library')
        run('/usr/bin/codesign', '--force', '--options', 'runtime', '--entitlements', str(entitlements),
            *(['--timestamp'] if identity != '-' else []), '--sign', identity, str(path))
    print(f'Relocated {len(copied)} native libraries; signed {len(queue)} Mach-O files.')


if __name__ == '__main__':
    relocate(Path(sys.argv[1]))
