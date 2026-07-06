#!/usr/bin/env bash
# Fetch-or-build one dependency into $STAGING.
#
# Usage: .github/deps/dep.sh <name>
#   <name> is both the directory (.github/deps/<name>/build.sh) and the
#   nixpkgs attribute (see fetch.sh for the override caveat).
#
# Per-dep fetch override: if .github/deps/<name>/fetch.sh exists, it is used
# instead of the generic fetch.sh — for deps the flake overrides (libgit2).
# Contract: `<name>/fetch.sh version` prints the version; `<name>/fetch.sh
# <dest>` fetches+unpacks.
#
# Skip logic: staging/.built/<name> records the version that was built.
# If it matches the pin, the dep is skipped — a restored staging cache makes
# previously built deps free. The stamp does NOT capture build.sh changes;
# `rm staging/.built/<name>` after editing one. The production pipeline will
# use .drv-hash cache keys instead (DESIGN.md §9.3).
set -euo pipefail

name=$1
deps_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$deps_dir/../.." && pwd)

: "${STAGING:?set STAGING to the absolute staging prefix}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
# Feature detection must see ONLY staging — never Homebrew or other ambient
# pkg-config trees (the runner ships one at /opt/homebrew/lib/pkgconfig).
export PKG_CONFIG_LIBDIR="$STAGING/lib/pkgconfig:$STAGING/share/pkgconfig"

if [ -x "$deps_dir/$name/fetch.sh" ]; then
    fetch=("$deps_dir/$name/fetch.sh")
    version=$("${fetch[@]}" version)
else
    fetch=("$deps_dir/fetch.sh" "$name")
    pin=$(jq -r ".nodes.nixpkgs.locked.rev" "$repo_root/flake.lock")
    version=$(nix --extra-experimental-features "nix-command flakes" \
        eval --raw "github:NixOS/nixpkgs/$pin#$name.version")
fi

stamp="$STAGING/.built/$name"
if [ -e "$stamp" ] && [ "$(cat "$stamp")" = "$version" ]; then
    echo "skip  $name $version (already in staging)"
    exit 0
fi

echo "build $name $version"
"${fetch[@]}" "/tmp/build/$name"
cd "/tmp/build/$name"
bash "$deps_dir/$name/build.sh"

mkdir -p "$STAGING/.built"
echo "$version" > "$stamp"
