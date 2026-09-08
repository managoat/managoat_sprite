#!/bin/sh
set -eu
export MIX_ENV=prod
mix deps.get --only prod
mix compile --warnings-as-errors
mix assets.build
mix release --overwrite --path src-tauri/target/rel
chmod -R u+w src-tauri/target/rel
# Previous packaging attempts may have copied read-only OTP files here.
for previous in src-tauri/target/release/rel src-tauri/target/release/bundle/macos/Manasprites.app; do
  if [ -d "$previous" ]; then chmod -R u+w "$previous"; fi
done
python3 scripts/relocate-macos.py src-tauri/target/rel
