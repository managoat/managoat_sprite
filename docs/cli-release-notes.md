# Managoat CLI 0.1.0 (preview)

Install the CLI on macOS or Linux without cloning the repository:

```sh
curl -fsSL https://github.com/managoat/managoat_sprite/releases/download/cli-v0.1.0/install-cli.sh | sh
export PATH="$HOME/.local/bin:$PATH"
```

Requires Python 3.9+ and curl. Provisioning also requires an authenticated
Sprites CLI; supply an inference API key when creating your agent.

```sh
managoat sprite create --file agent.json
managoat prompt "Build a reading-list CLI and test it."
managoat prompt --continue "Add search."
```

The host CLI creates a Sprite, clones an optional repository, imports selected
environment variables, runs bootstrap, and installs the pinned Sprite service.
It saves connection details locally and streams conversations with `prompt`,
`conversations`, and `watch`.

One Python archive supports macOS and Linux. The installer verifies its SHA-256,
installs into `~/.local`, and atomically updates its own launcher. Use
`sh -s -- --prefix /path/to/prefix` after the pipe for another location. Repeating
the command updates the CLI while preserving saved Sprite connections.

This release versions the host CLI separately from the Sprite service, which
remains pinned to `v0.1.0`. It does not update an existing agent or service.
Tool permission requests are displayed; answering them still uses the HTTP API.
Codex has live inference qualification; Claude qualification remains pending.

See [setup](https://github.com/managoat/managoat_sprite/tree/cli-v0.1.0#setup),
[configuration](https://github.com/managoat/managoat_sprite/blob/cli-v0.1.0/docs/provisioning.md),
and the [acceptance record](https://github.com/managoat/managoat_sprite/blob/main/docs/acceptance.md).
