#!/bin/sh
# Install a verified release into an existing Sprite. No build tools needed.
set -eu
umask 077
MANAGOAT_ROOT=${MANAGOAT_ROOT:-"$HOME/.local/share/managoat"}
export MANAGOAT_ROOT
version=0.1.1
explicit_version=false
download_only=false
stage_only=false
previous=
for arg in "$@"; do
  if [ "$previous" = --version ]; then version=$arg; explicit_version=true; fi
  if [ "$arg" = --download-only ]; then download_only=true; fi
  if [ "$arg" = --stage-only ]; then stage_only=true; download_only=true; fi
  previous=$arg
done
case "$version" in *[!0-9A-Za-z.-]*|'') echo 'Invalid release version' >&2; exit 1;; esac
[ "$(uname -s)" = Linux ] || { echo 'Managoat installs on Linux Sprites.' >&2; exit 1; }
[ -S /.sprite/api.sock ] || { echo 'Sprite management socket is missing.' >&2; exit 1; }
for dependency in curl python3 tar sha256sum flock; do
  command -v "$dependency" >/dev/null || { echo "Missing dependency: $dependency" >&2; exit 1; }
done
case "$(uname -m)" in
  x86_64) arch=amd64;;
  aarch64) arch=arm64;;
  *) echo 'Unsupported CPU architecture' >&2; exit 1;;
esac
mkdir -p "$MANAGOAT_ROOT/releases" "$MANAGOAT_ROOT/state" "$HOME/.local/bin"
exec 9>"$MANAGOAT_ROOT/download.lock"
flock -n 9 || { echo 'Another installer is running' >&2; exit 1; }
if [ -e "$MANAGOAT_ROOT/current" ] && [ "$explicit_version" = true ] && [ "$download_only" = false ]; then
  current_version=$(cat "$MANAGOAT_ROOT/current/VERSION")
  [ "$current_version" = "$version" ] || { echo 'Use managoat upgrade --version to change an installed version.' >&2; exit 1; }
fi
if [ -e "$MANAGOAT_ROOT/current" ] && [ "$explicit_version" = false ]; then
  exec python3 "$MANAGOAT_ROOT/current/managoat.py" install "$@"
fi
stage=$(mktemp -d "$MANAGOAT_ROOT/releases/.download.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
archive="managoat-linux-$arch.tar.gz"
if [ -n "${MANAGOAT_ARCHIVE:-}" ]; then
  cp "$MANAGOAT_ARCHIVE" "$stage/$archive"
  cp "$MANAGOAT_ARCHIVE.sha256" "$stage/$archive.sha256"
else
  base="https://github.com/managoat/manasprites/releases/download/v$version"
  curl -fL --retry 3 "$base/$archive" -o "$stage/$archive"
  curl -fL --retry 3 "$base/$archive.sha256" -o "$stage/$archive.sha256"
fi
(cd "$stage" && sha256sum -c "$archive.sha256")
mkdir "$stage/release"
python3 - "$stage/$archive" "$stage/release" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1]) as archive:
    archive.extractall(sys.argv[2], filter='data')
PY
[ -x "$stage/release/bin/managoat" ] || { echo 'Invalid release archive' >&2; exit 1; }
installed_version=$(cat "$stage/release/VERSION")
[ "$installed_version" = "$version" ] || { echo 'Release version mismatch' >&2; exit 1; }
# The bundled ERTS is checked before activating the candidate.
"$stage/release/bin/managoat" eval 'IO.puts("runtime compatible")' >/dev/null 2>&1 || {
  echo 'Release runtime is incompatible with this Linux environment.' >&2; exit 1;
}
if [ ! -d "$MANAGOAT_ROOT/releases/$version" ]; then
  mv "$stage/release" "$MANAGOAT_ROOT/releases/$version"
fi
if [ "$stage_only" = true ]; then exit 0; fi
ln -s "$MANAGOAT_ROOT/releases/$version" "$stage/current"
mv -Tf "$stage/current" "$MANAGOAT_ROOT/current"
python3 - "$MANAGOAT_ROOT" <<'PY'
from pathlib import Path
import shlex, sys
root = Path(sys.argv[1])
service = '#!/bin/sh\nset -eu\nexport MANAGOAT_ROOT=' + shlex.quote(str(root)) + '\nexec python3 ' + shlex.quote(str(root/'current/service.py')) + '\n'
(root/'service').write_text(service)
(root/'service').chmod(0o700)
launcher = Path.home()/'.local/bin/managoat'
launcher.write_text('#!/bin/sh\nexport MANAGOAT_ROOT=' + shlex.quote(str(root)) + '\nexec python3 ' + shlex.quote(str(root/'current/managoat.py')) + ' "$@"\n')
launcher.chmod(0o700)
PY
if [ "$download_only" = true ]; then exit 0; fi
exec python3 "$MANAGOAT_ROOT/current/managoat.py" install "$@"
