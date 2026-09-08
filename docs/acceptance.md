# Acceptance record

Updated 2026-09-08. [v0.1.0](https://github.com/managoat/managoat_sprite/releases/tag/v0.1.0)
is the initial preview distribution, with Linux AMD64 and ARM64 archives and
checksums. Publishing this prerelease does not mean the full v0.1 specification
has passed acceptance. The source is public at
[managoat/managoat_sprite](https://github.com/managoat/managoat_sprite).

## v0.1.0 distribution verification

The [release workflow](https://github.com/managoat/managoat_sprite/actions/runs/34192825292)
passed on Linux AMD64 and ARM64 at source commit `9d4deef`. Each architecture ran
`mix check` (27 tests), all 17 Python management/watchdog tests, and an extracted
release runtime check. Archive versions matched tag `v0.1.0`; both downloaded
archives matched their published SHA-256 files and contained release payloads
without local configuration or account state.

A clean x86_64 Sprite installed the draft archive successfully. After publication,
a second clean Sprite ran the tagged public installer with no `MANAGOAT_ARCHIVE`
override. It downloaded and verified the GitHub release, provisioned Codex, and
started the API without manual repair. Executed checks verified unauthorized API
rejection, authenticated readiness, ACP initialization, agent/capability discovery,
workspace preservation, private client-key file permissions, and readiness/key
preservation after a service restart.

These fresh-install checks used a placeholder inference credential and made no
model requests. Paid inference and continuation evidence below comes from the
earlier development builds, not a fresh paid probe of these release archives.
Live ARM64 Sprite installation and direct URL access remain unverified.

| Archive | SHA-256 |
|---|---|
| `managoat-linux-amd64.tar.gz` | `d19c613be077439ec0604872df286725fb60b2a1c71eef08a1e7f906f6c0a294` |
| `managoat-linux-arm64.tar.gz` | `34f881940eec7731147a9c745d759114c13c0067d0efb249ece38a3b919c5000` |

## Earlier implementation qualification

| Check | Result |
|---|---|
| Source publication | Public GitHub repository created and committed source pushed; repository visibility verified as PUBLIC |
| Elixir `mix check` | 27 tests cover real ACP ScriptedAgent, HTTP auth/CORS, continuity, normalized blocks, idempotency, pagination, permissions, concurrent admission, recovery, cancellation, output budget, unavailable task hold, subprocess behavior, immutable launch definitions, policy tightening, degraded readiness, missing-database startup guards and producer/ACP overload |
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
| Producer/ACP overload | Real `yes` subprocess stops at a small test queue threshold with one terminal error; a suspended real ACP peer causes durable `output_backpressure_exceeded` failure with bounded queued input. These checks do not qualify slow HTTP subscribers or total application memory usage. |

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
for each release candidate.

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

## Remaining qualification gates

The full contract remains [the specification](spec.md). In particular:

- Fresh paid inference and continuation against the published archives, and
  live ARM64 Sprite installation.

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
