#!/usr/bin/env bash
# Fetch-or-build one dependency into $STAGING.
#
# Usage: .github/deps/dep.sh <name>
#   <name> is both the directory (.github/deps/<name>/build.sh) and the
#   nixpkgs attribute (see fetch.sh for the override caveat).
#
# Skip logic: staging/.built/<name> records the version that was built.
# If it matches the pin's current version, the dep is skipped — so restoring
# the staging cache makes previously built deps free. This stamp does NOT
# capture build.sh changes; after editing a build.sh, `rm staging/.built/<name>`
# (or wipe staging) to force a rebuild. The production pipeline will use
# .drv-hash cache keys instead (DESIGN.md §9.3).
set -euo pipefail

name=$1
deps_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$deps_dir/../.." && pwd)

: "${STAGING:?set STAGING to the absolute staging prefix}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

pin=$(jq -r '.nodes.nixpkgs.locked.rev' "$repo_root/flake.lock")
nix=(nix --extra-experimental-features nix-command --extra-experimental-features flakes)
version=$("${nix[@]}" eval --raw "github:NixOS/nixpkgs/$pin#$name.version")

stamp="$STAGING/.built/$name"
if [ -e "$stamp" ] && [ "$(cat "$stamp")" = "$version" ]; then
    echo "skip  $name $version (already in staging)"
    exit 0
fi

echo "build $name $version"
"$deps_dir/fetch.sh" "$name" "/tmp/build/$name"
cd "/tmp/build/$name"
bash "$deps_dir/$name/build.sh"

mkdir -p "$STAGING/.built"
echo "$version" > "$stamp"
