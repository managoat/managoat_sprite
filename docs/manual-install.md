# Install on an existing Sprite

[Back to Managoat Sprite](../README.md)

## 1. Prepare an existing Sprite

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

## 2. Install Managoat

With `OPENAI_API_KEY` exported, run inside the Sprite:

```sh
curl -fsSL https://raw.githubusercontent.com/managoat/managoat_sprite/v0.1.0/install.sh | sh -s -- \
  --runtime codex --credential-env OPENAI_API_KEY --workspace /home/sprite/project

export PATH="$HOME/.local/bin:$PATH"
managoat status
```

The release bundles Erlang; installation does not need Elixir, Erlang, or a build
toolchain. [Build from source](development.md#build-a-linux-release) if you want to change Managoat.

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

## 3. Check readiness and connect

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
see the [acceptance record](acceptance.md) for remaining qualification.

Every Managoat bearer key grants owner access, including asking the agent to run
commands. The default tool policy is `auto_allow`; the agent and service share
the same computer and OS authority.
