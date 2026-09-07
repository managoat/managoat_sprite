#!/usr/bin/env python3
"""Stable Sprite Service process: own the instance lock and restart the BEAM.

A BEAM crash must not make the registered service wrapper exit as well. This
watchdog also bounds operational logs independently of platform log retention.
"""
import fcntl
import ctypes
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

root = Path(os.environ['MANAGOAT_ROOT'])
# Adopt orphaned grandchildren, including tools that create a new process group.
# The next BEAM may start only after every descendant of this service has exited.
if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
    sys.exit('cannot establish process ownership for crash recovery')
(root / 'state').mkdir(parents=True, exist_ok=True, mode=0o700)
lock = (root / 'state/instance.lock').open('a')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit('another Managoat instance owns this state directory')
(root / 'logs').mkdir(exist_ok=True, mode=0o700)
log = logging.getLogger('managoat')
log.setLevel(logging.INFO)
handler = RotatingFileHandler(root / 'logs/service.log', maxBytes=10*1024*1024, backupCount=4)
handler.setFormatter(logging.Formatter('%(asctime)s %(message)s'))
log.addHandler(handler)
stop = threading.Event()
child = None


def terminate(_signal, _frame):
    stop.set()
    if child is not None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass


def relay(pipe):
    pending = b''
    discarding = False
    while True:
        data = pipe.read1(4096)
        if not data:
            if pending and not discarding:
                record(pending)
            return
        pending += data
        while b'\n' in pending:
            line, pending = pending.split(b'\n', 1)
            if not discarding:
                record(line)
            discarding = False
        if len(pending) > 65536:
            if not discarding:
                log.warning('Oversized operational log line withheld')
            pending = b''
            discarding = True


def record(data):
        text = data.decode('utf-8', errors='replace')
        try:
            secrets = list(json.loads((root/'config/credentials.json').read_text()).values())
            secrets.append((root/'config/client.key').read_text().strip())
            for value in secrets:
                if isinstance(value, str) and value:
                    text = text.replace(value, '[REDACTED]')
        except (OSError, ValueError):
            text = '[operational output withheld: redaction configuration unavailable]'
        log.info(text.rstrip())


def cleanup():
    while True:
        parents = {}
        for entry in Path('/proc').iterdir():
            if entry.name.isdigit():
                try:
                    fields = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
                    parents[int(entry.name)] = int(fields[1])
                except (OSError, ValueError, IndexError):
                    pass
        owned = {os.getpid()}
        while True:
            children = {pid for pid, parent in parents.items() if parent in owned}
            expanded = owned | children
            if expanded == owned:
                break
            owned = expanded
        owned.remove(os.getpid())
        for pid in owned:
            try:
                descriptor = os.pidfd_open(pid)
                try:
                    # Recheck ancestry after opening a stable process handle.
                    parent = int(Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[1])
                    if parent == os.getpid() or parent in owned:
                        signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                finally:
                    os.close(descriptor)
            except (ProcessLookupError, FileNotFoundError):
                pass
        try:
            while os.waitpid(-1, os.WNOHANG)[0]:
                pass
        except ChildProcessError:
            if not owned:
                return
        # Never restart while an owned descendant remains, even if it is stuck
        # in uninterruptible I/O. Remaining unavailable is safer than overlap.
        time.sleep(0.1)


signal.signal(signal.SIGTERM, terminate)
signal.signal(signal.SIGINT, terminate)
env = dict(os.environ, SHELL='/bin/sh', RELEASE_NODE='managoat')
while not stop.is_set():
    child = subprocess.Popen([str(root/'current/bin/managoat'), 'start'], env=env,
        start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    thread = threading.Thread(target=relay, args=(child.stdout,), daemon=True)
    thread.start()
    while child.poll() is None:
        if stop.wait(0.2):
            try:
                child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
            break
    code = child.wait()
    cleanup()
    thread.join(timeout=3)
    child = None
    if not stop.is_set():
        log.warning('BEAM exited with status %s; restarting after process cleanup', code)
        stop.wait(3)
