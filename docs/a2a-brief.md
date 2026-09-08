# A2A access to Sprite agents

Handoff brief, 2026-09-08. **Proposed; not implemented.**

## Outcome

An owner opens an agent in Manasprites, copies its **Agent card URL**, and gives
that URL plus separately configured credentials to another agent. That agent
can submit work, follow progress, retrieve results, and continue the conversation.
The Sprite remains reachable when the laptop app is closed.

## What exists today

The service exposes the Fountain conversations API, authenticated HTTP/SSE,
durable conversations/turns/events, permission decisions, cancellation, and
idempotent admission. There are no A2A routes, cards, or protocol adapters.
The `agent-card` CSS class in the desktop is unrelated to A2A.

Each installation has one `default` agent, one workspace, and one active turn
across all conversations. Keep that admission rule and the existing API/CLI.
See [service contract](spec.md#http-contract) and [desktop architecture](desktop.md).

## Proposed first release

Implement an Elixir adapter **inside the Sprite service**, using the existing
Engine and Store. The laptop only configures access and displays discovery
information; it is not an A2A gateway. ACP continues to connect the service to
the coding runtime. A2A connects external agents to the service.

Target the A2A **1.0** wire protocol, pinning schemas and interoperability fixtures
to the official [v1.0.1 release](https://github.com/a2aproject/A2A/releases/tag/v1.0.1).
Recheck the released version when implementation starts; do not copy older 0.3
examples or silently mix their field names with 1.0.

Use one JSON-RPC endpoint, proposed `POST /a2a`, with `SendMessage`,
`SendStreamingMessage`, `GetTask`, `ListTasks`, `CancelTask`, and `SubscribeToTask`.
Implement version negotiation, required request/response fields, SSE envelopes,
and protocol errors from the [official specification](https://a2a-protocol.org/latest/specification/).
Pin an official SDK client version that supports this protocol for execution tests.

Accept text and return normalized assistant text, with a stable text-result
artifact when available. Exclude file uploads/downloads, arbitrary URL fetching,
push notifications, additional bindings, extended cards, and multi-user delegation.
The desktop's remote file inspector is not a service artifact API.

## Discovery and access

Serve a sanitized card at `GET /.well-known/agent-card.json`, describing the
installed agent, a generic coding skill, text input/output, streaming support,
the verified HTTPS interface, and bearer authentication. The standard discovery
document describes interfaces and access requirements; it does not supply
credentials. [Agent discovery](https://a2a-protocol.org/latest/topics/agent-discovery/).

Make A2A enablement explicit and initially off. For an enabled direct endpoint,
allow anonymous access only to this sanitized card; execution and task access
still require the service bearer key. Do not include instructions, repository
details, workspace paths, account identifiers, transcripts, or secrets in the card.
Use a configured, verified external origin, never an incoming Host header or a
guessed Sprite hostname. Preserve existing route authentication.

Private Sprite ingress still requires platform access. Display **Private — caller
needs network access**, and explain that the URL alone is insufficient. A generic
A2A client cannot use the desktop's private relay automatically. Never switch
ingress to public when copying a URL, expose an organization token, or advertise
`sprite://` or a laptop loopback tunnel as a remotely usable card URL. If no
verified external origin is known, show configuration needed instead of inventing one.

For the first release, access is for **trusted peers acting as the owner**. The
existing service key grants full service authority, including workspace execution
and the existing permission API. Copying a URL must never copy a key. Credentials
are configured separately; scoped, revocable delegation keys are a follow-up
prerequisite for sharing with less-trusted agents.

## Map onto the existing engine

The proposed mapping follows A2A's separation of contexts and terminal tasks.
Follow-ups start new tasks in the same context; terminal tasks cannot restart.
[Task lifecycle](https://a2a-protocol.org/latest/topics/life-of-a-task/).

| A2A concept | Proposed service mapping |
|---|---|
| Agent card | One per installed `default` agent, not per conversation or laptop |
| `contextId` | Durable conversation ID; absent means create a conversation |
| Task ID | Durable turn ID; validate task/context association on every request |
| `messageId` | Persist request fingerprint and admission result; duplicate delivery must not execute twice |
| Submitted / working | Pending / running turn |
| Completed / failed | Terminal engine outcome; return only this turn's output |
| Canceled | Confirmed explicit interruption, after subprocess cleanup |
| Follow-up | New turn in the same conversation; never reopen a terminal task |

Use exact 1.0 enum spellings in the wire serializer. Reject conflicting duplicate
messages, unknown contexts, unsupported parts, and concurrent admission with
documented errors. Namespace message deduplication separately from existing REST
keys; recording the mapping and accepting work must be atomic. Preserve deletion
tombstones and avoid exposing unrelated history through task listing.

Cancellation needs a task-specific engine operation: checking a turn and then
calling today's conversation-level `Engine.interrupt/1` can race with a newer
turn. Interrupt only the requested active turn, retaining the conversation and
workspace. Crash/unknown-outcome recovery is a failure with a clear reason, not
successful completion or automatic retry. Known provider failures must remain
failures even when an adapter reports prompt completion.

Keep owner tool approvals in the existing UI. While awaiting that owner, report
working with a safe status message; do not imply the calling agent must provide
ordinary task input or new authentication. Free-text “approve” must not resolve
an ACP permission request. Read durable permission state and publish resolution
updates so another client's answer clears the wait. A future structured approval
extension needs an explicit authority model.

Build task snapshots and streams from durable events, with stable artifact IDs
and bounded output. Reconnection must reconcile a current snapshot and subsequent
updates without missed terminal transitions. Do not forward raw ACP/provider
payloads or assume existing REST SSE is already A2A-compatible.

## Implementation order and seams

1. **Service adapter:** add `lib/managoat/sprite/a2a/` for card, validation,
   serialization and task projection. Mount through `http.ex`; reuse `engine.ex`,
   `store.ex`, and SQLite migrations for durable mappings and cancellation.
   Specify errors, blocking behavior, pagination and replay semantics before coding.
2. **Configuration:** persist opt-in enablement and verified external origin;
   add authenticated A2A discovery metadata to `/api/capabilities`. Update the
   installer/provisioning contract without changing existing defaults or keys.
3. **Desktop:** use the capability snapshot in `Operations`/`Connection` and add
   **Agent card URL**, **Copy URL**, and reachability/authentication guidance beside
   the agent heading in `fleet_live/render.html.heex`. Older services show
   **Upgrade required**; disabled services show **Not enabled**. Cache discovery
   during explicit refresh/connection; do not introduce idle polling.
4. **Ship:** update the service specification, qualify a new service release,
   then advance the desktop provisioning pin. Keep the README's feature claims
   unchanged until the end-to-end workflow passes.

## Acceptance for the next agent

- A pinned official A2A client discovers the card, submits a real ScriptedAgent
  task, streams output, gets the result, lists tasks and follows up in the same
  context. The same work appears in the desktop's normal conversation history.
- Execute duplicate-message, busy-workspace, invalid-context, cancellation-race,
  approval allow/deny/timeout, disconnect/reconnect and service-restart cases with
  real local subprocesses. Verify exactly one dispatch and no wrong-turn interrupt.
- Verify anonymous card discovery exposes only intended metadata; unauthenticated
  task access fails; card URLs contain no credentials. Exercise public/private
  ingress, unknown external origins, disabled A2A, and older service capabilities.
- Run `mix check` in both projects for Elixir changes, installer/CLI tests for
  lifecycle changes, and a native UI check of copying the URL. Do not substitute
  source-text assertions for execution tests.
- Qualify a disposable Sprite with an external A2A client while the laptop app
  is closed, including one paid coding task and owner approval after reopening.
  Record sanitized evidence and remove test resources and credentials.
