# A2A service adapter

Implementation contract, pinned to A2A specification v1.0.1 (wire version 1.0).
Qualification results and remaining release work are recorded in a2a-brief.md.

The authenticated `POST /a2a` JSON-RPC binding supports SendMessage,
SendStreamingMessage, GetTask, ListTasks, CancelTask and SubscribeToTask.
`A2A-Version: 1.0` is required; patch components are ignored for negotiation.
Absent/empty versions mean 0.3 and are refused. Discovery is version independent.

SendMessage blocks until terminal by default. `configuration.returnImmediately`
returns the admitted task immediately. Disconnecting never cancels work.
Streaming sends a current task snapshot followed by replacement artifact and
status updates read from transactional durable projections every 200ms. A stream
closes on terminal status or after 60 seconds without a change, with 15-second
heartbeats. Reconnect with SubscribeToTask for a fresh snapshot; GetTask recovers
a task that became terminal before resubscription. No Last-Event-ID replay is
promised: snapshots replace previous state and artifacts use stable IDs. The
projection and its event cursor are committed with the engine event, closing
snapshot/terminal races without retaining subscriber queues.

Only A2A-admitted tasks are listed/retrievable through A2A. Contexts may refer to
existing service conversations, but results/history contain only the requested
turn. ListTasks defaults to 50, maximum 100, ordered by status update timestamp
and task ID descending. Opaque cursors bind the filters and last ordering key;
changing filters invalidates the cursor. Concurrent updates can move tasks ahead
of a cursor; refresh the first page to reconcile. Artifacts default off in lists.
Text results are bounded to 1 MiB per task; truncation is explicit in metadata.
History is bounded to the input and normalized assistant result for that turn.

Message IDs deduplicate installation-wide in a namespace separate from REST
idempotency keys, atomically with admission. Repeating a message returns the
current task; conflicting content/context returns Invalid params (-32602).
Deleted messages retain tombstones indefinitely and return TaskNotFound (-32001)
with reason `gone`. Unknown contexts and malformed values are Invalid params.
Unsupported parts are ContentTypeNotSupported (-32005); terminal task messages
and busy admission are UnsupportedOperation (-32004), with safe reason codes.
Unknown tasks are -32001, noncancelable tasks -32002, push configuration -32003,
unsupported versions -32009. JSON-RPC parse/request/method/params/internal errors
use -32700/-32600/-32601/-32602/-32603. Authentication failures remain HTTP 401.
Cancellation targets the admitted turn under the Engine coordinator and waits for
confirmed cleanup (up to 15 seconds, otherwise an internal cleanup_pending error).
Crash recovery and unknown execution outcomes are FAILED.

A2A is disabled by default. The service configuration accepts:

```json
"a2a": {
  "enabled": true,
  "external_origin": "https://verified-agent.example",
  "origin_verified": true,
  "ingress": "private"
}
```

The owner must verify the HTTPS origin routes to this installed service and
check ingress through the platform before setting `origin_verified`. Apply the
complete configuration with `managoat configure --file PATH`; installation and
repeat installation preserve existing defaults and keys. This flag records the
operator's verification, not an automatic network probe. `ingress` is `public`
or `private` and describes existing routing; it never changes platform access.
Enabled configurations without a verified origin serve no public card and
capabilities report configuration needed. Origins cannot contain credentials,
paths, queries, fragments, loopback or private IP literals.

`GET /.well-known/agent-card.json` alone is anonymous when configured. It uses
fixed generic descriptions, not the configured private agent name/instructions.
Task and existing API routes require the full-authority service bearer key.
Trusted peers act as the owner; credentials are configured separately from the
card URL. Private callers also need platform/network access; desktop relays
cannot be used automatically by ordinary A2A clients. Scoped delegation is deferred.
