# Laptop fleet application

Product direction recorded 2026-09-08. This extends Manasprites with a local
application; it does not replace the existing CLI or Sprite conversations API.

## Intended product

A Fountain-like personal workspace on the operator's laptop, focused on Sprites.
The operator supplies a Sprites token and inference keys locally, creates or
connects their agents, gives them work, follows output, answers tool approvals,
and returns to durable conversations and files. Different Sprites can work in
parallel; the existing service still admits one turn at a time per workspace.

Switchyard is the interaction reference: project/agent navigation, conversations,
an overview of active work, and a workspace inspector. This app does not require
a Fountain account, hosted control plane, GitHub OAuth application or server-side
organization credentials. Shared multi-user projects, browser/device previews,
and full parity with Switchyard are outside the initial personal fleet scope.

User-specified stack:

- Elixir + Phoenix LiveView for the laptop application.
- OTP for fleet connections, jobs, supervision, cancellation and recovery.
- SQLite through Ecto for local authoritative state.
- Evaluate Elixir Desktop; prove macOS native packaging before implementing the
  rest of the workflows.
- Preserve the existing CLI and Sprite service. The proposed Python desktop
  backend was removed when the stack direction changed.

## Native shell decision

The local `~/dev/jhgaylor/elixir-desktop-demo` prototype was examined read-only,
including its contributor instructions, release config and native lifecycle.
Despite the directory name, it uses **Tauri 2 + ElixirKit**, not the `desktop`
Hex library. The first packaging candidate follows that architecture: Rust owns
only the native window and embedded release lifetime; application logic stays
in Elixir. The native host opens the URL announced by the running endpoint,
rather than assuming port 4000 or shipping a fixed session secret.

The [Elixir Desktop project](https://github.com/elixir-desktop/desktop) provides
a wxWidgets backend for macOS and a browser fallback. This host has OTP wx and
wxWebView installed, but inspection of `wxe_driver.so` shows nine Homebrew
wxWidgets dynamic-library dependencies. Using that backend would require bundling
and qualifying that additional native stack. It remains an alternative, not a
claimed tested package. Tauri uses macOS WebKit and fits the supplied prototype.
[ElixirKit](https://github.com/livebook-dev/elixirkit) provides the release launch
and native/BEAM PubSub bridge, including shutdown when the native side disconnects.

The embedded release also needs its OpenSSL library bundled. Packaging follows
Mach-O dependencies, copies non-system libraries, rewrites install names, fixes
precompiled SQLite's builder-path library ID, signs nested code and then signs
the app. Native libraries and ERTS are part of the deliverable, not prerequisites
on the user's machine. The app requires macOS 15, matching the embedded runtime;
archive verification rejects binaries requiring a newer OS than the app declares. Python is used only by build/test scripts.

## Delivery gates

See the [acceptance audit](desktop-acceptance.md) for requirement-by-requirement
evidence and the external checks still needed.

1. **macOS packaging:** moved self-contained `.app`, actual native WebKit and
   LiveView connection, real UI mutation, SQLite restart persistence, no build
   tools on runtime PATH, private local listener, child-process cleanup on host
   exit and crash. This gate passes locally.
2. **Local authority:** durable credential settings, write-only secret inputs,
   no credentials in browser storage, logs or URLs; fleet token remains on the
   laptop, only the selected inference credential reaches its Sprite.
3. **Fleet lifecycle:** list/discover/import/create agents, resumable provisioning
   with durable job records, honest partial/error states and explicit retry.
   OTP owns jobs independently of the LiveView/window. Do not replay ambiguous
   remote mutations after a connection loss or application restart.
4. **Agent work:** create/list/continue conversations, live output and tool blocks,
   approval answers, interruption, history/reconnection and fleet-wide active-work
   status. Verify with the real ACP ScriptedAgent and local subprocesses, then
   real Sprites before claiming remote qualification.
5. **Switchyard workspace:** repository context and read-only files/changes;
   agents on separate Sprites can run concurrently. Idle views do not keep
   sleeping Sprites awake through indiscriminate polling.
6. **Distribution:** reproducible build instructions and CI, clean-Mac testing,
   Developer ID signing/notarization, and a release artifact. No credentials,
   account state, transcripts or test Sprite tokens in artifacts.

## Current verification

The desktop now connects existing installed services by URL or private Sprite
relay, using their service bearer key,
shows a fleet board and conversation workbench, and stores provider credentials,
agent connections, jobs and conversation history locally. Registry and
DynamicSupervisor own one connection process per agent; Task.Supervisor owns
linked request tasks. SQLite admits at most one unresolved prompt submission per
agent. Active conversations refresh automatically; idle agents refresh only on
an explicit user action. Closing a LiveView does not own or cancel its jobs.

Credential inputs are write-only. SQLite stores AES-256-GCM ciphertext, with the
master key in a mode-0600 file under the mode-0700 application directory. The
master key and database must be backed up together. Keychain integration is not
implemented. Prompts, job payloads and cached events are ordinary SQLite data in
that private directory. The native host suppresses runtime console output and
BEAM crash dumps. Credentials and local state are excluded from the app bundle.

The desktop suite passes twenty-four tests. It starts the actual Sprite HTTP service
and real ACP ScriptedAgent to exercise conversation creation, continuation,
permission answers through LiveView, interruption and authentication repair.
A test holds the HTTP acknowledgement after the actual service accepts a prompt,
kills the connection owner, and verifies that recovery marks the submission
unknown, prevents another prompt, and does not replay the accepted work.
A separate full desktop restart restores encrypted credentials and conversation
cache, then observes no idle HTTP traffic before or after an explicit refresh.
These are local integration results, not live-Sprite qualification.

A separate concurrency test launches two actual Sprite services in independent
BEAM subprocesses with distinct SQLite state and real ACP ScriptedAgents. Both
accept work and wait for approval simultaneously; answering one agent allows it
to finish while the other remains blocked on its own approval. Returning to the
other agent reopens its active conversation, which can be interrupted without
changing the completed agent's history. The test verifies separate conversation
caches and closes both owned OS process groups and HTTP listeners.

Cached approval requests now appear in agent navigation and the overview's
**Needs attention** lane. The marker is derived from the latest request in each
active turn and acknowledged local answer jobs, without additional remote
polling. A local acknowledgement disables the corresponding answer buttons and
clears the marker even while the turn is running. The real-service tests hold
the actual ACP answer write to verify that boundary, and verify two independent
agents' overview markers through completion and interruption. The existing
service does not expose permission-resolution state from another client during
an active turn; such an observed request can remain marked until the turn ends.
These are observed-request markers, not an authoritative cross-client pending
approval count. The original service and CLI contracts remain unchanged.

Discovery results now offer a **Connect agent** action that fills the private
connection form with the Sprite name and organization. When list metadata omits
the organization, discovery uses the saved token's organization. The operator
supplies the installed service bearer key; the form shows only the fields needed
for private or URL access. Agent navigation opens the active conversation, or
the newest conversation when idle, while the explicit new-conversation action
remains available. LiveView tests exercise discovery handoff, form switching,
connection verification and real ACP work.

The platform workflow now lists the token's Sprites with bounded pagination and
creates new agents from locally saved keys. Its Elixir supervisor runs up to four
platform jobs independently of LiveViews. Durable creation records preserve
configuration, ownership label and Sprite ID. The remote setup worker is shared
with the existing CLI, compiled as public source into the release, and executed
inside the Sprite over the official SDK's authenticated WebSocket stdin. Neither
the organization token nor secret values appear in remote command arguments.
The token's organization is checked before creation, using the documented
[organization/token/secret format](https://docs.sprites.dev/cli/authentication/).
The platform client follows the [Sprites REST API](https://sprites.dev/api/sprites)
with redirects and automatic retries disabled.

New Sprites start private. Private access is the default; public URL access remains
an explicit option. After local installation succeeds, the workflow applies
the selected access mode and verifies unauthenticated
rejection, authenticated readiness, runtime and API contract. It then registers
the agent and its encrypted bearer key in the local fleet. Failed work can resume
after explicit review; it reconciles identity rather than blindly creating a
second Sprite. Successful operations delete temporary recovery secrets. Failed
operations retain their encrypted original inference/service credentials, while
allowing a repaired platform token for the same organization.

The tests exercise multi-page discovery through LiveView, the creation form and
handoff to real ACP work, a lost create response, ownership/organization refusal,
token repair and recovery-secret cleanup. A local WebSocket fixture uses the real
Sprites SDK and actual subprocesses to verify stdin framing and cleanup when a
job exits. Another test executes the packaged remote setup source in an isolated
Python process. The creation test simulates remote installation; actual Linux
release installation from the desktop has not yet been qualified on a Sprite.

Private connections use the [Sprites TCP proxy protocol](https://sprites.dev/api/sprites/proxy).
A request-scoped OTP process owns a single loopback TCP relay and its authenticated
WebSocket. It verifies TLS, disables reconnect/retry, transfers accepted socket
ownership, and closes on request completion or owner death. Service requests ask
for connection closure; the app does not maintain idle tunnels. The relay limits
transferred data to 20 MiB and its lifetime to 90 seconds. A saved Sprite ID and
token organization are checked before each private service request. Existing
agents can be attached by name, organization, service key and port through the UI.

The pinned Sprites SDK 0.2.2 proxy implementation was inspected but is not used:
it disables TLS verification, misroutes accepted sockets to its acceptor process,
and does not transfer socket ownership to its forwarders. The desktop relay uses
Gun directly with verified TLS and explicit ownership. Local tests forward to the
actual Sprite service, exercise private creation and attachment followed by real
ACP work, prove idle/owner-death cleanup, and refuse an untrusted TLS endpoint,
rejected platform credentials and a same-name Sprite replacement. These tests do
not establish live platform sleep or cold-wake behavior.

The workspace inspector now browses directories and text files and renders Git
status plus staged/unstaged diffs beside conversations. It verifies the saved
Sprite ID and installed service key before reading the configured workspace.
Existing URL connections can be linked explicitly; replaced Sprites are refused
until relinked, and relinking invalidates prior previews. A separate connection
owner handles inspection jobs, so a slow read cannot block conversation requests.
Results persist in the private SQLite job cache and show their read timestamp.
Opening cached views makes no platform request; refresh is explicit.

The inspector uses an embedded Python reader only inside the Sprite. Filesystem
reads open path components relative to a held workspace directory and refuse
symlinks, traversal, Git internals and special files. Text/file previews and Git
output are capped at 128 KiB; directory listings stop at 1,000 entries. Git runs
against that exact workspace with optional locks, external diff/text conversion
and filesystem-monitor commands disabled. Tests execute real Python and Git
through SDK WebSockets, check the unchanged Git index, enforce bounds and identity
checks, and prove real ACP work proceeds while a workspace read is held. Live
checks now also verify a real Codex-generated file, Git status and diff through
the packaged backend; see the acceptance audit for the exact scope.

The workspace LiveView tests exercise authentication, cross-origin refusal,
real form submission through Ecto and PubSub updates to another LiveView.
The existing service passed `mix check` (30 tests); installer/CLI tests passed
(48 tests, one platform-specific skip) after the desktop was separated.

The macOS packaging smoke test passed on Apple Silicon, macOS 15.5 (24F74),
2026-09-08. It ran the actual moved `.app` from a canonical path containing
spaces with only `/usr/bin:/bin` on runtime PATH. Native WebKit connected to
LiveView, submitted the workspace form, and restored the saved name on a second
native launch. SQLite was mode 0600 under a mode-0700 directory. A second runtime
was refused access to the active database without disrupting the first. The BEAM
exited after both termination and SIGKILL of the native host, and the local
listener closed. Deep, strict ad-hoc code
signature verification passed. The build relocated one OpenSSL library and
signed 23 embedded Mach-O files.

The smoke test is `desktop/scripts/smoke-macos.py`. Its optional environment
switches automate the native UI and write only synthetic test evidence into the
test's temporary directory. Normal launches do not write probe files.

`desktop/scripts/package-macos.py` prepares a ZIP, SHA-256 checksum and metadata
report in the ignored `desktop/dist/` directory. Before emitting them it verifies
the bundle's signature, embedded architectures and native dependency paths,
refuses known state/database/key files and escaping symlinks, extracts the actual
ZIP, and runs the native smoke test against that extracted app. It also executes
the embedded release launcher with an inherited request for Erlang distribution
and requires a non-distributed node. The release now disables distribution in
its own environment template, in addition to the native host's settings, and
uses an unused cookie marker rather than shipping a generated distribution key.
The Apple Silicon ZIP passed this complete path locally on 2026-09-08, including
actual direct release startup with an inherited `sname` setting; the running node
remained `nonode@nohost`. The ZIP checksum was independently recomputed and matched
the report. This is a verified local artifact, not a notarized published release.

The separate `.github/workflows/desktop.yml` workflow specifies Apple Silicon
`macos-15` and Intel `macos-15-intel` runners, matching
[GitHub's runner architecture labels](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
It pins the tested Elixir/OTP, Rust and Tauri CLI versions, runs the desktop
integration suite, builds the app, and archives only after extracted native
verification. It uploads short-lived CI artifacts and does not publish a release.
`actionlint` passes locally. Hosted Apple Silicon and Intel jobs passed integration tests, native fleet
controls and extracted-archive checks after correcting the Cargo CLI invocation.
The downloaded ARM build also passed native lifecycle tests on the development
Mac. See the acceptance audit and PR checks for source revisions.

This proves local and hosted Apple Silicon/Intel packaging, including a
separate Mac runner and cross-machine archive launch. Developer ID
signing/notarization and published desktop artifacts remain unverified. Live public/private provisioning, Codex work and continuation, interruption,
file/Git inspection, concurrent work on two agents, and approval answering have
passed. The approval check exposed an adapter reviewer default; the service
patch release and other remaining checks are recorded in the acceptance audit. Initial desktop creation
supports a fixed workspace and service version, optional repository/ref, runtime,
model, instructions and approval policy; it does not yet expose arbitrary
bootstrap commands or environment imports. Existing services retain their own
inference configuration. The original CLI's lifecycle path remains unchanged.
