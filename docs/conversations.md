# Conversation walkthroughs

[Back to Managoat Sprite](../README.md)

## From the CLI

After [provisioning](provisioning.md), run from the directory containing your
`agent.json`, or pass `--file /path/to/agent.json` to any command:

```sh
managoat prompt "Inspect this project and explain how to run it."
managoat prompt --continue "Run its tests and fix the failures."
managoat conversations
managoat prompt --conversation CONVERSATION_ID "Add a regression test for the bug we fixed."
managoat watch CONVERSATION_ID
```

Each `prompt` submits one turn. Without `--continue` or `--conversation`, it
creates a new conversation and prints its ID to stderr. `--continue` selects
the last conversation submitted from this CLI for this Sprite. The CLI retains
only that ID locally, not your prompts or the agent's answers.

Agent text streams to stdout, and tool activity and connection messages go to
stderr. A completed turn exits zero; failed or interrupted turns exit nonzero.
`--json` emits one JSON event per line instead of rendering blocks. Read a prompt
from stdin with `managoat prompt -`. `managoat conversations --json` returns the
API's conversation list, which may include private prompt content.

Ctrl-C stops the stream without cancelling work. `watch` replays the latest turn
of the selected conversation and follows it to completion; omit the ID to use
your last conversation. Stream reconnects use event IDs and never resubmit the
prompt. If submission loses its response, inspect `conversations` and `watch`
before sending it again: the server may already have accepted it. When several
clients submit at once and the accepted turn cannot be identified unambiguously,
the CLI reports that ambiguity rather than choosing another client's output.

The CLI uses the saved local URL and key from provisioning. For a private Sprite,
run the `proxy_command` from `managoat sprite status --file agent.json --json`
in another terminal and pass `--url http://127.0.0.1:8080` (or the configured port)
to conversation commands. HTTPS redirects are refused to avoid forwarding the key.
A rotated service key must also be updated in your local client key file.

Tool permission requests are displayed but currently answered through the HTTP
API described below. The CLI does not auto-approve requests under an `ask` policy.

## Connect an HTTP client

The following examples use `curl` and `jq`. Load the same connection details:

```sh
managoat sprite status --file agent.json --json > connection.json
export BASE_URL="$(jq -r '.url' connection.json)"
export MANAGOAT_API_KEY="$(cat "$(jq -r '.api_key_file' connection.json)")"
```

For private access, start the tunnel and use its local address as `BASE_URL`.

## Example: explore a project, then run its tests

Start a conversation in the workspace you configured during installation:

```sh
CONVERSATION_ID=$(curl -fsS "$BASE_URL/api/conversations" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"title":"Project tour","prompt":"Inspect this project. Explain its main components and how to run its tests. Do not change files yet."}' \
  | jq -er '.data.id')
```

Creation returns HTTP `201` with the conversation under `data`. It acknowledges
the prompt; the agent continues working asynchronously. Watch its output:

```sh
curl -fsSN "$BASE_URL/api/conversations/$CONVERSATION_ID/stream?blocks=true" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY"
```

This displays SSE records with an `id`, an event kind, and a JSON payload.
`blocks=true` includes normalized text and tool blocks. Text arrives in deltas;
a client joins text block bodies to display the response. Completion appears as
an `event: stage` record with `"stage":"turn"` and `"state":"done"`.

Press Ctrl-C once the turn finishes. Closing the stream does not cancel work.
Streams also close after 60 seconds without a durable event, even if the turn
is still running. Reconnect with `Last-Event-ID: <last received id>` to replay
only newer events; without that header, conversation streams replay from the
beginning. Deduplicate by event ID when reconnecting.

Check that the conversation is `idle`, then send a follow-up in the same session:

```sh
curl -fsS "$BASE_URL/api/conversations/$CONVERSATION_ID" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" | jq '.data.status'

curl -fsS "$BASE_URL/api/conversations/$CONVERSATION_ID/prompts" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Run the tests you identified. Fix any failures, rerun the relevant tests, and summarize what changed."}'
```

The follow-up returns `{"status":"queued"}`. Run the stream command again to
watch the next turn. Only one turn can run at a time; an admission conflict
means you should wait for the current work to finish or interrupt it explicitly.

To read saved output without holding a stream open:

```sh
curl -fsS "$BASE_URL/api/conversations/$CONVERSATION_ID/events?blocks=true" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" | jq .
```

Events are paginated. If `meta.has_more` is true, pass `meta.next_cursor` as the
next request's `after` parameter. For reliable submission retries, add a unique
`Idempotency-Key` header to each create or follow-up request and reuse that key
with the same body only when retrying that submission.

## Example: build something and come back later

After the previous turn finishes, start a separate conversation. This works in
an empty workspace too:

```sh
BUILD_ID=$(curl -fsS "$BASE_URL/api/conversations" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"title":"Reading list tool","prompt":"Build a small Python command-line reading list tool in a new reading-list directory. It should add a URL, list saved URLs, and mark one as read. Use only the standard library, save data as JSON, and include usage instructions and tests."}' \
  | jq -er '.data.id')

curl -fsSN "$BASE_URL/api/conversations/$BUILD_ID/stream?blocks=true" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY"
```

Wait for completion and close the stream. Save `BUILD_ID` if you will use a new
shell; you can also find it later with `GET /api/conversations`.

You can restart the service while idle to try continuation. Run this management
command **inside the Sprite**:

```sh
managoat restart
managoat status
```

Back in your API client shell, use the same conversation ID:

```sh
curl -fsS "$BASE_URL/api/conversations/$BUILD_ID/prompts" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Add a search command to the reading list tool we built. Keep the same storage format, update the usage instructions, and test it."}'

curl -fsSN "$BASE_URL/api/conversations/$BUILD_ID/stream?blocks=true" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY"
```

The next turn resumes the saved runtime session, and the files remain in the
workspace. History also survives service crashes, but ambiguous in-flight work
is marked interrupted and is not automatically replayed. An explicit follow-up
can continue if the runtime session is still available.

## Control and everyday operation

To stop the current turn while keeping its conversation available for follow-up:

```sh
curl -fsS -X POST "$BASE_URL/api/conversations/$CONVERSATION_ID/interrupt" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY"
```

Use `POST /api/conversations/:id/terminate` to close a conversation permanently,
or `DELETE /api/conversations/:id` to remove its history. Neither removes project
files; interrupting work can leave partial edits.

For tool approvals, create a conversation with
`"permission_policy":{"default":"ask"}`. Answer permission requests through
`POST /api/conversations/:id/requests/:request_id` with
`{"option_id":"<offered option ID>"}`. The stream carries the runtime's permission
request and offered options. Unanswered requests time out after 300 seconds by
default and occupy the active turn slot while waiting. Policies can narrow the
installation's permissions, never widen them.

Run management commands inside the Sprite:

| Command | Purpose |
|---|---|
| `managoat status --json` | Inspect readiness, runtime availability, and admission capacity |
| `managoat logs` | Read operational logs |
| `managoat start`, `stop`, `restart` | Manage the API service |
| `managoat configure --file config.json` | Validate and apply configuration while idle |
| `managoat key rotate` | Replace the application key; update your clients afterward |
| `managoat backup --output backup.tar.gz` | Back up idle application state and runtime sessions; add `--workspace` for project files |
| `managoat uninstall` | Remove the service and executables while preserving state and workspace |

Configuration lives in `~/.local/share/managoat/config/config.json`, SQLite
history in `state/managoat.sqlite3` under the same root, and runtime files in
`runtime/`. `MANAGOAT_ROOT` overrides the application root. Backups omit API and
inference credentials but can still contain private conversation content.
Retained conversations depend on their original runtime, workspace, and system
instructions; changing those is not a way to migrate an existing session.
