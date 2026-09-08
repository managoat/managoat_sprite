# Provision an agent from your computer

The `manasprites` CLI creates a Sprite, prepares its workspace, installs the released
Managoat service, and returns connection details. You do not need to open a Sprite
console to complete setup. The [CLI release](https://github.com/managoat/manasprites/releases/tag/cli-v0.2.0)
is distributed separately from the `v0.1.0` Sprite service.

## Install the host CLI

You need macOS or Linux, Python 3.9+, curl, and an installed, authenticated
[Sprites CLI](https://docs.sprites.dev/cli/commands/). Run `sprite login` to set up
your account. Manasprites uses that login through `sprite api` and `sprite exec`;
it does not copy the organization token to the agent's computer.

Install the released CLI:

```sh
curl -fsSL https://github.com/managoat/manasprites/releases/download/cli-v0.2.0/install-cli.sh | sh
export PATH="$HOME/.local/bin:$PATH"
manasprites sprite --help
```

The installer checks the archive's SHA-256 and installs into `~/.local`. Add
`~/.local/bin` to your shell profile's `PATH`. `manasprites --version` reports the
CLI version, which is independent of your Sprite service version.

For a different install location:

```sh
curl -fsSL https://github.com/managoat/manasprites/releases/download/cli-v0.2.0/install-cli.sh | sh -s -- --prefix /path/to/prefix
```

The executable is `manasprites`. Repeat the installer to reinstall or update its
own launcher. It preserves saved connections and keys and refuses to replace an unrelated `manasprites` executable.
Updating the CLI does not upgrade or reconfigure an existing Sprite.

For an offline install, download `install-cli.sh`, `manasprites.tar.gz`, and
`manasprites.tar.gz.sha256` from the same release, then run:

```sh
MANASPRITES_ARCHIVE="$PWD/manasprites.tar.gz" sh install-cli.sh
```

For development, `./bin/manasprites` runs from the repository, or install a checkout
with `python3 scripts/install-cli.py`. See [development](development.md).

## Describe your agent

Copy [agent.json](../examples/agent.json) and
[instructions.md](../examples/instructions.md) into the same directory, then edit
the JSON. A more typical application configuration looks like this:

```json
{
  "name": "my-project-agent",
  "org": "your-sprites-org",
  "url_auth": "public",
  "release": "0.1.0",
  "workspace": "/home/sprite/project",
  "repository": {
    "url": "https://github.com/your-org/your-project.git",
    "ref": "main",
    "token_env": "GITHUB_TOKEN"
  },
  "agent": {
    "runtime": "codex",
    "name": "Project agent",
    "instructions_file": "instructions.md",
    "permissions": {"default": "auto_allow"}
  },
  "env": ["DATABASE_URL", "APP_ENV"],
  "bootstrap": ["npm ci", "npm run build"],
  "bootstrap_timeout_seconds": 900,
  "cors_origins": ["http://localhost:5173"]
}
```

| Field | Meaning |
|---|---|
| `name`, `org` | Required, explicit Sprite name and organization. Setup never changes your active Sprite selection. |
| `url_auth` | Required: `public` for a direct URL protected by the Managoat bearer key; `sprite` to keep platform authentication and connect through a tunnel. |
| `release` | Service version without a `v` prefix; defaults to `0.1.0`. |
| `workspace` | Absolute project directory; defaults to `/home/sprite/project`. |
| `repository` | Optional HTTPS Git URL and ref. Omit it for an empty workspace. Ref defaults to `HEAD`; the initial checkout is detached. |
| `repository.token_env` | Optional host environment variable containing an HTTPS Git token. Omit for public repositories. |
| `repository.username` | Git token username; defaults to `x-access-token`. Set it when your Git host requires a different username. |
| `agent.runtime` | Required: `codex` or `claude`. Codex is the runtime with live qualification evidence. |
| `agent.model` | Optional `openai/model-id` or `anthropic/model-id`; otherwise the runtime default. |
| `agent.instructions_file` | Optional UTF-8 instructions file, resolved relative to the JSON file. |
| `agent.name`, `agent.permissions` | Agent display name and tool policy. Permissions default to `{"default":"auto_allow"}`. |
| `env` | Host variable names to import into bootstrap commands and persist for the agent. Values never belong in this JSON file. |
| `bootstrap` | Ordered Bash commands run in the workspace. Completed commands are recorded individually. |
| `bootstrap_timeout_seconds` | Per-command timeout; defaults to 900 seconds. Each command also has a 10 MiB output limit. |
| `port` | Service port inside the Sprite; defaults to 8080. |
| `cors_origins` | Exact origins allowed to use the API from a browser. Defaults to none. |

The runtime's inference variable (`OPENAI_API_KEY` or `ANTHROPIC_API_KEY`) is
imported automatically for the agent. It is available to bootstrap only if you
also list it in `env`. The Git token is provided to Git through an askpass helper
and is not stored in the clone URL, local provisioning record, or agent
environment unless explicitly included in `env` too. HTTPS redirects during
clone are refused; use the repository's canonical URL.

Only named environment values are sent to the Sprite, over the authenticated
exec connection's stdin. Process controls such as `HOME`, `PATH`, `CODEX_HOME`,
and Sprite platform credentials cannot be imported through `env`. Imported
agent values survive service restarts in Managoat's private credential store.
The agent runs with the same OS authority as that store; these controls do not
provide isolation from the agent itself.

## Create and connect

Export the inference key and any variables named in your configuration, then run:

```sh
manasprites sprite create --file /path/to/agent.json
```

For `url_auth: public`, setup finishes only after checking the external endpoint
for unauthenticated rejection, authenticated readiness, the selected runtime,
and SSE connection framing. The output includes the platform-assigned URL and
the path to your local client key. No paid inference probe is made.

```text
Managoat ready
URL:       https://<platform-assigned-host>
API:       https://<platform-assigned-host>/api
API key:   saved to <local-client-directory>/client.key
Inference: not probed (readiness makes no paid model request)
```

For scripts, `--json` prints only connection metadata to stdout; progress goes to
stderr. Keys and environment values are never included in that output:

```sh
manasprites sprite create --file /path/to/agent.json --json > connection.json
export BASE_URL="$(jq -r '.url' connection.json)"
export MANAGOAT_API_KEY="$(cat "$(jq -r '.api_key_file' connection.json)")"

curl -fsS "$BASE_URL/api/conversations" \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Inspect this project and explain what we should work on next."}'
```

From the directory containing `agent.json`, the host CLI can also load the saved
connection details and stream a conversation directly:

```sh
manasprites prompt "Inspect this project and explain what we should work on next."
manasprites prompt --continue "Start with the first improvement and run its tests."
```

Use the [conversation walkthroughs](conversations.md) for CLI options and HTTP
examples.

With `url_auth: sprite`, the result reports local readiness and
`external_access: unverified`, and includes a `proxy_command`. Run that command
in another terminal, use `http://127.0.0.1:<port>` as `BASE_URL`, and authenticate
with the same local key. This mode does not claim a publicly verified endpoint.

Retrieve and recheck connection details later with:

```sh
manasprites sprite status --file /path/to/agent.json --json
```

## Retry and recovery

Rerun the same `create` command after a transport, clone, download, or installation
failure. A generated ownership label and the recorded Sprite ID prevent retries
from creating duplicate computers or adopting an unrelated Sprite with the same
name. A deleted Sprite is not silently replaced. The clone is staged and renamed
into place; completed setup never fetches, resets, or overwrites subsequent edits.

A failed or interrupted bootstrap command may have caused partial effects. The
next attempt stops with `bootstrap_needs_review` instead of running it again.
Inspect its log and any still-running Sprite sessions, stop any remaining work,
and then explicitly retry that unfinished command:

```sh
manasprites sprite create --file /path/to/agent.json --retry-bootstrap
```

Earlier completed commands remain skipped. Bootstrap commands must be foreground
jobs; use Sprite Services for persistent applications. Timeouts and output-limit
failures kill the command's process group. A hard crash can leave detached work
with an uncertain outcome; `--retry-bootstrap` is your decision to rerun after
inspection, not an exactly-once guarantee.

Local state and the private client key live under
`~/.local/share/manasprites/<org>/<name>/`; `MANASPRITES_ROOT` overrides
that root. The key is mode 0600 and directories are mode 0700. Keep this directory
if you want to resume setup or recover connection details. A missing key or
changed configuration causes an explicit error, not silent key regeneration.
After successful setup, repeated `create` calls do not require provider variables
again and do not update imported environment values.

Remote setup records and bounded logs live under `~/.managoat-provision/`.
Logs can contain private command output; inspect them locally on the Sprite and
do not publish them. Neither success nor failure deletes a Sprite automatically.

This command handles initial provisioning and retry. Updating an existing agent,
rotating environment values, migrating retained conversations, fleet management,
and restoring lost local provisioning records are separate operations. Use the
[service management commands](guide.md#persistence-and-operation) for the installed
service. Existing `v0.1.0` backups omit credentials, including imported environment
values; supply those again when restoring.

## A2A access after provisioning

The 0.1.2 source candidate adds opt-in A2A to the installed service. Provisioning
continues to use its pinned published release and existing URL-auth defaults.
After installing an A2A-capable release, verify the platform-returned HTTPS
origin against the installed service and apply the complete service configuration
with managoat configure --file PATH, including the a2a object documented in
[a2a.md](a2a.md). This preserves the service key and conversation state.
origin_verified records the operator's verification; it performs no network
probe. Changing a2a.ingress describes existing platform access and does not
change it. Private callers still need their own platform/network access.

A2A is never enabled implicitly by creating a Sprite, connecting the desktop or
copying an agent card URL. The desktop refreshes /api/capabilities explicitly
to display the configured URL and access requirements; older releases show
Upgrade required. Card URLs never include the service key or organization token.
