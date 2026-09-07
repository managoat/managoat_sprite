# Managoat Sprite

**Give your Sprite a conversations API.**

Send a prompt. Watch an agent edit code, run commands, and work on your project.
Come back for a follow-up with your files and conversation history still there.

- **Build your own agent app.** Connect through HTTP and live event streams.
- **Keep the conversation going.** Resume context across turns and service restarts.
- **Stay in control.** Choose tool permissions and interrupt work.

Your Sprite. Your workspace. One active turn, multiple conversations.

## Install

> **Release preview:** Codex has passed live Sprite tests. Packaged downloads
> aren't published yet, so the install command below is not live yet.
> [See what's verified →](docs/acceptance.md)

Once releases are available, run this inside your Sprite with `OPENAI_API_KEY` exported:

```sh
curl -fsSL https://raw.githubusercontent.com/managoat/managoat_sprite/main/install.sh | sh -s -- \
  --runtime codex --credential-env OPENAI_API_KEY --workspace /home/sprite/project
```

The installer sets up the agent, starts the API, and creates your API key.

## Put your agent to work

Inside your Sprite, after installation:

```sh
export MANAGOAT_API_KEY="$(managoat key show)"

curl http://localhost:8080/api/conversations \
  -H "Authorization: Bearer $MANAGOAT_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Run the tests in this project and fix any failures."}'
```

Use the returned conversation ID to stream progress, send follow-ups, or answer
permission requests. [See the API examples →](docs/guide.md#api)

Connect from your computer with `sprite proxy 8080`, or configure public Sprite
URL access and connect directly with your Managoat API key.

[Setup & operation](docs/guide.md) · [API contract](docs/spec.md#http-contract) · [Development](docs/guide.md#development)

Built with [Managoat ACP](https://github.com/managoat/managoat_acp),
[Runtimes](https://github.com/managoat/managoat_runtimes), and
[Sandbox](https://github.com/managoat/managoat_sandbox). Apache-2.0.
