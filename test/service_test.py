"""Exercise the Linux service watchdog with real detached grandchildren."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


@unittest.skipUnless(sys.platform == 'linux', 'Sprite process ownership uses Linux subreapers')
class ServiceTests(unittest.TestCase):
    def test_crash_reaps_detached_tool_before_restarting_and_redacts_split_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'current/bin').mkdir(parents=True)
            (root/'config').mkdir()
            secret = 'fake-secret-crossing-a-log-read-boundary'
            (root/'config/client.key').write_text(secret)
            (root/'config/credentials.json').write_text(json.dumps({'OPENAI_API_KEY': secret}))
            executable = root/'current/bin/managoat'
            executable.write_text(f'''#!{sys.executable}
import os, subprocess, sys, time
from pathlib import Path
r=Path(os.environ['MANAGOAT_ROOT'])
counter=r/'starts'
n=int(counter.read_text())+1 if counter.exists() else 1
counter.write_text(str(n))
child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(120)'],start_new_session=True)
(r/f'tool-{{n}}').write_text(str(child.pid))
(r/f'beam-{{n}}').write_text(str(os.getpid()))
sys.stdout.write('fake-secret-crossing-'); sys.stdout.flush(); time.sleep(.1)
sys.stdout.write('a-log-read-boundary\\n'); sys.stdout.flush()
time.sleep(120)
''')
            executable.chmod(0o700)
            watchdog = subprocess.Popen([sys.executable, str(Path(__file__).parents[1]/'scripts/service.py')],
                env=dict(os.environ, MANAGOAT_ROOT=str(root)), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            def wait_for(path):
                for _ in range(150):
                    if path.exists():
                        return int(path.read_text())
                    if watchdog.poll() is not None:
                        self.fail(watchdog.stderr.read().decode())
                    time.sleep(.1)
                self.fail(f'timed out waiting for {path.name}')
            try:
                beam = wait_for(root/'beam-1')
                tool = wait_for(root/'tool-1')
                time.sleep(.3)
                os.kill(beam, signal.SIGKILL)
                wait_for(root/'beam-2')
                self.assertFalse(Path(f'/proc/{tool}').exists(), 'orphaned tool survived restart')
                time.sleep(.3)
                logs = (root/'logs/service.log').read_text()
                self.assertNotIn(secret, logs)
                self.assertIn('[REDACTED]', logs)
                second_tool = wait_for(root/'tool-2')
            finally:
                watchdog.terminate()
                watchdog.wait(timeout=20)
                watchdog.stderr.close()
            self.assertFalse(Path(f'/proc/{second_tool}').exists(), 'tool survived service stop')


if __name__ == '__main__':
    unittest.main()
