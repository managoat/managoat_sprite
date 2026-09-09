# Manasprites

A desktop app for running a fleet of coding agents on [Sprites](https://sprites.dev).
Give agents work, follow their progress, answer approvals, and review their files
and Git changes from one place. Each agent works in its own persistent cloud
workspace while you manage it from your laptop.

![Manasprites fleet overview showing two agents awaiting approval](docs/screenshots/desktop-fleet.png)

## Work with your agents

- **Create or connect agents.** Add a Sprite with a repository, runtime and
  instructions, or connect an existing agent.
- **Keep work moving.** Send tasks to different agents, see which are working or
  need attention, answer tool approvals, and interrupt a turn when needed.
- **Pick up where you left off.** Reopen conversations and send follow-ups in the
  same workspace.
- **Review the results.** Browse project files and inspect staged and unstaged
  Git changes beside the conversation.

![Conversation workbench with a project file preview](docs/screenshots/desktop-files.png)

<details>
<summary>See Git changes</summary>

![Conversation workbench with an unstaged Git diff](docs/screenshots/desktop-changes.png)

</details>

Screenshots show the running native macOS app with synthetic demo agents.

## Try the macOS preview

The preview requires **macOS 15 or later** and currently needs to be built from
source. Follow the
[macOS build instructions](desktop/README.md#build-and-test-on-macos) to build
and open `Manasprites.app`. A signed, notarized desktop download is still pending.

Once the app is open:

1. Save your Sprites token and inference API key in **Keys & settings**.
2. Choose **Add a Sprite**, select a runtime, and optionally add a repository.
   Use **Connect an agent** if you already have an installed Manasprites agent.
3. Open the agent, give it a task, and follow its conversation and workspace.

You bring your own Sprites and inference accounts. The app saves connections,
credentials and cached history locally; the agents and their project files live
on Sprites. See the [desktop guide](desktop/README.md) for setup and usage details.

## Preview status

Native macOS builds and workflow checks have passed on Apple Silicon and Intel. Live Codex
checks cover public/private creation, coding tasks, follow-ups, interruption,
cold wake, file/Git inspection, and overlapping work on two agents. Live approval
answering passed on a fresh service installation.

Service 0.1.2 supports opt-in A2A access: trusted agents can discover
an agent card, submit tasks, stream results and follow up while the laptop is
closed. Live Codex qualification includes owner approval after reopening and
conversation continuity across a service restart. See the [A2A guide](docs/a2a.md)
for configuration and access requirements. The installer and desktop provisioning
default to this [published preview release](https://github.com/managoat/manasprites/releases/tag/v0.1.2).

Funded Claude inference and desktop distribution remain open. The
[acceptance record](docs/desktop-acceptance.md) separates verified behavior from
remaining work.

## Development

The laptop app uses **Elixir + Phoenix LiveView**, OTP for fleet connections and
jobs, and **SQLite/Ecto** for local state. Tauri + ElixirKit provides the native
macOS shell and embeds the Elixir runtime.

- [Desktop development and build guide](desktop/README.md)
- [Architecture and delivery plan](docs/desktop.md)
- [Sprite service development](docs/development.md) and [API specification](docs/spec.md#http-contract)
- [Optional Fountain-compatible host API](docs/fountain-api.md) for Sprites with Codex/Claude
- [Optional CLI guide](docs/cli.md) for terminal workflows and scripts

Built with [Managoat ACP](https://github.com/managoat/managoat_acp),
[Runtimes](https://github.com/managoat/managoat_runtimes), and
[Sandbox](https://github.com/managoat/managoat_sandbox). Apache-2.0.
