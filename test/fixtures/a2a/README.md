# Official protocol and interoperability pin

- Protocol: https://github.com/a2aproject/A2A/releases/tag/v1.0.1
- Normative schema: https://raw.githubusercontent.com/a2aproject/A2A/v1.0.1/specification/a2a.proto
- SHA-256: e195bf96ab630c69797851970203e1b2b6b19528f2e9803b7d904b91a5104016
- SDK: official a2aproject/a2a-python, published a2a-sdk 1.0.3.
- Rechecked 2026-09-08: latest protocol release is v1.0.1. The SDK
  repository's latest tag was v1.1.4, unavailable from the configured package
  index. The published 1.0.3 SDK implements the required 1.0 wire protocol.
- Upstream schema is covered by the adjacent Apache-2.0 LICENSE.

sdk_client.py executes actual discovery and every supported operation using the
official protobuf types and JSON-RPC transport. It strictly parses the card,
verifies 1.0 enums and result envelopes, disconnects/reconnects SSE, checks
owner approval, task-only output and session continuation, and cancels work.
Its fixture runs a real HTTP listener and an OS subprocess running the actual
ACP ScriptedAgent. The local HTTP transport override is test-only; this does not
qualify public HTTPS ingress, real providers or Sprite service restart behavior.
