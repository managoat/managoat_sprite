Install a conversations API on an existing Sprite with one command.

This first preview distribution includes Linux AMD64 and ARM64 archives with
bundled Erlang/OTP, plus SHA-256 checksum files. Codex is the runtime with live
inference and continuation evidence. Claude is implemented but has not yet
passed the same live qualification.

Inside your Sprite, with `OPENAI_API_KEY` exported:

```sh
curl -fsSL https://raw.githubusercontent.com/managoat/managoat_sprite/v0.1.0/install.sh | sh -s -- \
  --runtime codex --credential-env OPENAI_API_KEY --workspace /home/sprite/project
```

The installer provisions pinned agent tools, persists the selected credential,
creates a separate client API key, starts the service, and checks local readiness.
Node.js/npm, Python 3.12+, curl, tar, sha256sum, and flock must be available.

Includes authenticated HTTP and SSE, SQLite history, follow-up sessions,
permission answers, cancellation, and local management commands. One shared
workspace and one active turn per installation. The service resumes saved
sessions on explicit follow-up; ambiguous work is marked interrupted after a
crash and is never automatically replayed.

This is a prerelease. Remaining qualification includes Claude parity, direct URL
streaming, browser UI integration, observed idle sleep/cold wake, and the full
recovery/resource fault matrix. Linux ARM64 builds and tests do not establish
live ARM64 Sprite qualification.

See the [README](https://github.com/managoat/managoat_sprite#setup) for setup and
[acceptance record](https://github.com/managoat/managoat_sprite/blob/main/docs/acceptance.md)
for validation evidence and remaining work.
