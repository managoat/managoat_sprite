#!/bin/sh
# Install the host CLI on macOS or Linux; no checkout or build tools needed.
set -eu
umask 077
version=0.1.0
prefix="$HOME/.local"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version|--prefix)
      [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
      case "$1" in --version) version=$2;; --prefix) prefix=$2;; esac
      shift 2;;
    -h|--help)
      echo 'Usage: install-cli.sh [--version VERSION] [--prefix DIRECTORY]'
      exit 0;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done
case "$(uname -s)" in Darwin|Linux) ;; *) echo 'The CLI supports macOS and Linux.' >&2; exit 1;; esac
command -v python3 >/dev/null || { echo 'Install Python 3.9+ first.' >&2; exit 1; }
python3 - "$version" <<'PY'
import re, sys
if sys.version_info < (3, 9):
    sys.exit('Install Python 3.9+ first.')
if not re.fullmatch(r'\d+\.\d+\.\d+', sys.argv[1]):
    sys.exit('Invalid CLI release version.')
PY
stage=$(mktemp -d "${TMPDIR:-/tmp}/managoat-cli.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
archive=managoat-cli.tar.gz
if [ -n "${MANAGOAT_CLI_ARCHIVE:-}" ]; then
  cp "$MANAGOAT_CLI_ARCHIVE" "$stage/$archive"
  cp "$MANAGOAT_CLI_ARCHIVE.sha256" "$stage/$archive.sha256"
else
  command -v curl >/dev/null || { echo 'Install curl first.' >&2; exit 1; }
  base="https://github.com/managoat/managoat_sprite/releases/download/cli-v$version"
  curl -fsSL --retry 3 "$base/$archive" -o "$stage/$archive"
  curl -fsSL --retry 3 "$base/$archive.sha256" -o "$stage/$archive.sha256"
fi
python3 - "$stage" "$version" <<'PY'
import hashlib, pathlib, re, sys, tarfile
root = pathlib.Path(sys.argv[1])
try:
    archive = root / 'managoat-cli.tar.gz'
    if archive.stat().st_size > 20 * 1024 * 1024:
        raise ValueError('CLI archive exceeds size limit')
    checksum = (root / 'managoat-cli.tar.gz.sha256').read_text().strip()
    match = re.fullmatch(r'([0-9a-f]{64})  managoat-cli\.tar\.gz', checksum)
    if not match or hashlib.sha256(archive.read_bytes()).hexdigest() != match[1]:
        raise ValueError('CLI archive checksum mismatch')
    expected = {'managoat.py', 'provision.py', 'provision_remote.py', 'chat.py',
                'install-cli.py', 'CLI_VERSION', 'LICENSE'}
    with tarfile.open(archive) as tar:
        members = tar.getmembers()
        if (len(members) != len(expected) or {m.name for m in members} != expected
                or any(not m.isfile() or m.size > 2 * 1024 * 1024 for m in members)):
            raise ValueError('Invalid CLI archive contents')
        # Write only the fixed set of regular files; no tar paths or links are extracted.
        target = root / 'release'
        target.mkdir()
        for member in members:
            with tar.extractfile(member) as source:
                (target / member.name).write_bytes(source.read())
    if (target / 'CLI_VERSION').read_text().strip() != sys.argv[2]:
        raise ValueError('CLI release version mismatch')
except (OSError, ValueError, tarfile.TarError) as error:
    sys.exit(str(error))
PY
python3 "$stage/release/install-cli.py" --prefix "$prefix"
