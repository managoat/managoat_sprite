#!/usr/bin/env python3
"""Verify, archive, extract and exercise the macOS app before delivering a ZIP.

Build tooling only. No account access and no publication. Failed verification
leaves no new delivery archive. The native smoke test uses synthetic state.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


MACHO = {bytes.fromhex(magic) for magic in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca',
    'cafebabf', 'bfbafeca')}


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def verify(app, require_notarized=False):
    app = app.resolve(strict=True)
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    if require_notarized:
        signature = run('/usr/bin/codesign', '--display', '--verbose=4', str(app))
        assert 'Authority=Developer ID Application:' in signature, 'Developer ID Application signature required'
        assert 'Timestamp=' in signature, 'Secure signing timestamp required'
        run('/usr/bin/xcrun', 'stapler', 'validate', str(app))
        run('/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', str(app))
    with (app / 'Contents/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    assert info['CFBundleIdentifier'] == 'com.managoat.manasprites', 'Unexpected app identity'
    version = info['CFBundleShortVersionString']
    assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.-]+)?', version), 'Invalid version'
    native = app / 'Contents/MacOS/manasprites'
    architectures = run('/usr/bin/lipo', '-archs', str(native)).split()
    assert len(architectures) == 1 and architectures[0] in ('arm64', 'x86_64'), 'Build each architecture natively'
    arch = architectures[0]
    release = app / 'Contents/Resources/rel'
    assert (release / 'releases/COOKIE').read_text().strip() == 'unused', 'Release contains an active distribution cookie'
    assert not list((release / 'lib').glob('managoat_sprite-*')), 'Test service must not ship in desktop release'
    binaries = []
    for path in app.rglob('*'):
        relative = path.relative_to(app)
        name = path.name.lower()
        assert name not in ('vault.key', 'client.key', 'credentials.json', 'erl_crash.dump', '.env', '.ds_store'), 'Local state file found in app'
        assert not re.search(r'\.(?:sqlite3?|db)(?:-wal|-shm|-journal)?$', name), 'Local database found in app'
        if path.is_symlink():
            assert app in path.resolve(strict=True).parents, 'Symlink escapes app bundle'
            continue
        if not path.is_file():
            continue
        with path.open('rb') as file:
            magic = file.read(4)
        if magic not in MACHO:
            continue
        assert arch in run('/usr/bin/lipo', '-archs', str(path)).split(), 'Embedded binary architecture mismatch'
        for line in run('/usr/bin/otool', '-L', str(path)).splitlines()[1:]:
            dependency = line.strip().split(' (', 1)[0]
            assert dependency.startswith(('/usr/lib/', '/System/Library/', '@')), 'External native dependency remains'
            if dependency.startswith('@loader_path/'):
                target = (path.parent / dependency[len('@loader_path/'):]).resolve(strict=True)
                assert app in target.parents, 'Native dependency escapes bundle'
        binaries.append(str(relative))
    assert any('beam.smp' in path for path in binaries), 'Embedded ERTS is missing'
    return {'version': version, 'architecture': arch, 'native_binaries': len(binaries)}


def package(app, destination, require_notarized=False):
    evidence = verify(app, require_notarized)
    destination.mkdir(parents=True, exist_ok=True)
    filename = f"Manasprites-{evidence['version']}-macos-{evidence['architecture']}.zip"
    with tempfile.TemporaryDirectory(prefix='.package-', dir=destination) as temporary:
        staging = Path(temporary).resolve()
        archive = staging / filename
        run('/usr/bin/ditto', '-c', '-k', '--keepParent', '--norsrc', str(app.resolve()), str(archive))
        unpacked = staging / 'Archive verification'
        run('/usr/bin/ditto', '-x', '-k', str(archive), str(unpacked))
        extracted = unpacked / 'Manasprites.app'
        assert verify(extracted, require_notarized) == evidence, 'Archive changed bundle metadata'
        module_spec = importlib.util.spec_from_file_location('native_smoke', Path(__file__).with_name('smoke-macos.py'))
        module = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(module)
        module.smoke(extracted)
        # Exercise the embedded launcher too: distribution stays disabled even
        # if an inherited environment asks for an Erlang network node.
        env = {key: os.environ[key] for key in ('HOME', 'USER', 'LOGNAME', 'TMPDIR') if key in os.environ}
        node_proof = staging / 'node.txt'
        vm_args = staging / 'probe.vm.args'
        vm_args.write_text('-eval \'file:write_file(' + json.dumps(str(node_proof)) +
            ', atom_to_list(node())).\'\n')
        ready = staging / 'direct-ready.json'
        env.update(PATH='/usr/bin:/bin', RELEASE_DISTRIBUTION='sname',
            RELEASE_NODE=f'manasprites_probe_{os.getpid()}', RELEASE_VM_ARGS=str(vm_args),
            MANASPRITES_DESKTOP_ROOT=str(staging / 'Direct launch state'),
            MANASPRITES_DESKTOP_READY_FILE=str(ready))
        child = subprocess.Popen([str(extracted / 'Contents/Resources/rel/bin/manasprites_desktop'), 'start'],
            env=env, cwd=staging, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            def direct_ready():
                assert child.poll() is None, 'Embedded release exited before ready'
                return module.read(ready) if node_proof.exists() else None
            module.wait_for(direct_ready)
            assert node_proof.read_text() == 'nonode@nohost', 'Embedded release enabled Erlang distribution'
        finally:
            child.terminate()
            try:
                child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=15)
        print('PASS: direct embedded release launch overrides inherited Erlang distribution settings')
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        checksum = staging / (filename + '.sha256')
        checksum.write_text(f'{digest}  {filename}\n')
        evidence.update(sha256=digest, archive=filename, native_smoke='passed',
            distribution='disabled', signing=('Developer ID; stapled notarization and Gatekeeper verified'
                if require_notarized else 'local build; notarization not verified'))
        report = staging / (filename + '.json')
        report.write_text(json.dumps(evidence, indent=2) + '\n')
        for file in (archive, checksum, report):
            os.replace(file, destination / file.name)
    print(f'PASS: verified archive, checksum and build evidence at {destination / filename}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path, nargs='?', default=Path('src-tauri/target/release/bundle/macos/Manasprites.app'))
    parser.add_argument('--output', type=Path, default=Path('dist'))
    parser.add_argument('--require-notarized', action='store_true',
        help='Require Developer ID signing, a stapled notarization ticket and Gatekeeper acceptance before and after archiving')
    args = parser.parse_args()
    package(args.app, args.output, args.require_notarized)
