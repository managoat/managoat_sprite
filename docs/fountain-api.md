# Fountain-compatible host API

The opt-in Manasprites host API implements Fountain resource and conversation
routes for **Sprites with Codex or Claude**, using operator-provisioned accounts.
It runs in the laptop/host application and can run without its native window.
It is a separate listener from the desktop UI and the single-Sprite service.
It binds only to `127.0.0.1` and is disabled unless `MANASPRITES_API_PORT` is set.

## Implemented behavior

- Bearer authentication, operator-provisioned account identity, and revocable
  full-account API keys. Each account's resources, events, files and mutations
  are scoped to that account. API keys are stored as SHA-256 digests; provider
  credentials and environment/vault values use the desktop's encrypted vault.
- Agent, environment and vault create/read/update/list/delete, with metadata
  updates and field validation. Agents support Codex or Claude, explicit models,
  instructions, permission policies, and account-owned environment/vault links.
  Environments support one HTTPS repository, environment variables and a setup
  script. Vault environment variables override environment values; inference
  credentials come from the account. Secret values are write-only over this API.
- Conversation creation provisions a fresh **ephemeral** Sprite with the pinned
  service installer. No inference occurs until a prompt is submitted, unless
  creation explicitly includes a prompt. The Sprite URL remains private; the
  host uses authenticated Sprites TCP relays to reach the service.
- Prompts, follow-ups, turn history, normalized tool/text blocks, permissions,
  interruption, per-conversation and account-wide SSE, cursor replay, and paged
  event history. The host translates turn-stage metadata and assigns durable
  global event IDs; account-wide streams include the host conversation ID.
- Sandbox identity/status and bounded file reads (up to 128 KiB, base64 encoded).
  File reads refuse traversal, symlinks, `.git`, and non-regular files.
- Termination destroys the conversation's owned ephemeral Sprite. It returns
  204 only after cleanup is confirmed, otherwise 503 while cleanup is pending
  or failed. Retrying termination is supported. Conversation deletion requires
  completed cleanup; referenced parent resources remain until the conversation
  is deleted. Existing desktop agents and their persistent Sprites are separate.

Unknown request fields and unsupported modes/providers are rejected. This is
not the whole Fountain product: persistent-sandbox attachment, additional
providers/runtimes, billing, registration, OAuth, scoped delegation, scheduling,
MCP server configuration and conversation trees are not implemented here.
The OpenAPI response vocabulary retains compatible optional Fountain fields;
it does not imply support for every feature those fields can describe.

Up to eight conversations not yet terminated per account and 1,000 resources per
resource type are admitted. There is one active turn per conversation/Sprite.
Each service retains its existing timeout, output budget and process ownership
rules. The host must remain running for new API requests and live forwarding;
an accepted remote turn continues if the host or its client disconnects.

## Run on a host

From `desktop/`, choose an isolated persistent state directory. Do not run two
processes against the same desktop database. Account import is a local operator
operation; there is no unauthenticated registration endpoint or automatic email
verification. The operator must verify each account's email before importing it.

```sh
export MANASPRITES_DESKTOP_ROOT=/absolute/private/path/manasprites-api
export MANASPRITES_HEADLESS=true

# Populate these variables through your secret manager; do not put keys in args.
# MSP_OWNER_KEY must contain at least 24 bytes of random secret material.
mix fountain.account --email owner@example.com --verified-email \
  --key-env MSP_OWNER_KEY --sprites-env MSP_SPRITES_KEY \
  --openai-env MSP_OPENAI_KEY --anthropic-env MSP_ANTHROPIC_KEY

MANASPRITES_API_PORT=4080 mix run --no-halt
```

Provider variables may be omitted during account import, for example for a
second test account that will perform no inference. Repeating import for an
email retains its identity and adds the supplied key if necessary. Supplied
provider credentials replace that account's stored values. The import command
prints the account ID and never prints a credential. The original environment
variables are not needed on later host boots.

Use `http://127.0.0.1:4080` as a Fountain client's base URL with the imported
bearer key. A remote deployment requires your own HTTPS reverse proxy to this
loopback listener, preserving Authorization and unbuffered SSE. The native
window is optional; hosting, automatic startup and public TLS are operator
responsibilities. This API does not alter the single-Sprite service listener.

## Admission, recovery and cleanup

The host commits prompt intent and a downstream idempotency key before dispatch.
If the service's acknowledgement is lost, a recovering worker uses that same
key and request. It never invents a new prompt operation to recover an old one.
The service's own durable admission, runtime-session and crash barriers remain
responsible for inference. Host restart resumes service-event polling; it does
not restart an already executing remote turn. A caller's repeated POST without
an application-level decision is a new submission: this adapter does not yet
expose inbound `Idempotency-Key` semantics.

Provisioning records the intended Sprite name before creation and its verified
platform identity before setup. Reconciliation never adopts an unrelated name.
A missing Sprite after an unacknowledged creation remains uncertain; absence at
one instant is not treated as successful cleanup. Termination verifies the
recorded identity and ownership label before deletion and confirms platform
absence before reporting completion. A replacement Sprite is left untouched.

The host uses the same private SQLite database and vault master key as its
selected desktop state directory. Back up that directory together with its
master key. Host transcripts are private local state, not encrypted at rest by
this adapter. The host operator remains trusted; account scoping does not isolate
accounts from someone who controls the host OS or its vault master key.

## Qualification and reproducible checks

Compatibility is pinned to Fountain commit
`01ed20a38d39be9c72fcb2828047f1cce7a6bb55`, with wire-contract SHA-256
`f15a337bc85008a67663ab3e03ab7b8678a7c63d631d9d096fcefb884d261d99`.
The authoritative hash is recorded by the unchanged external runner on each
run. The source of response shapes is `sdk/contract/contract.json` in that
checkout; `scripts/fountain-openapi.py` projects the implemented routes into the
host's advertised OpenAPI document. No Fountain server is embedded or started.

```sh
# In desktop/, with the pinned Fountain checkout available:
FOUNTAIN_CHECKOUT=/absolute/path/to/fountain mix check

# In this repository's root:
mix check
python3 -m unittest discover -s test -p '*_test.py' -v
```

The Fountain CI job checks out that exact revision, regenerates the advertised
schemas, and runs the tests with Node 24. When `FOUNTAIN_CHECKOUT` is absent,
ExUnit explicitly excludes the external conformance test; ordinary host API
and lifecycle tests still run. An excluded test is not a conformance pass.

Verified locally in this PR's implementation work:

| Check | Evidence and scope |
| --- | --- |
| Unchanged deployed `basic` profile | Real loopback HTTP: identity, catalog, resource CRUD, field errors, two-account isolation, key revocation, advertised schemas |
| Unchanged deployed `streaming` profile, Codex and Claude configurations | Separate real service BEAMs, real ACP ScriptedAgent over OS stdio, and real shell file writes/reads; includes the two-turn execution checks, incremental output while running, disconnect/reconnect, pagination, replay and cleanup |
| Lost prompt acknowledgement plus killed host worker | Real service retains one turn under the persisted idempotency key; replacement worker collects its result without duplicate dispatch |
| Concurrent prompts | One admission succeeds, one receives `conversation_busy`; foreign-account termination is denied |
| Production Sprites adapter | Real Sprites SDK against a loopback platform fixture, real private TCP relay, real remote-inspector subprocess, binary byte limits, replacement identity rejection, and uncertain-create cleanup |

These checks establish host/service compatibility and execution semantics.
**They do not establish live Sprites platform behavior or funded Codex/Claude
inference for this new host API.** The existing service's earlier live Codex
qualification is recorded separately in `desktop-acceptance.md`; it is not a
live pass of this adapter. Fresh live provisioning, model/tool execution,
continuation, ingress/replay and cleanup must be run per provider before
claiming that qualification. Full host process-crash/platform-failure matrices,
slow-reader resource bounds and public reverse-proxy behavior remain unqualified.

For live qualification, import two distinct dedicated accounts, configure the
primary account's provider keys, and run Fountain's `deployed/cli.mjs` against
this host URL with `profiles: ["basic"]`, then `profiles: ["streaming"]` separately
for each runtime. Set the model and `sandbox_provider: "sprites"` explicitly,
and authorize `max_turns: 2` in each execution configuration. The suite provisions
and destroys its own ephemeral resources. Keep all target files, credentials,
transcripts and run artifacts private; commit only a sanitized qualification
summary. The provider's usage and the suite's separate provisioning/turn/cleanup
deadlines do not constitute a monetary cap.
