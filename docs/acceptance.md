# Acceptance record

Updated 2026-09-07. This is a working implementation under qualification, not
an accepted or published v0.1 release. No hosted installer or public release
asset is claimed to exist yet.

## Executed checks

| Check | Result |
|---|---|
| Elixir `mix check` | 25 tests cover real ACP ScriptedAgent, HTTP auth/CORS, continuity, normalized blocks, idempotency, pagination, permissions, concurrent admission, recovery, cancellation, output budget, unavailable task hold, subprocess behavior, immutable launch definitions, policy tightening, degraded readiness and missing-database startup guards |
| Python management tests on macOS | 16 pass; Linux watchdog test skipped on macOS |
| Python tests on Linux | All 17 pass, including real occupied-port detection, installer failure preservation, degraded status parsing, and the watchdog with detached grandchildren, restart, shutdown cleanup and split-write credential redaction |
| Release packaging | Bundled ERTS release built on x86_64 Linux; no Elixir compilation required by the installer |
| Clean Sprite install | Verified archive supplied through `MANAGOAT_ARCHIVE`; installer imports a credential file, provisions Codex, creates the service and returns authenticated readiness without manual repair |
| Real paid inference | `managoat doctor --inference` completed using the supplied OpenAI credential on both the build Sprite and a second clean Sprite |
| Real continuation after service restart | A later turn recalled a token given before restart, with no file-based memory; provider usage reported cached context |
| Real tool execution | Agent wrote the requested file inside the configured workspace; normalized tool blocks appeared; conversation deletion preserved that file |
| Real BEAM SIGKILL during a tool | API restarted; turn became `interrupted` with `execution_outcome_unknown`; owned `sleep` process was gone before recovery; completion sentinel was absent; prompt was not replayed |
| Existing template client through private tunnel | Actual `FountainClient` and SSE parser passed auth, CORS preflight, agent discovery, create, history, global streaming, follow-up context, exclusive cursor replay and interruption |
| Management fault injection | Consistent backup/restore retains history, session files and optional workspace while omitting keys; failed download, migration and candidate health checks retain or restore the previous release/database |
| Live readiness diagnostics | Updated test service reports installed, process reachable, API ready, schema ready, runtime available, local initialization verified at install, free admission capacity and external access unverified; no paid inference was needed |

Client source revision: `fountain-template-chat`
`c9ba5d2f13cdacdf21da9e0a7460391b1406d882`. Run
`scripts/check-client.ts` against that checkout to exercise its actual client
code. This is a client-library integration check; a browser UI walkthrough is
still outstanding.

The clean-install archive used Codex CLI `0.153.4`, OTP `28.1`, and Elixir
`1.19.2`, with the library versions pinned by `mix.lock`. Its SHA-256 was
`9e4289cccc09b0af14ee6bc38908f02c761d23bf8b8fe1a7eaa6770cb145c94a`.
This is a development artifact, not a signed or published release. Later source
changes receive their own build/test checks and must be qualified together
before tagging a release.

## Findings incorporated into the implementation

- Sprite services have a minimal environment: use an explicit shell and pin
  the real Node installation path instead of invoking its NVM wrapper with an
  application-owned npm prefix.
- `erlexec` reports linked process exit status in encoded form; decode it and
  wait for process cleanup before releasing the active slot.
- Restarting only the BEAM is insufficient. A stable Linux subreaper supervisor
  must own the instance lock and reap orphaned tools before restarting the API.
- Persist the ACP session ID inside the prompt writer barrier, before marking
  dispatch intent or writing prompt bytes.
- Incremental text can split a remembered token across several blocks. Clients
  and acceptance checks must concatenate deltas rather than require one block
  to contain the entire response.
- Download artifacts through normal HTTP and compare against the checksum
  produced by the build. A binary transfer through the Sprites exec CLI lost
  data; this was a test-transfer failure, not a valid installable archive.

## Remaining release gates

The full contract remains [the specification](spec.md). In particular:

- Public repository publication, CI on GitHub, AMD64/ARM64 release artifacts,
  and a clean install directly from the eventual public distribution URL.
- Claude real inference, permission and continuation parity. Only an OpenAI
  credential was supplied for live provider tests; Claude is implemented but
  is not qualified by these results.
- Direct Sprite URL access, externally streamed first bytes, a browser UI
  walkthrough, and observed idle sleep/cold wake.
- The full fault matrix at dispatch, permission-answer and completion
  boundaries; renewal failures; slow readers; corrupt sessions and database;
  disk exhaustion; and real maintenance failure tests on a Sprite.
- Final audit of remaining installer diagnostics, database recovery diagnostics
  and all resource bounds against the specification.

Launch definitions now have durable `agents` snapshots referenced by each
conversation and turn. Pre-release history created before these snapshots
existed remains readable but cannot prove its original launch configuration;
follow-up returns `configuration_snapshot_unavailable` instead of inventing
one. This affects development installations, not a previously published release.
The snapshot implementation passed another live Codex sequence: three completed
turns, context recall after service restart, tool execution, cursor replay and
workspace preservation after conversation deletion.

Local and live checks above establish the tested behavior only; they do not
stand in for these remaining gates.
