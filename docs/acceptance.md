# Acceptance record

Initial implementation in progress. This record is updated from executed checks,
not from intended behavior.

- Local `mix check`: 9 tests pass (HTTP auth/CORS, conversation and follow-up,
  SSE blocks, permissions, idempotency/deletion, pagination, subprocess streams,
  stdin EOF and owner-death cleanup).
- Isolated Linux Sprite created for release build and live verification.
- Public distribution, live inference, restart/crash probes, installer lifecycle
  tests and the complete specification audit remain in progress.
