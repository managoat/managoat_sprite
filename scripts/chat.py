"""Conversation commands for the host CLI; compatible with service v0.1.0."""
import argparse
import http.client
import json
import re
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from provision import NoRedirect, directory, fail, fingerprint, load_config, save


class Client:
    def __init__(self, config_file, url=None):
        config = load_config(config_file)
        self.location = directory(config).resolve()
        try:
            state = json.loads((self.location / 'state.json').read_text())
            connection = json.loads((self.location / 'connection.json').read_text())
            self.key = (self.location / 'client.key').read_text().strip()
        except (OSError, ValueError):
            fail('connection_missing', 'run managoat sprite create with this config first')
        if state.get('config_hash') != fingerprint(config):
            fail('configuration_changed', 'use the original provisioning config')
        if connection.get('url_auth') == 'sprite' and not url:
            fail('private_connection', 'run the proxy_command from sprite status, then pass --url http://127.0.0.1:' + str(config['port']))
        self.url = (url or connection['url']).rstrip('/')
        u = urllib.parse.urlsplit(self.url)
        if (not u.hostname or u.username or u.password or u.query or u.fragment or u.path
                or not (u.scheme == 'https' or (u.scheme == 'http' and u.hostname in ('127.0.0.1', 'localhost', '::1')))):
            fail('invalid_url', 'use an HTTPS origin or an HTTP loopback tunnel')
        self.opener = urllib.request.build_opener(NoRedirect)

    def open(self, path, body=None, headers=None):
        request = urllib.request.Request(self.url + path,
            data=json.dumps(body).encode() if body is not None else None,
            headers={'Authorization': 'Bearer ' + self.key, 'Content-Type': 'application/json', **(headers or {})})
        try:
            return self.opener.open(request, timeout=75)
        except urllib.error.HTTPError as error:
            # Never echo arbitrary response bodies or URLs containing account state.
            hints = {401: 'check the saved client key', 404: 'conversation or endpoint not found',
                     400: 'check the prompt and whether this conversation is busy',
                     409: 'another turn is active or the idempotency key conflicts',
                     410: 'this conversation is closed', 422: 'check the submitted options'}
            fail('api_error', f'HTTP {error.code}; ' + hints.get(error.code, 'check service status'))

    def api(self, path, body=None, headers=None):
        with self.open(path, body, headers) as response:
            return json.load(response)

    def last(self):
        try:
            return identifier(json.loads((self.location / 'last-conversation.json').read_text())['id'])
        except (OSError, ValueError, KeyError):
            fail('conversation_missing', 'start a prompt or select an ID from managoat conversations')


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r'[a-zA-Z0-9_-]+', value):
        fail('invalid_conversation', 'expected a conversation ID')
    return value


def events(response):
    """Decode complete SSE frames only, including multiline data and comments."""
    data, event_id = [], None
    size = 0
    while True:
        raw = response.readline(1024 * 1024 + 1)
        if not raw:
            return
        size += len(raw)
        if size > 8 * 1024 * 1024 or len(raw) > 1024 * 1024:
            fail('invalid_stream', 'event exceeds the client size limit')
        line = raw.decode('utf-8').rstrip('\r\n')
        if not line:
            if data:
                yield event_id, json.loads('\n'.join(data))
            data, event_id, size = [], None, 0
        elif line.startswith('id:'):
            event_id = int(line[3:].strip())
        elif line.startswith('data:'):
            data.append(line[5:].removeprefix(' '))


def render(event):
    for block in event.get('blocks', []):
        kind = block.get('kind')
        if kind == 'text':
            print(block.get('body', ''), end='', flush=True)
        elif kind == 'tool_use':
            print('\n[tool] ' + str(block.get('summary') or block.get('name') or 'running'), file=sys.stderr, flush=True)
        elif kind == 'tool_result':
            print(str(block.get('body', '')), file=sys.stderr, flush=True)
        elif kind == 'permission_request':
            print('\n[permission] Answer through the API: request ' + str(block.get('request_id')),
                  file=sys.stderr, flush=True)


def watch(client, cid, tid, json_output=False):
    cursor = 0
    failures = 0
    while True:
        try:
            with client.open(f'/api/conversations/{cid}/stream?blocks=true',
                             headers={'Last-Event-ID': str(cursor)}) as response:
                if response.headers.get_content_type() != 'text/event-stream':
                    fail('invalid_stream', 'expected server-sent events')
                for event_id, event in events(response):
                    if event_id is None or event_id <= cursor:
                        continue
                    cursor = event_id
                    failures = 0
                    if event.get('turn_id') != tid:
                        continue
                    if json_output:
                        print(json.dumps(event), flush=True)
                    else:
                        render(event)
                    if event.get('stage') == 'turn' and event.get('state') != 'started':
                        if not json_output:
                            print(flush=True)
                        if event.get('state') != 'done':
                            fail('turn_failed', str(event.get('state')) + '; inspect this conversation before continuing')
                        return
        except (OSError, http.client.HTTPException):
            failures += 1
            if failures >= 3:
                fail('stream_disconnected', f'reconnect with managoat watch {cid}; the turn may still be running')
        # Normal idle stream closure is expected. Reconnect without resubmitting.
        time.sleep(0.2)


def main(argv=None):
    parser = argparse.ArgumentParser(prog='managoat', description='Talk to the agent on your Sprite.')
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('prompt', 'conversations', 'watch'):
        p = sub.add_parser(name)
        p.add_argument('--file', default='agent.json', help='provisioning config (default: agent.json)')
        p.add_argument('--url', help='API origin override, including a local private tunnel')
        p.add_argument('--json', action='store_true', help='print JSON (one event per line when streaming)')
        if name == 'prompt':
            p.add_argument('text', help='prompt text, or - to read stdin')
            group = p.add_mutually_exclusive_group()
            group.add_argument('--conversation', help='send a follow-up to this conversation ID')
            group.add_argument('--continue', dest='continue_last', action='store_true', help='follow up in the last conversation used by this CLI')
        if name == 'watch':
            p.add_argument('conversation', nargs='?', help='conversation ID (default: last used)')
    args = parser.parse_args(argv)
    client = Client(args.file, args.url)
    if args.command == 'conversations':
        rows = client.api('/api/conversations')['data']
        if args.json:
            print(json.dumps({'data': rows}))
        else:
            for row in rows:
                print(f"{row['id']}  {row['status']}  {row.get('title') or '(untitled)'}")
        return
    cid = client.last() if getattr(args, 'continue_last', False) else getattr(args, 'conversation', None)
    if cid:
        cid = identifier(cid)
    if args.command == 'watch':
        cid = cid or client.last()
        turns = client.api(f'/api/conversations/{cid}/turns')['data']
        if not turns:
            fail('turn_missing', 'this conversation has no turns')
        tid = turns[-1]['id']
    else:
        prompt = sys.stdin.read() if args.text == '-' else args.text
        if not prompt.strip():
            parser.error('prompt must not be empty')
        before = client.api(f'/api/conversations/{cid}/turns')['data'] if cid else []
        path = f'/api/conversations/{cid}/prompts' if cid else '/api/conversations'
        # Never automatically replay a POST after an ambiguous transport failure.
        try:
            result = client.api(path, {'prompt': prompt}, {'Idempotency-Key': secrets.token_hex(16)})
        except (OSError, http.client.HTTPException):
            fail('submission_unknown', 'check managoat conversations before submitting again; the prompt may have been accepted')
        cid = cid or identifier(result['data']['id'])
        save(client.location / 'last-conversation.json', {'id': cid})
        print('Conversation: ' + cid, file=sys.stderr, flush=True)
        previous = {turn['id'] for turn in before}
        turns = client.api(f'/api/conversations/{cid}/turns')['data']
        candidates = [turn for turn in turns if turn['id'] not in previous]
        # v0.1.0 acknowledges follow-ups without a turn ID. Refuse to attribute
        # concurrent clients' turns to this prompt when the result is ambiguous.
        if len(candidates) != 1 or candidates[0]['prompt'] != prompt:
            fail('turn_ambiguous', f'inspect managoat watch {cid}; no prompt was resubmitted')
        tid = candidates[0]['id']
    try:
        watch(client, cid, tid, args.json)
    except KeyboardInterrupt:
        print(f'\nStopped watching; the agent may still be working. Resume: managoat watch {cid}', file=sys.stderr)
        raise SystemExit(130)
