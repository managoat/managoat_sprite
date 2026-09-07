# Contributor instructions

Read README.md and docs/spec.md. Keep implemented behavior and remaining work distinct.
Run `mix check` for Elixir changes and the installer/CLI tests for lifecycle changes.
Use the real ACP ScriptedAgent and real local subprocesses to test behavior; do not
substitute assertions on implementation text for execution tests.
Never publish credentials, local account state, transcripts, or test Sprite tokens.
Do not change Managoat's other repositories without examining their instructions.
