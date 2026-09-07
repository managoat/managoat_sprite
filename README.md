# Managoat Sprite

Install a conversations API on a Sprite you already own. The service runs coding
agents on that computer, stores conversation history in SQLite, and exposes
Fountain-compatible HTTP and server-sent events.

Built with [Managoat.ACP](https://github.com/managoat/managoat_acp),
[Managoat.Runtimes](https://github.com/managoat/managoat_runtimes), and
[Managoat.Sandbox](https://github.com/managoat/managoat_sandbox).

## Installation

The initial release is under verification. Once its release assets are published,
run inside your Sprite with an inference key already exported:

```sh
curl -fsSL https://raw.githubusercontent.com/managoat/managoat_sprite/main/install.sh | sh -s -- \
  --runtime codex --credential-env OPENAI_API_KEY --workspace /home/sprite/project
```

Or use `--credential-file /path/to/key` to read a plain API-key file. `--runtime
claude` uses `ANTHROPIC_API_KEY`. The installer downloads a checksummed Linux
release containing Erlang, installs pinned agent tools in an application-owned
home, registers a Sprite Service, and checks authenticated HTTP readiness.
It does not require a Fountain account, external database, or build tools.

The application key is generated locally (or supplied as `MANAGOAT_API_KEY`):

```sh
managoat status
managoat key show
```

The Sprite's platform URL authentication is separate from the application key.
For a direct URL-plus-key endpoint, configure the Sprite URL with public platform
access during provisioning. Managoat's API still requires its bearer key. For
private development, use `sprite proxy 8080` from the provisioner's computer.
The installer never needs an organization-wide Sprites token.

## API

```sh
curl "$BASE_URL/api/conversations" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: first-conversation' \
  -d '{"agent_id":"default","prompt":"Inspect this project and explain how to run it."}'

curl -N "$BASE_URL/api/conversations/$CONVERSATION_ID/stream?blocks=true" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY"

curl "$BASE_URL/api/conversations/$CONVERSATION_ID/prompts" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Now run its tests."}'
```

The API includes agents, conversations, turns, paginated events, global and
conversation SSE, interruption, termination, deletion, and permission answers.
`GET /api/capabilities` describes the supported Fountain subset. Bearer auth
applies to all API routes. Configure explicit `cors_origins` to use a browser
client such as `fountain-template-chat` in API-key mode.

One configured agent and one shared workspace serve multiple conversations.
One turn runs at a time. Deleting a conversation preserves your Sprite and
project files. The service and agent share the same trust boundary; the agent
has access to the computer on which you install it.

## Persistence and operation

The default application root is `~/.local/share/managoat`; `MANAGOAT_ROOT`
overrides it. Configuration is `config/config.json`, the application key is
`config/client.key`, and SQLite is `state/managoat.sqlite3`. Secrets are stored
in private files and are excluded from ordinary command output.

A browser disconnect does not cancel work. Active turns hold a finite Sprite
task that is renewed while they run. Idle SSE clients should disconnect when
they have nothing to follow, since reconnecting clients can keep a Sprite awake.

After a service crash, history survives and ambiguous in-flight turns are marked
interrupted. An explicit follow-up resumes the saved runtime session. The
service does not automatically replay a prompt that may already have caused
external effects. It does not promise seamless mid-turn reattachment.

```text
managoat status [--json]
managoat doctor [--inference]
managoat logs
managoat start | stop | restart
managoat key show | rotate
managoat configure --file config.json
managoat backup --output backup.tar.gz [--workspace]
managoat upgrade --version VERSION
managoat uninstall
```

`doctor --inference` makes a small paid model request. A normal readiness check
only establishes local agent initialization. Backups omit application and
inference credentials by default. Uninstall preserves state and the workspace.

## Development

```sh
mix deps.get
mix check
python3 -m unittest discover -s test -p '*_test.py' -v
```

Linux release: `sh scripts/build-release.sh`. The release workflow builds
AMD64 and ARM64 archives on Ubuntu 24.04. The local test suite exercises a real
ACP peer against the libraries' ScriptedAgent and executes real subprocesses.

[The specification](docs/spec.md) defines the full release target; integration
verification is recorded in [the acceptance record](docs/acceptance.md).

Apache-2.0.
