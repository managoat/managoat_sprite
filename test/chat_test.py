import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import chat
from provision import directory, fingerprint, load_config, private_write, save

REPO = Path(__file__).resolve().parents[1]


class ChatTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = patch.dict(os.environ, {'MANAGOAT_CLIENT_ROOT': str(self.root / 'client')})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.config = self.root / 'agent.json'
        self.config.write_text(json.dumps({'org': 'test-org', 'name': 'test-agent',
            'url_auth': 'public', 'agent': {'runtime': 'codex'}}))
        c = load_config(self.config)
        self.location = directory(c)
        save(self.location / 'state.json', {'config_hash': fingerprint(c)})
        private_write(self.location / 'client.key', 'fixture-client-key')

    def serve(self, callback):
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                callback(self)

            def do_POST(self):
                callback(self)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        url = f'http://127.0.0.1:{server.server_port}'
        save(self.location / 'connection.json', {'url': url, 'url_auth': 'public'})
        return url

    def run_cli(self, *args, input=None):
        return subprocess.run([sys.executable, str(REPO / 'bin/managoat'), *args,
            '--file', str(self.config)], input=input, text=True, capture_output=True, timeout=15)

    def test_reconnect_replays_neither_prompt_nor_rendered_events(self):
        calls = []
        streams = []
        turn = {'id': 'turn-1', 'prompt': 'hello'}
        def handle(h):
            calls.append((h.command, h.path))
            self.assertEqual(h.headers['Authorization'], 'Bearer fixture-client-key')
            if h.command == 'POST':
                self.assertEqual(json.loads(h.rfile.read(int(h.headers['Content-Length']))), {'prompt': 'hello'})
                self.assertTrue(h.headers['Idempotency-Key'])
                body = json.dumps({'data': {'id': 'conversation-1'}}).encode()
            elif h.path.endswith('/turns'):
                body = json.dumps({'data': [turn]}).encode()
            else:
                streams.append(h.headers['Last-Event-ID'])
                prior = {'turn_id': 'old-turn', 'stage': 'turn', 'state': 'done'}
                text = {'turn_id': 'turn-1', 'blocks': [{'kind': 'text', 'body': 'hello'}]}
                done = {'turn_id': 'turn-1', 'stage': 'turn', 'state': 'done'}
                body = (': connected\n\nid: 1\ndata: ' + json.dumps(prior) + '\n\nid: 2\ndata: ' + json.dumps(text) + '\n\n').encode()
                if len(streams) > 1:
                    body += ('id: 3\ndata: ' + json.dumps(done) + '\n\n').encode()
            h.send_response(200)
            h.send_header('Content-Type', 'text/event-stream' if '/stream?' in h.path else 'application/json')
            h.end_headers()
            h.wfile.write(body)
        self.serve(handle)
        result = self.run_cli('prompt', '-', input='hello')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'hello\n')
        self.assertEqual(streams, ['0', '2'])
        self.assertEqual(sum(method == 'POST' for method, _ in calls), 1)
        self.assertNotIn('fixture-client-key', result.stdout + result.stderr)
        self.assertEqual(json.loads((self.location / 'last-conversation.json').read_text()), {'id': 'conversation-1'})

    def test_ambiguous_submission_is_not_retried(self):
        posts = []
        def handle(h):
            posts.append(h.path)
            h.rfile.read(int(h.headers['Content-Length']))
            h.close_connection = True
        self.serve(handle)
        result = self.run_cli('prompt', 'hello')
        self.assertEqual(result.returncode, 1)
        self.assertIn('submission_unknown', result.stderr)
        self.assertEqual(len(posts), 1)

    def test_redirect_never_forwards_authorization(self):
        received = []
        def target(h):
            received.append(h.path)
            h.send_response(200)
            h.end_headers()
        target_url = self.serve(target)
        def redirect(h):
            h.send_response(302)
            h.send_header('Location', target_url + '/stolen')
            h.end_headers()
        self.serve(redirect)
        result = self.run_cli('conversations')
        self.assertEqual(result.returncode, 1)
        self.assertIn('HTTP 302', result.stderr)
        self.assertEqual(received, [])

    def test_private_tunnel_requires_explicit_origin_and_no_plaintext_remote_url(self):
        save(self.location / 'connection.json', {'url': 'https://example.invalid', 'url_auth': 'sprite'})
        with self.assertRaisesRegex(RuntimeError, 'private_connection'):
            chat.Client(self.config)
        with self.assertRaisesRegex(RuntimeError, 'invalid_url'):
            chat.Client(self.config, 'http://example.invalid')
        self.assertEqual(chat.Client(self.config, 'http://127.0.0.1:8080').url, 'http://127.0.0.1:8080')

    def test_sse_multiline_and_incomplete_frames(self):
        stream = io.BytesIO(b': heartbeat\r\n\r\nid: 12\r\ndata: {"blocks":\r\ndata: []}\r\n\r\nid: 13\ndata: {')
        self.assertEqual(list(chat.events(stream)), [(12, {'blocks': []})])

    def test_json_stream_outputs_events_and_failed_turn_exits_nonzero(self):
        def handle(h):
            if h.path.endswith('/turns'):
                body = json.dumps({'data': [{'id': 'turn-1'}]}).encode()
                mime = 'application/json'
            else:
                body = b'id: 1\ndata: {"turn_id":"turn-1","stage":"turn","state":"failed"}\n\n'
                mime = 'text/event-stream'
            h.send_response(200)
            h.send_header('Content-Type', mime)
            h.end_headers()
            h.wfile.write(body)
        self.serve(handle)
        result = self.run_cli('watch', 'conversation-1', '--json')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['state'], 'failed')
        self.assertIn('turn_failed', result.stderr)


if __name__ == '__main__':
    unittest.main()
