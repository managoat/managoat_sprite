# Desktop acceptance audit

Audited against the user-specified stack and the six delivery gates in
[desktop.md](desktop.md). Local implementation and packaging are verified;
the full goal remains incomplete pending live-platform and distribution evidence.

| Requirement | Current evidence | Result |
| --- | --- | --- |
| Elixir + Phoenix LiveView laptop backend | Separate `desktop/mix.exs`, supervised application and LiveViews; 24 passing desktop tests | Verified locally |
| OTP owns fleet connections and jobs | Registry, DynamicSupervisor, Task.Supervisor; owner-death, lost-acknowledgement and restart tests | Verified locally |
| SQLite/Ecto stores local authority and history | Encrypted credential tests, restart/cache tests, actual native SQLite persistence and second-process lock refusal | Verified locally |
| Evaluate Elixir Desktop and use the supplied prototype | Recorded wxWidgets dependency evaluation; Tauri + ElixirKit follows the inspected prototype | Evaluation complete; Tauri packaging verified |
| Preserve existing CLI and Sprite service | No source diff under root `lib`, `scripts`, `test`, `mix.exs` or `mix.lock`; root service check passed 30 tests and CLI/installer suite passed 48 with one platform skip | Verified locally |
| Native macOS launch and lifetime | Extracted ZIP launches real WebKit with system-only PATH, saves/reloads state, closes BEAM/listener on normal exit and SIGKILL | Verified on this Apple Silicon Mac |
| Local credential handling | Write-only forms, encrypted SQLite values, private files, per-launch loopback authentication; package audit excludes known state files and verifies signatures | Verified within the tested local scope |
| Discovery, attachment and creation | Packaged-backend discovery, fresh private Codex/Claude creation and a fresh local attachment recovering the installed agent's remote history | Live private lifecycle verified; fresh public creation remains unqualified |
| Conversations and independent fleet work | Local two-service ACP coverage plus actual Codex file work, continuation, interruption and history recovery through the packaged backend | Real Codex work verified; live approval and simultaneous provider work remain unqualified |
| Honest recovery | Actual accepted prompt with withheld HTTP acknowledgement; owner termination produces an unknown result and prevents automatic replay | Verified locally |
| Workspace files and changes | Local subprocess/Git tests plus live authenticated listing/status and exact checks of a Codex-generated file and Git diff | Verified against live Sprite work |
| Idle behavior | A live private test Sprite reached `cold`, then Codex resumed the same conversation through the packaged backend and made the expected file change | Live sleep, private cold wake and inference continuation verified |
| Fleet approval visibility | Two-service overview test and held real ACP answer after HTTP acknowledgement | Verified with the limitation below |
| Native fleet forms and work controls | Production WebKit drives write-only settings, two real local service attachments, parallel approvals, continuation, interruption, local removal and restart | Core native workflow verified with synthetic services; creation and file inspector UI walkthroughs remain |
| Reviewable delivery archive | Local ZIP, SHA-256 checksum and metadata report; checksum recomputed; deep strict signature verification passes | Verified local artifact |
| Hosted macOS CI and Intel build | Workflow and `actionlint` validation exist; no hosted result for this uncommitted desktop source | Unverified |
| Clean second Mac | Moving the app and removing build tools from runtime PATH passes on the development Mac | Separate-machine evidence missing |
| Developer ID signing/notarization and published release | Current artifact is ad-hoc signed; no signing/notarization environment configured and no usable code-signing identity found | Incomplete |

The existing service does not expose another client's permission-resolution
state during an active turn. The UI therefore shows an observed **Approval
requested** marker, clears acknowledged local answers, and clears terminal turns.
An answer submitted by another client can leave that marker visible until the
turn finishes. It is not an authoritative cross-client pending count.

The desktop now recognizes structured Codex billing and non-retried provider
errors, shows a fixed warning on the affected turn, and routes the agent into
Needs attention. It preserves the service's reported status and labels a
reported completion for review instead of presenting completion alone. Detection
uses the full cached protocol history, so UI output pagination cannot hide the
warning. A later clean turn in that conversation clears the fleet marker while
the earlier warning remains in history. A real ACP ScriptedAgent regression
test verifies these cases and avoids treating ordinary assistant text or a
transient retried error as a terminal provider failure. The warning is an
observed provider report, not a claim that the desktop verified the task output.

## Live qualification on 2026-09-08

The authorized credential source was available and its Sprites token matched
the CLI's default organization. The existing macOS bundle's embedded release
ran the actual desktop modules against the platform with isolated encrypted
local state. Discovery and fresh private creation passed for both Codex and
Claude, including installation, unauthenticated service refusal and authenticated
readiness. The actual native WebKit/LiveView app then reopened that fleet, kept
saved credentials out of the rendered page and stopped its BEAM on close.

The initial OpenAI and Anthropic credentials returned billing/credit errors.
Codex's adapter nevertheless reported its turn completed, so completion alone
was not accepted as evidence: the expected file was absent. After an explicitly
authorized funded OpenAI credential replacement on the owned test Sprite, the
real task passed. Codex created and committed a baseline file, left a requested
change uncommitted, then appended another exact line in the same conversation.
The desktop inspector verified the file bytes, Git status and diff. Restarting
the packaged backend restored the two successful turns and cached events.

A subsequent real turn remained active until the desktop interrupted it and
observed the remote `interrupted` state. A harmless approval-specific prompt
did not produce a permission request, so live approval handling is still
unqualified; the actual ACP ScriptedAgent tests remain the evidence for that
path. Claude inference remains unqualified because of the initial billing error.

The idle private Codex Sprite reached `cold`. The packaged backend subsequently
synced it and performed authenticated workspace listing and repository-status
reads; the same inspection checks passed on the Claude Sprite. This initial
wake check did not exercise inference continuation after sleep. A later check
observed `cold` again, resumed the successful Codex conversation and verified
the exact appended file contents. Finally, removing only the local test
connection and attaching the installed private agent again recovered all five
remote turns and their events, including the successful continuation.
The native WebKit/LiveView app also reopened the freshly attached fleet and
closed its BEAM cleanly. With explicit cleanup authorization, both disposable
qualification Sprites were deleted after rechecking ownership and identity;
subsequent API reads returned 404 for each. The isolated local test credentials,
state and logs were removed. No pre-existing Sprite was modified.
No key values, account records or transcripts are included in this evidence.

## Evidence still needed

Answer a live approval and qualify fresh public URL creation/authentication.
Claude provider work and simultaneous work by two real providers remain
unqualified. Local fixtures do not substitute for these results.
Complete the native creation and workspace-inspector walkthroughs; the native
fleet probe currently covers settings, attachment and conversation controls.

Distribution still needs the hosted workflow results for both architectures,
an actual second-Mac launch, and a configured Developer ID/notarization path.
The verified local ZIP is not a published or notarized desktop release.
