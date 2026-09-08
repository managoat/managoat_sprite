# Development

[Back to Managoat Sprite](../README.md)

For local development, install Elixir 1.19 and a compatible Erlang/OTP toolchain,
then run:

```sh
mix deps.get
mix check
python3 -m unittest discover -s test -p '*_test.py' -v
```

The tests use the real ACP ScriptedAgent and real local subprocesses. Live Sprite
checks are tracked separately from local test results. The Linux watchdog test
requires Linux; it is skipped on macOS.

## Build a CLI release

The host CLI requires Python 3.9+ and uses only the standard library. Run it from
`./bin/managoat`, or install a checkout with `python3 scripts/install-cli.py`.

```sh
python3 scripts/build-cli.py
MANAGOAT_CLI_ARCHIVE="$PWD/dist/cli/managoat-cli.tar.gz" sh install-cli.sh --prefix /tmp/managoat-cli
/tmp/managoat-cli/bin/managoat --version
```

The build uses an explicit list of source files and reproducible archive metadata.
It writes the archive, installer, and adjacent SHA-256 files to `dist/cli/`.
The installer rejects unexpected archive entries, links, checksum failures, and
version mismatches before changing the installed launcher.

CLI releases use `cli-vVERSION` tags independently of service `vVERSION` tags.
Update `scripts/CLI_VERSION`, the default in `install-cli.sh`, and the release
notes and install links together. The CLI release workflow tests Python 3.9 and
3.13 on macOS and Linux, installs the resulting archive, and stages a draft
preview release. Publish after those checks and a downloaded-artifact smoke test.
The regular `mix check` suite also runs the packaged CLI against the real local
service and ACP ScriptedAgent.

## Build a Linux release

The release workflow builds on Ubuntu 24.04 with Erlang/OTP 28.1 and Elixir 1.19.2.
Install those tools, Git, and a C/C++ build toolchain on your Linux build machine:

```sh
git clone https://github.com/managoat/managoat_sprite.git
cd managoat_sprite
mix deps.get
mix check
python3 -m unittest discover -s test -p '*_test.py' -v
sh scripts/build-release.sh
```

The build writes an archive and adjacent `.sha256` file under `dist/`. To try it,
copy both files to a Sprite with the same CPU architecture, then run from a source
checkout inside the Sprite with your inference credential exported:

```sh
# Use managoat-linux-arm64.tar.gz on an ARM64 Sprite.
MANAGOAT_ARCHIVE="$PWD/dist/managoat-linux-amd64.tar.gz" \
  sh install.sh --runtime codex --credential-env OPENAI_API_KEY \
  --workspace /home/sprite/project
```

Set `MANAGOAT_ARCHIVE` to the actual archive path if you copied it elsewhere.
A macOS release cannot be installed on a Linux Sprite. The build machine needs
Elixir and Erlang; the target Sprite does not.

Release tags run both architecture test/build jobs and stage a draft GitHub
release. Verify the archives and a clean Sprite installation before publishing
the draft. The initial `v0.1.0` distribution is marked as a prerelease while the
remaining acceptance gates are open.
