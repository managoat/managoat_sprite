# Sprite service 0.1.2 preview

Adds an opt-in A2A 1.0 JSON-RPC adapter and sanitized agent card, using the
existing durable conversation engine and owner bearer key. External agents can
submit text tasks, stream updates, retrieve/list results, cancel a specific turn,
and follow up in the same context. Message IDs deduplicate atomically; task
artifacts contain only normalized text from the requested turn.

Known provider errors now fail the service turn even if ACP later reports
completion. Cancellation records intent before a pending prompt can be written.
Durable approval-resolution events allow other clients to clear owner waits.

See [configuration and wire semantics](a2a.md) and the
[qualification record](a2a-brief.md#implementation-and-qualification-record).
A2A remains off by default. Trusted peers use the existing full-authority service
key, configured separately from the card URL. Private ingress requires network
access; no platform access is changed by enabling discovery or copying a URL.

The schema migration is additive. A rollback to a pre-A2A service also requires
removing its unsupported A2A configuration while offline.

Qualification passed 41 service tests, 25 desktop tests, 48 installer/CLI tests,
and the native macOS workflow with actual clipboard verification. A disposable
AMD64 Sprite passed paid Codex execution through the official A2A Python SDK with
the laptop app closed, owner approvals after reopening, external SSE completion,
and same-context follow-up after a service restart. Test resources and temporary
credentials were removed.

Fresh installs can select this release explicitly:

```sh
curl -fsSL https://raw.githubusercontent.com/managoat/manasprites/v0.1.2/install.sh | sh -s -- \
  --version 0.1.2 --runtime codex --credential-env OPENAI_API_KEY --workspace /home/sprite/project
```

For an idle existing installation, use `managoat upgrade --version 0.1.2`.
A2A requires separate explicit configuration after installation. Linux ARM64
build tests do not establish live ARM64 Sprite qualification. Claude inference
parity and signed desktop distribution remain open.

---

# Sprite service 0.1.1 preview

Codex tool escalation requests now reach the service's configured permission
policy. The pinned adapter previously selected its automatic reviewer by
default, which could resolve requests before an `ask` policy received them.
The service now selects the adapter's human-review mode for both new and
continued conversations; ordinary workspace writes remain available. HTTP and
CLI contracts, persisted conversations and database schema are unchanged.

Verification: both Linux architecture jobs passed 31 service tests and all 48
installer/CLI tests. The desktop suite passes 24 tests with real ACP agents and
subprocesses. The exact AMD64 draft archive was checksum-verified and installed
on a fresh disposable Sprite. Authenticated readiness, unauthenticated refusal,
paid Codex inference, and an actual desktop allow-once approval round trip passed
with the new default and no environment override.

An existing disposable 0.1.0 installation also upgraded to this archive while
preserving its service key, workspace and conversations. A subsequent paid turn
recalled its pre-upgrade task from the same conversation without reading files
or calling tools.

This release supplies Linux AMD64 and ARM64 archives with bundled Erlang/OTP
and SHA-256 checksums. It is the remote service used by Manasprites; it does
not include the desktop application.

For a fresh Sprite, with `OPENAI_API_KEY` exported:

```sh
curl -fsSL https://raw.githubusercontent.com/managoat/manasprites/v0.1.1/install.sh | sh -s -- \
  --runtime codex --credential-env OPENAI_API_KEY --workspace /home/sprite/project
```

For an idle existing installation, use `managoat upgrade --version 0.1.1`.
The installer requires Node.js/npm, Python 3.12+, curl, tar, sha256sum and flock.
Setup imports the selected credential and verifies authenticated readiness; it
makes no inference request.

Claude inference parity and the broader service recovery/resource fault matrix
remain open. Linux ARM64 build tests do not establish live ARM64 Sprite
qualification. See the [desktop acceptance record](https://github.com/managoat/manasprites/blob/codex/desktop-liveview-macos/docs/desktop-acceptance.md)
and [service acceptance record](https://github.com/managoat/manasprites/blob/codex/desktop-liveview-macos/docs/acceptance.md)
for the scope of existing evidence.
