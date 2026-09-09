"""Read-only project inspector. Runs inside the Sprite; JSON stdin/stdout only."""
import base64
import codecs
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import sys
import time

LIMIT = 128 * 1024


class InspectionError(Exception):
    pass


def parts(path):
    if not isinstance(path, str) or len(path.encode()) > 4096 or path.startswith('/') or '\0' in path:
        raise InspectionError('invalid_path')
    items = path.split('/') if path else []
    if any(item in ('', '.', '..', '.git') for item in items):
        raise InspectionError('invalid_path')
    return items


def open_path(root_fd, path, directory=False):
    """Each component is opened relative to a held directory; never follow links."""
    items = parts(path)
    fd = os.dup(root_fd)
    try:
        for index, item in enumerate(items):
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            if directory or index < len(items) - 1:
                flags |= os.O_DIRECTORY
            child = os.open(item, flags, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def listing(root_fd, path):
    fd = open_path(root_fd, path, directory=True)
    try:
        entries = []
        truncated = False
        with os.scandir(fd) as iterator:
            for entry in iterator:
                if entry.name == '.git':
                    continue
                if len(entries) == 1000:
                    truncated = True
                    break
                info = entry.stat(follow_symlinks=False)
                kind = 'directory' if stat.S_ISDIR(info.st_mode) else 'file' if stat.S_ISREG(info.st_mode) else 'unavailable'
                entries.append({'name': entry.name, 'path': '/'.join(filter(None, [path, entry.name])),
                                'kind': kind, 'size': info.st_size})
        entries.sort(key=lambda e: (e['kind'] != 'directory', e['name']))
        return {'entries': entries, 'truncated': truncated}
    finally:
        os.close(fd)


def read_file(root_fd, path, max_bytes=LIMIT, encoded=False):
    fd = open_path(root_fd, path)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise InspectionError('not_regular_file')
        with os.fdopen(os.dup(fd), 'rb') as file:
            data = file.read(max_bytes + 1)
        truncated = len(data) > max_bytes
        data = data[:max_bytes]
        if encoded:
            return {'content': base64.b64encode(data).decode('ascii'), 'encoding': 'base64',
                    'size': info.st_size, 'truncated': truncated}
        try:
            if b'\0' in data:
                raise UnicodeError()
            text = codecs.getincrementaldecoder('utf-8')().decode(data, final=not truncated)
            return {'text': text, 'binary': False, 'size': info.st_size, 'truncated': truncated}
        except UnicodeError:
            return {'binary': True, 'size': info.st_size, 'truncated': truncated}
    finally:
        os.close(fd)


def git(root, args):
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    env.update(GIT_OPTIONAL_LOCKS='0', GIT_CONFIG_GLOBAL='/dev/null',
               GIT_CONFIG_SYSTEM='/dev/null', GIT_TERMINAL_PROMPT='0')
    command = ['git', '--no-pager', '--git-dir', str(root / '.git'), '--work-tree', str(root),
               '-C', str(root), '-c', 'core.fsmonitor=false',
               '-c', 'core.hooksPath=/dev/null'] + args
    process = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    deadline = time.monotonic() + 10
    result = bytearray()
    truncated = False
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                if time.monotonic() >= deadline:
                    raise InspectionError('git_timeout')
                for event, _ in selector.select(0.1):
                    data = os.read(event.fileobj.fileno(), 65536)
                    if not data:
                        selector.unregister(event.fileobj)
                    else:
                        result.extend(data)
                        if len(result) > LIMIT:
                            truncated = True
                            break
                if truncated:
                    break
        code = process.wait(timeout=max(0.01, deadline - time.monotonic())) if not truncated else 0
        return bytes(result[:LIMIT]), code, truncated
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        process.stdout.close()


def changes(root):
    raw, code, truncated = git(root, ['status', '--porcelain=v1', '-z', '--untracked-files=normal', '--ignore-submodules=all'])
    if code:
        return {'repository': False, 'changes': []}
    rows = raw.split(b'\0')
    if rows[-1] != b'':
        rows.pop()  # A bounded preview must not invent a partial filename.
    result = []
    index = 0
    while index < len(rows):
        row = rows[index]
        index += 1
        if len(row) < 4:
            continue
        status = row[:2].decode('ascii', errors='replace')
        path = row[3:].decode('utf-8', errors='replace')
        record = {'status': status, 'path': path}
        if 'R' in status or 'C' in status:
            if index >= len(rows):
                break
            record['previous_path'] = rows[index].decode('utf-8', errors='replace')
            index += 1
        result.append(record)
    branch, _, _ = git(root, ['symbolic-ref', '--short', '-q', 'HEAD'])
    return {'repository': True, 'changes': result, 'branch': branch.decode('utf-8', errors='replace').strip() or 'Detached HEAD', 'truncated': truncated}


def inspect(payload):
    app = Path.home() / '.local/share/managoat/config'
    key = (app / 'client.key').read_text().strip()
    if hashlib.sha256(key.encode()).hexdigest() != payload.get('client_key_hash'):
        raise InspectionError('service_key_mismatch')
    config = json.loads((app / 'config.json').read_text())
    root = Path(config['workspace']).resolve(strict=True)
    if not root.is_dir():
        raise InspectionError('workspace_unavailable')
    action = payload.get('action')
    path = payload.get('path', '')
    parts(path)
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if action in ('list', 'link'):
            data = listing(root_fd, path)
        elif action == 'file':
            data = read_file(root_fd, path)
        elif action == 'api_file':
            maximum = payload.get('max_bytes', LIMIT)
            if type(maximum) is not int or not 0 < maximum <= LIMIT:
                raise InspectionError('invalid_limit')
            data = read_file(root_fd, path, maximum, encoded=True)
        elif action == 'status':
            data = changes(root)
        elif action == 'diff':
            arguments = ['diff', '--no-ext-diff', '--no-textconv', '--ignore-submodules=all']
            if payload.get('staged'):
                arguments.append('--cached')
            arguments.extend(['--'] + ([path] if path else []))
            output, code, truncated = git(root, arguments)
            if code:
                raise InspectionError('git_unavailable')
            data = {'text': output.decode('utf-8', errors='replace'), 'truncated': truncated,
                    'staged': bool(payload.get('staged'))}
        else:
            raise InspectionError('invalid_action')
        return dict(data, ok=True, action=action, path=path, workspace=str(root))
    finally:
        os.close(root_fd)


if __name__ == '__main__':
    try:
        print(json.dumps(inspect(json.load(sys.stdin))))
    except InspectionError as error:
        print(json.dumps({'ok': False, 'error': str(error)}))
    except Exception:
        print(json.dumps({'ok': False, 'error': 'workspace_unavailable'}))
