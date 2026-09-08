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
