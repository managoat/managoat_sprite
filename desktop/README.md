# Manasprites Desktop

A laptop control room for a fleet of Sprite agents. The application is Elixir +
Phoenix LiveView, with OTP supervising connections and work and Ecto/SQLite for
local state. The macOS shell is Tauri + ElixirKit, following the author's
`elixir-desktop-demo` prototype.

This is a separate Mix project. The existing Python CLI and Elixir service at the
repository root retain their own builds, dependencies, data and release format.

![Native macOS fleet overview with synthetic demo agents](../docs/screenshots/desktop-fleet.png)

![Conversation and project file inspection in native WebKit](../docs/screenshots/desktop-files.png)

[View the Git diff screenshot](../docs/screenshots/desktop-changes.png). All
screenshots use synthetic demo data from the native workflow test.

## Implemented

- Phoenix LiveView fleet board, agent navigation, conversations and local job history.
- Connect existing Manasprites services by URL or private Sprite connection, update their bearer keys, and remove
  local connections without deleting remote work.
- Discover Sprites through the saved platform token, including paginated accounts.
  Connect from a discovery result with its name and organization already filled in.
- Create a Sprite with a runtime, repository, model, instructions and approval
  policy; install the existing service and connect its authenticated endpoint.
  Fresh private Codex/Claude creation and public Codex creation passed live checks.
- Write-only Sprites, inference and GitHub credential settings; AES-256-GCM
  encryption in SQLite with a private local master-key file.
- Prompt, continue, stream output through active-work polling, answer agent tool
  approvals, interrupt work, and reopen locally cached turns and events.
  Switching agents opens their active conversation, or their newest conversation when idle.
- Observed approval requests appear in agent navigation and the fleet's Needs
  attention lane; acknowledged local answers disable their action buttons.
- Browse workspace directories and text files, review staged/unstaged Git diffs,
  and reopen cached previews beside the conversation. Inspection has its own OTP
  worker so it does not queue ahead of prompts or approval answers.
- A supervised OTP connection owner per agent and durable SQLite job admission.
  Ambiguous submissions require explicit review; they are never silently replayed.
  Idle agents receive no background polling, including after app restart.
- Native macOS WebKit window hosting an embedded OTP release.
- Random loopback port, per-launch authentication, same-origin WebSocket checks,
  CSRF protection and private local data files.
- Native-host/BEAM lifetime coupling through ElixirKit.
- macOS native-library relocation and ad-hoc signing during packaging.

Private relays, Codex file work and continuation, interruption, and file/Git
inspection passed live checks using the packaged backend. Two real Codex agents completed overlapping file work. Live approval answering also passed on a fresh service 0.1.1 installation.
Distribution checks remain open. Existing agents can be connected using their installed service bearer key
and either a service URL or a Sprite name and organization.
See the [product plan and verification record](../docs/desktop.md).

## Create an agent

Save your Sprites token and the runtime's inference key under **Keys & settings**.
Choose **Add a Sprite**, enter the organization matching that token, choose Codex
or Claude, and optionally supply an HTTPS repository, Git ref and instructions.
The saved GitHub key is used only when explicitly selected for the clone.

Creation installs service [0.1.1](https://github.com/managoat/manasprites/releases/tag/v0.1.1)
at `/home/sprite/project`, port 8080. Codex uses human approval review so offered
requests reach the service's configured ask/allow/deny policy. A fresh 0.1.1
installation passed the live approval round trip without an environment override.
Private access is the default: the app opens an authenticated platform relay for
each request and closes it afterward. Public URL access is also available; the
agent API still requires its generated bearer key. The Sprite remains private
until local service readiness succeeds. Authentication, readiness, runtime and API contract checks must
pass before the new connection is registered. Setup makes no inference request.

Jobs continue independently of the open view. A failed or interrupted operation
offers **Review complete · resume**. Review its error and any private remote setup
logs first. Resume checks the Sprite ID and operation ownership label; it does
not adopt an unrelated name or replace a known deleted Sprite. No error path
deletes a Sprite. Disconnecting the app may leave remote setup running; the
remote operation lock prevents a retry from running setup concurrently.
The original inference/service credentials remain encrypted
for retry; a repaired Sprites token can be used only for the same organization.
Temporary recovery credentials are removed after success. Removing a provider
key from settings does not discard an unfinished job's recovery snapshot.

## Connect an existing private agent

Save its organization's Sprites token in settings, then choose **Connect an
agent** → **Private Sprite**. Enter the organization, Sprite name, installed
service bearer key and port (8080 by default). The app records the Sprite ID and
refuses a same-name replacement until explicitly relinked. No platform URL change
or separate CLI tunnel is needed. Private requests require both the platform
token and the service key; neither is sent to the interface.
Alternatively, choose **Add a Sprite** → **Discover existing Sprites** and click
**Connect agent** on a result. The name and organization are filled in; enter
the installed service key and adjust its port if needed.

The request relay binds an ephemeral IPv4 loopback port, verifies platform TLS,
and forwards one TCP connection. It belongs to its OTP request owner, has a
90-second lifetime and a 20 MiB transfer budget, and closes on completion or owner
exit. Service responses retain their separate 16 MiB limit. Idle views open no
relays. Local socket tests cover ownership and cleanup; a live private Sprite
also reached `cold` and woke for a successful sync and workspace inspection.

## Inspect the workspace

Select an agent and use **Files** or **Changes** beside its conversation. The
**Workspace** button expands the inspector on a smaller laptop window. Refresh
reads the selected view once; there is no background workspace polling.

Agents created by the app already have a Sprite identity. For an existing URL
connection, **Link workspace** takes the Sprite name and organization. The app
checks the platform identity and verifies the installed service's key before
reading its configured workspace. Use **Change Sprite link** after an intentional
replacement; relinking invalidates old previews. A saved Sprites token for that
organization is required, including when conversations use a loopback tunnel.

The reader handles the default Manasprites installation under
`~/.local/share/managoat` inside the Sprite. File access stays inside its configured
workspace and refuses symlinks, Git internals and special files. Text previews
are limited to 128 KiB, directories to 1,000 entries and Git output to 128 KiB.
Binary files show metadata. Git commands have a ten-second deadline, disable
external diff/text conversion and filesystem-monitor commands, and leave the
working tree and index unchanged. Git inspection requires the workspace itself
to be a repository root; it does not inspect a parent repository.

Previews are cached in the laptop's private SQLite database as ordinary data.
Their timestamps indicate when they were read, and opening another window can
reuse them without waking the Sprite.

## Build and test on macOS

The app requires macOS 15 or later, matching the embedded runtime.

Verified build tools: Elixir 1.19.5 / OTP 28.4, Rust/Cargo 1.96.0, Tauri CLI 2.11.4, Python 3 (packaging
scripts only), and the Xcode command-line tools. The installed app embeds ERTS;
it does not need these tools or Python to run. Install the Cargo CLI with
`cargo install tauri-cli --version 2.11.4 --locked` before using the commands below.

```sh
cd desktop
mix deps.get
mix assets.build
mix check
cargo tauri build --bundles app --ci
python3 scripts/smoke-macos.py
python3 scripts/smoke-native-fleet.py
python3 scripts/package-macos.py
open src-tauri/target/release/bundle/macos/Manasprites.app
```

The native fleet probe drives the production WebKit window through credential
settings, attachment, two simultaneous approval waits, continuation, interruption,
private creation, file previews, staged/unstaged Git diffs, local removal and
restart. It runs three real local service processes with ACP ScriptedAgents,
a synthetic platform API and actual Python/Git subprocesses. Installation is
emulated at the service boundary. Its opt-in native hook accepts only loopback
origins and runs a fixed workflow; it does not load arbitrary scripts.

Pass `--screenshots ../docs/screenshots` to capture the synthetic walkthrough
with WebKit's own snapshot API. This captures only the application's webview and
does not require desktop screen-recording access. Normal launches take no snapshots.

Structured Codex billing errors and errors without an automatic retry now show
a turn warning and a fleet review marker, even if the service reports completion.
The source status stays intact. Warnings survive output pagination and remain
in history after a later clean turn clears the fleet marker.

The smoke test copies the app to a directory with spaces, starts the native
WebKit window with only `/usr/bin:/bin` on PATH, submits a real LiveView form,
restarts the app to verify SQLite persistence, and checks that its BEAM exits
after both termination and SIGKILL of the native host. It uses a temporary data
directory and synthetic workspace name, with no Sprite or model requests.

`package-macos.py` creates a ZIP, SHA-256 checksum and small verification report
under `desktop/dist/`. It verifies code signatures, embedded architectures,
minimum macOS versions and native-library references, rejects known local state files and escaping symlinks,
extracts the ZIP, and runs the native smoke test on that extracted app before
making the archive available. It also executes the embedded release launcher and
checks that Erlang distribution stays disabled. The report contains build
metadata, not account state or transcripts. This command does not publish files.

The [desktop CI workflow](../.github/workflows/desktop.yml) builds on separate
Apple Silicon and Intel macOS 15 runners, runs the integration checks and archive
smoke test, and uploads only verified ZIP/checksum/report files as temporary CI
artifacts. It requires no Sprites, inference or signing credentials. The corrected hosted Apple Silicon and Intel jobs passed all 24 desktop tests,
native fleet controls and extracted-archive checks. The downloaded Apple Silicon
app also passed native launch and lifecycle checks locally. See the
[acceptance record](../docs/desktop-acceptance.md) for source revisions.

`mix check` additionally runs the real Sprite HTTP service and ACP ScriptedAgent
to verify prompts, session continuation, LiveView permission answers,
interruption, authentication repair, lost-acknowledgement recovery, encrypted
credential persistence, cached history and the absence of idle polling. The root
service is a test-only dependency and is excluded from the desktop release.
Platform tests use a local HTTP/WebSocket fixture, the actual Sprites SDK, real
Python subprocesses, and the real ACP service. The creation test simulates the
remote installer boundary; it does not claim that a live Sprite was installed.
Inspector tests execute the actual remote reader against real files and Git,
including traversal/symlink refusal, binary and size limits, replaced identities,
cached views without network traffic, and ACP work during a held inspection.
Private-connection tests forward real HTTP and ACP work through WebSocket/TCP
relays, check owner-death cleanup and idle inactivity, and reject untrusted TLS,
invalid platform credentials and replaced Sprite identities.
The fleet concurrency test starts two separate service BEAM subprocesses, each
with its own SQLite state and actual ACP ScriptedAgent. It verifies simultaneous
work, independent approvals and interruption, agent switching, isolated history,
and cleanup of both process groups and listeners.
An additional test holds the real ACP answer write after HTTP acknowledgement:
the approval marker clears and buttons disable while the turn remains active.
Approval markers use cached requests and this app's acknowledged answers. A2A-capable
services publish durable permission-resolution events, so refreshed caches clear
another client's answer during an active turn. Older service versions may retain
the marker until the turn finishes.

Ad-hoc signing is for local builds. Developer ID signing/notarization remains a separate distribution gate;
hosted Apple Silicon and cross-machine launch checks pass, but this is not a published
desktop release. The initial packaging target is Apple Silicon macOS.
The embedded launcher disables Erlang distribution and crash dumps regardless of
inherited release settings; its distribution cookie is an unused fixed marker.

## Prepare a signed desktop release

This path requires a **Developer ID Application** identity in the build Mac's
Keychain and a configured `notarytool` Keychain profile. Neither is currently
available for this project's release qualification. Follow the
[Tauri signing setup](https://v2.tauri.app/distribute/sign/macos/) and
[Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
to configure them. Keep credentials outside the repository.

From `desktop/`, after the normal checks pass:

```sh
export APPLE_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
cargo tauri build --bundles app --ci
notary_dir=$(mktemp -d)
ditto -c -k --keepParent src-tauri/target/release/bundle/macos/Manasprites.app "$notary_dir/Manasprites.zip"
xcrun notarytool submit "$notary_dir/Manasprites.zip" --keychain-profile manasprites-notary --wait
xcrun stapler staple src-tauri/target/release/bundle/macos/Manasprites.app
python3 scripts/package-macos.py --require-notarized --output dist/notarized
```

The identity applies to both the embedded runtime and the native shell. Runtime
signatures include secure timestamps. The release packaging flag requires a
Developer ID signature, a stapled ticket and Gatekeeper acceptance on both the
source app and the extracted ZIP, then executes the native smoke test. The
report records that verification; ordinary local packages make no notarization
claim. An ad-hoc app has been tested and is refused before an archive is created.
The signed/notarized success path remains unverified until credentials are
available. These commands prepare artifacts without publishing a release.

## Develop without rebuilding the native shell

```sh
mix assets.build
MANASPRITES_DESKTOP_ROOT="$PWD/.state" \
  MANASPRITES_DESKTOP_READY_FILE=/tmp/manasprites-dev-ready.json \
  mix run --no-halt
```

The private ready file contains the one-launch URL. Open that URL locally and
keep the file out of logs and version control. Remove the ready file before
restarting this development command. Normal native launches do not write it.

Default data directory: `~/Library/Application Support/Manasprites`. The app
does not store state inside its bundle. `MANASPRITES_DESKTOP_ROOT` can select an
isolated data directory for development. A SQLite exclusive lock prevents two
app processes from owning the same local database.

The local master key is `vault.key` in that directory. Back it up together with
the database; without it, saved credentials cannot be decrypted. This is local
file protection, not macOS Keychain integration. Conversation history and prompt
job records are stored as ordinary SQLite data inside the private app directory.

The browser assets are copied from pinned Phoenix dependencies by
`mix assets.build`. `package.json` only identifies the build root to Tauri;
there is no separate JavaScript frontend framework or npm runtime dependency.

The existing `scripts/provision_remote.py` setup worker is compiled into the
desktop release as source and executed only inside the Sprite over SDK stdin.
It is shared remote installer tooling; the laptop backend remains Elixir and
the installed macOS app has no Python runtime requirement.
