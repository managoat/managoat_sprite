#!/usr/bin/env python3
"""Exercise the real packaged macOS webview, LiveView, SQLite and child cleanup.

Uses only synthetic state under a temporary root. No Sprite or inference calls.
"""
import argparse
import http.cookiejar
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


def wait_for(predicate, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError('Timed out waiting for packaged app evidence')


def read(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, ValueError):
        return None


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def smoke(app):
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    with tempfile.TemporaryDirectory(prefix='manasprites packaging ') as temp:
        # macOS /var is a symlink; Tauri deliberately refuses executable paths
        # with symlink ancestors. Launch the canonical moved bundle path.
        root = Path(temp).resolve()
        moved = root / 'Moved app/Manasprites.app'
        shutil.copytree(app, moved)
        binary = moved / 'Contents/MacOS/manasprites'
        data = root / 'Private application state'
        children = []
        try:
            def launch(number, rename=None):
                ready, proof = root / f'ready-{number}.json', root / f'proof-{number}.json'
                # Prove the bundle runs without development tools on PATH.
                env = {k: os.environ[k] for k in ('HOME', 'USER', 'LOGNAME', 'TMPDIR') if k in os.environ}
                env.update(PATH='/usr/bin:/bin', MANASPRITES_DESKTOP_ROOT=str(data),
                    MANASPRITES_DESKTOP_READY_FILE=str(ready), MANASPRITES_DESKTOP_SMOKE_FILE=str(proof),
                    ERL_CRASH_DUMP='/dev/null')
                if rename:
                    env['MANASPRITES_DESKTOP_SMOKE_NAME'] = rename
                child = subprocess.Popen([str(binary)], cwd=root, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                children.append(child)
                def booted():
                    assert child.poll() is None, 'Native application exited before it became ready'
                    return read(ready)
                metadata = wait_for(booted)
                def connected():
                    assert child.poll() is None, 'Native application exited before LiveView connected'
                    result = read(proof)
                    return result if result and (not rename or result.get('workspace') == rename) else None
                try:
                    evidence = wait_for(connected)
                except AssertionError as error:
                    raise AssertionError(f'Native LiveView probe failed; last synthetic evidence: {read(proof)}') from error
                return child, metadata, evidence

            first, metadata, evidence = launch(1, 'Packaging proof')
            assert evidence == {'event': 'live_connected', 'workspace': 'Packaging proof'}
            url = metadata['url']
            parsed = urllib.parse.urlsplit(url)
            origin = f'{parsed.scheme}://{parsed.netloc}'
            try:
                urllib.request.urlopen(origin, timeout=5)
                raise AssertionError('Unauthenticated local access was accepted')
            except urllib.error.HTTPError as error:
                assert error.code == 401
            opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
            with opener.open(url, timeout=5) as response:
                assert b'Packaging proof' in response.read()
            print('PASS: moved .app starts native WebKit + LiveView with system-only PATH; UI mutation persists in SQLite')
            env = {k: os.environ[k] for k in ('HOME', 'USER', 'LOGNAME', 'TMPDIR') if k in os.environ}
            env.update(PATH='/usr/bin:/bin', MANASPRITES_DESKTOP_ROOT=str(data),
                RELEASE_DISTRIBUTION='none', RELEASE_COOKIE='unused-local-desktop', ERL_CRASH_DUMP='/dev/null')
            duplicate = subprocess.Popen([str(moved / 'Contents/Resources/rel/bin/manasprites_desktop'), 'start'],
                cwd=root, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            children.append(duplicate)
            assert duplicate.wait(timeout=20) != 0, 'Second runtime acquired the same local state'
            with opener.open(origin, timeout=5) as response:
                assert b'Packaging proof' in response.read()
            print('PASS: a second application process cannot acquire the active SQLite database')
            first.terminate()
            first.wait(timeout=15)
            wait_for(lambda: not alive(int(metadata['pid'])), 15)
            try:
                urllib.request.urlopen(origin, timeout=2)
                raise AssertionError('Local listener survived native host termination')
            except urllib.error.URLError as error:
                assert not isinstance(error, urllib.error.HTTPError)
            print('PASS: closing native host stops its BEAM and local listener')
            second, second_metadata, restored = launch(2)
            assert restored['workspace'] == 'Packaging proof'
            assert (data / 'fleet.sqlite3').stat().st_mode & 0o777 == 0o600
            assert data.stat().st_mode & 0o777 == 0o700
            print('PASS: native relaunch restores SQLite state with private file permissions')
            second.kill()
            second.wait(timeout=15)
            wait_for(lambda: not alive(int(second_metadata['pid'])), 15)
            print('PASS: SIGKILL of the native host also shuts down its BEAM')
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=15)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path, nargs='?', default=Path('src-tauri/target/release/bundle/macos/Manasprites.app'))
    smoke(parser.parse_args().app.resolve())
