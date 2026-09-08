#!/bin/sh
set -eu
export MIX_ENV=prod
mix deps.get --only prod
mix compile --warnings-as-errors
mix release managoat --overwrite
release=_build/prod/rel/managoat
cp scripts/managoat.py "$release/managoat.py"
cp scripts/chat.py scripts/provision.py scripts/provision_remote.py "$release/"
cp scripts/service.py "$release/service.py"
version=$(awk '{print $2}' "$release/releases/start_erl.data")
printf '%s\n' "$version" > "$release/VERSION"
printf '%s\n' '{"schema":1,"reads_schemas":[1],"rollback_schemas":[1]}' > "$release/manifest.json"
case "$(uname -m)" in x86_64) arch=amd64;; aarch64) arch=arm64;; *) exit 1;; esac
mkdir -p dist
archive="managoat-linux-$arch.tar.gz"
tar -C "$release" -czf "dist/$archive" .
(cd dist && sha256sum "$archive" > "$archive.sha256")
