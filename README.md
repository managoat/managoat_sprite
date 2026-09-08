# Managoat Sprite

**Stand up a persistent coding agent with a conversations API.**

Describe your agent and project in a config file. Run one command to create a
Sprite, clone the repository, run setup, and get back a URL with an API key.
Send a prompt, watch the agent work, and come back for a follow-up with your
files and conversation history still there.

- **Build your own agent app.** Connect through HTTP and live event streams.
- **Keep the conversation going.** Resume context across turns and service restarts.
- **Stay in control.** Choose tool permissions and interrupt work.

Your Sprite. Your workspace. One active turn, multiple conversations.

## Quick tour

Managoat runs on a [Sprite](https://sprites.dev), a persistent Linux computer.
The CLI on your computer creates the Sprite, prepares its workspace, and starts
the conversations service. The service runs Codex or Claude in that workspace
and exposes the agent through an authenticated HTTP API. You can also install
the service on a Sprite you already have.

| Piece | What it does |
|---|---|
| Provisioning config | A JSON file describing the Sprite, agent, repository, environment, and bootstrap commands |
| Agent | The configured Codex or Claude runtime, exposed as agent `default` |
| Workspace | The project directory where the agent reads files, edits code, and runs commands |
| Conversation | A saved runtime session with its own history and follow-up context |
| Turn | One prompt and the work it triggers; only one turn runs across the installation at a time |
| Events | Durable text, tool output, and lifecycle updates, available as JSON history or live server-sent events (SSE) |

Conversations have separate sessions but share the same files. Creating or deleting
one does not create or destroy a Sprite. There is no bundled web UI; use the API
from a terminal, your own app, or a compatible Fountain chat client.

> **Preview release:** [v0.1.0](https://github.com/managoat/managoat_sprite/releases/tag/v0.1.0)
> provides Linux AMD64 and ARM64 downloads. Codex has passed live installation,
> inference, tools, and continuation checks; Claude still needs live qualification.
> See the [acceptance record](docs/acceptance.md) for verified behavior and the
> [specification](docs/spec.md) for the full target and remaining work.

## Setup

### 1. Install the CLI on your computer

You need macOS or Linux, Python 3.9+, Git, and an authenticated
[Sprites CLI](https://docs.sprites.dev/quickstart/). Install the Sprites CLI and
run `sprite login` first. The API examples below also use `curl` and `jq`.
You do not need Elixir or Erlang to provision an agent.

The host CLI is available from this repository; the already-published `v0.1.0`
service archives predate it. Clone the current source and install:

```sh
git clone https://github.com/managoat/managoat_sprite.git
cd managoat_sprite
python3 scripts/install-cli.py
export PATH="$HOME/.local/bin:$PATH"
managoat sprite --help
```

If you already have this checkout, start with the Python command. The installer
copies the CLI into `~/.local`, so it keeps working if you move the checkout.
Add the `PATH` setting to your shell profile to keep the command available.

### 2. Describe your agent and project

Copy the example config and instructions into your own directory:

```sh
export AGENT_DIR="$HOME/.config/managoat/my-project"
mkdir -p "$AGENT_DIR"
cp examples/agent.json examples/instructions.md "$AGENT_DIR/"
```

Edit `agent.json` before running setup:

| Setting | What to choose |
|---|---|
| `org`, `name` | Your Sprites organization and a new Sprite name |
| `url_auth` | `public` for a direct URL protected by Managoat's bearer key, or `sprite` for private access through a tunnel |
| `agent` | Codex or Claude, a display name, instructions, and tool permissions |
| `repository` | An HTTPS Git URL and ref; omit this object to start with an empty workspace |
| `env` | Names of exported variables to import, such as `["APP_ENV", "DATABASE_URL"]`; keep their values out of the JSON |
| `bootstrap` | Ordered Bash commands to prepare the project, such as `["npm ci", "npm run build"]` |

The [example config](examples/agent.json) clones this repository at `v0.1.0` and
runs `git status --short`. Replace those settings with your project and its setup
commands. Edit `instructions.md` to tell the agent how to work on it. Bootstrap
commands run in the configured workspace before the service starts.

Export `OPENAI_API_KEY` for Codex, or `ANTHROPIC_API_KEY` for Claude, along with
any variables named in `env`. The inference key is imported automatically for
the agent. In an interactive **Bash** shell, you can enter it without putting
its value in shell history:

```bash
read -rsp 'OpenAI API key: ' OPENAI_API_KEY; printf '\n'
export OPENAI_API_KEY
```

The inference key pays for model requests. Managoat generates a separate
application key for clients of your conversations API. See the
[full configuration reference](docs/provisioning.md#describe-your-agent) for
private Git repositories, model selection, CORS, and bootstrap timeouts.

### 3. Create the Sprite and connect

Run on your computer, with the variables from the previous step still exported:

```sh
managoat sprite create --file "$AGENT_DIR/agent.json" --json > "$AGENT_DIR/connection.json"

export BASE_URL="$(jq -r '.url' "$AGENT_DIR/connection.json")"
export MANAGOAT_API_KEY="$(cat "$(jq -r '.api_key_file' "$AGENT_DIR/connection.json")")"
```

The command creates the Sprite, clones your repository, runs bootstrap commands,
installs the pinned service release, and waits for readiness. Progress goes to
stderr; `connection.json` contains the assigned URL and local key-file path,
without the key value. Setup makes no paid model request.

With `url_auth: public`, setup also verifies authenticated access and initial SSE
streaming through the public URL. With `url_auth: sprite`, run the returned
`proxy_command` in a second terminal and keep it open, then set `BASE_URL` to
`http://127.0.0.1:8080` (or your configured port). Private mode reports external
access as unverified; the Managoat key alone cannot unlock a private Sprite URL.

Check the API from the same client shell:

```sh
curl -fsS "$BASE_URL/readyz" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" | jq .

curl -fsS "$BASE_URL/api/agents" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" | jq .
```

You are ready for the conversation examples below. Every Managoat bearer key
grants owner access, including asking the agent to run commands. The example
uses `auto_allow` tool permissions; choose `ask` if you want to answer tool
permission requests through the API.

To check the deployment later, run
`managoat sprite status --file "$AGENT_DIR/agent.json" --json`. Rerunning `create`
with the same config preserves the Sprite, key, completed setup, and workspace
edits. This is initial provisioning and recovery, not a configuration updater.
A failed bootstrap step requires inspection and an explicit `--retry-bootstrap`;
see [retry and recovery](docs/provisioning.md#retry-and-recovery).

### Alternative: install on an existing Sprite

<details>
<summary>Manual installation, prerequisites, and connection options</summary>

#### 1. Prepare an existing Sprite

To install manually on an existing Sprite, use the steps below.

On your computer, install and authenticate the Sprites CLI using the
[Sprites quickstart](https://docs.sprites.dev/quickstart/). Then create a Sprite
or select one you already have:

```sh
# Skip creation if you already have a Sprite.
sprite create my-agent
sprite use my-agent
sprite console
```

The remaining installation commands run **inside the Sprite**. Choose a workspace
such as `/home/sprite/project`; clone your project there first if you have one.
The installer creates a missing directory and preserves existing files. It does
not install your project's dependencies or run its setup scripts automatically.

You need:

- An inference API key: `OPENAI_API_KEY` for Codex, or `ANTHROPIC_API_KEY` for Claude.
  Interactive CLI logins are not imported.
- Node.js and npm on `PATH`, plus `curl`, Python with `tarfile` extraction-filter
  support (Python 3.12+ works), `tar`, `sha256sum`, and `flock`.
- A writable workspace, disk space for the release and agent tools, and a free
  port 8080. The default disk reserve is 256 MiB.

Supply the inference key through your provisioning environment or a private
plain-text file. In an interactive Bash shell, you can enter it without adding
the value to shell history:

```bash
read -rsp 'OpenAI API key: ' OPENAI_API_KEY; printf '\n'
export OPENAI_API_KEY
```

This key pays for model requests. Managoat generates a separate application key
for clients of your conversations API.

#### 2. Install Managoat

With `OPENAI_API_KEY` exported, run inside the Sprite:

```sh
curl -fsSL https://raw.githubusercontent.com/managoat/managoat_sprite/v0.1.0/install.sh | sh -s -- \
  --runtime codex --credential-env OPENAI_API_KEY --workspace /home/sprite/project

export PATH="$HOME/.local/bin:$PATH"
managoat status
```

The release bundles Erlang; installation does not need Elixir, Erlang, or a build
toolchain. [Build from source](#build-a-linux-release) if you want to change Managoat.

The installer verifies the archive, installs pinned agent tools in an
application-owned home, saves the selected credential, creates the API key, and
starts a persistent Sprite Service named `managoat`. It checks authenticated
HTTP readiness and local agent initialization before returning. You can exit
the installation shell afterward.

Useful installer options:

| Option | Use |
|---|---|
| `--credential-file /path/to/key` | Read the inference key from a file instead of an exported variable |
| `--model provider/model-id` | Select a model explicitly; otherwise use the runtime default |
| `--cors-origin http://localhost:5173` | Allow a browser app at this exact origin; repeat for more origins |
| `--port 8081` | Change the API listening port |
| `--no-http-route` | Leave Sprite HTTP routing to an existing gateway |

Another service owning Sprite HTTP routing causes `http_service_conflict`.
Changing the port does not resolve routing ownership; use `--no-http-route` when
you intend to configure your own gateway.

#### 3. Check readiness and connect

For the examples below, use a shell **inside the Sprite** with `curl` and `jq`
installed:

```sh
export BASE_URL=http://127.0.0.1:8080
export MANAGOAT_API_KEY="$(managoat key show)"

curl -fsS "$BASE_URL/readyz" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" | jq .

curl -fsS "$BASE_URL/api/agents" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" | jq .
```

Readiness does not make a model request or verify provider billing. To check
inference credentials with a small paid request, run `managoat doctor --inference`.

To use the same examples **from your computer**, run `sprite proxy 8080` in a
separate local terminal and keep it open. In your client terminal, set `BASE_URL`
to `http://127.0.0.1:8080` and load the application key from the selected Sprite:

```sh
export BASE_URL=http://127.0.0.1:8080
export MANAGOAT_API_KEY="$(sprite exec -- /home/sprite/.local/bin/managoat key show)"
```

For direct access, `sprite config update --url-auth public` enables public
platform access; use the actual URL shown by `sprite info` as `BASE_URL`.
Managoat still requires its bearer key. A private Sprite URL has a separate
platform authentication layer that the Managoat key cannot satisfy. See
[Sprites HTTP access](https://docs.sprites.dev/working-with-sprites/).
Authenticated public access and initial SSE streaming have passed live checks;
see the [acceptance record](docs/acceptance.md) for remaining qualification.

Every Managoat bearer key grants owner access, including asking the agent to run
commands. The default tool policy is `auto_allow`; the agent and service share
the same computer and OS authority.

</details>

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

## Development and reference

For local development, install Elixir 1.19 and a compatible Erlang/OTP toolchain,
then run:

```sh
mix deps.get
mix check
python3 -m unittest discover -s test -p '*_test.py' -v
```

The tests use the real ACP ScriptedAgent and real local subprocesses. Live Sprite
checks are tracked separately from local test results. The Linux watchdog test
requires Linux; it is skipped on macOS.

### Build a Linux release

The release workflow builds on Ubuntu 24.04 with Erlang/OTP 28.1 and Elixir 1.19.2.
Install those tools, Git, and a C/C++ build toolchain on your Linux build machine:

```sh
git clone https://github.com/managoat/managoat_sprite.git
cd managoat_sprite
mix deps.get
mix check
python3 -m unittest discover -s test -p '*_test.py' -v
sh scripts/build-release.sh
```

The build writes an archive and adjacent `.sha256` file under `dist/`. To try it,
copy both files to a Sprite with the same CPU architecture, then run from a source
checkout inside the Sprite with your inference credential exported:

```sh
# Use managoat-linux-arm64.tar.gz on an ARM64 Sprite.
MANAGOAT_ARCHIVE="$PWD/dist/managoat-linux-amd64.tar.gz" \
  sh install.sh --runtime codex --credential-env OPENAI_API_KEY \
  --workspace /home/sprite/project
```

Set `MANAGOAT_ARCHIVE` to the actual archive path if you copied it elsewhere.
A macOS release cannot be installed on a Linux Sprite. The build machine needs
Elixir and Erlang; the target Sprite does not.

Release tags run both architecture test/build jobs and stage a draft GitHub
release. Verify the archives and a clean Sprite installation before publishing
the draft. The initial `v0.1.0` distribution is marked as a prerelease while the
remaining acceptance gates are open.

- [Provisioning and configuration](docs/provisioning.md): host CLI, environment import, private Git, and setup recovery.
- [Setup and operation](docs/guide.md): configuration, backup/restore, upgrades, and client integration checks.
- [API contract](docs/spec.md#http-contract) and [OpenAPI document](priv/openapi.json): endpoints, envelopes, events, and error semantics.
- [Acceptance record](docs/acceptance.md): executed checks and remaining release gates.
- [Specification](docs/spec.md): product scope, architecture, persistence, and recovery target.

Built with [Managoat ACP](https://github.com/managoat/managoat_acp),
[Runtimes](https://github.com/managoat/managoat_runtimes), and
[Sandbox](https://github.com/managoat/managoat_sandbox). Apache-2.0.
