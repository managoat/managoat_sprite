# Sprite service 0.1.1 preview

Codex tool escalation requests now reach the service's configured permission
policy. The pinned adapter previously selected its automatic reviewer by
default, which could resolve requests before an `ask` policy received them.
The service now selects the adapter's human-review mode for both new and
continued conversations; ordinary workspace writes remain available. HTTP and
CLI contracts, persisted conversations and database schema are unchanged.

Local verification: 31 service tests, 24 desktop tests, and 48 installer/CLI
tests with the Linux-only watchdog test skipped on macOS. The suites use the
real ACP ScriptedAgent and local subprocesses. A live disposable Codex agent
configured with the same mode received an approval through the desktop,
accepted an allow-once answer, completed the tool, and cleared its attention
marker. Fresh installation of these exact release archives is a separate
qualification gate before publication.

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
