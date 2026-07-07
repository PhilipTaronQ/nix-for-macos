#!/usr/bin/env bash
# Fetch-or-build one dependency into $STAGING.
#
# Usage: .github/deps/dep.sh <name>
#   <name> is both the directory (.github/deps/<name>/build.sh) and the
#   entry in order.json / the standalone-sources manifest.
#
# Sources come from ONE flake build (`nix build .#standalone-sources`,
# see fetch.sh); build-all.sh exports $SOURCES so the loop is nix-free.
#
# Skip logic: staging/.built/<name> records "<version> <build.sh sha256>".
# If it matches, the dep is skipped — a restored staging cache makes
# previously built deps free, and editing a build.sh invalidates its own
# stamp automatically.
set -euo pipefail

name=$1
deps_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$deps_dir/../.." && pwd)

: "${STAGING:?set STAGING to the absolute staging prefix}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
# Feature detection must see ONLY staging — never Homebrew or other ambient
# pkg-config trees (the runner ships one at /opt/homebrew/lib/pkgconfig).
export PKG_CONFIG_LIBDIR="$STAGING/lib/pkgconfig:$STAGING/share/pkgconfig"

if [ -z "${SOURCES:-}" ]; then
    SOURCES=$(nix --extra-experimental-features 'nix-command flakes' \
        build --no-link --print-out-paths "$repo_root#standalone-sources")
fi
export SOURCES

version=$(jq -er --arg n "$name" '.[$n].version' "$SOURCES/manifest.json") \
    || { echo "no manifest entry for $name (missing from order.json?)" >&2; exit 1; }
want="$version $(shasum -a 256 "$deps_dir/$name/build.sh" | cut -d' ' -f1)"

stamp="$STAGING/.built/$name"
if [ -e "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
    echo "skip  $name $version (already in staging)"
    exit 0
fi

echo "build $name $version"
"$deps_dir/fetch.sh" "$name" "/tmp/build/$name"
cd "/tmp/build/$name"
bash "$deps_dir/$name/build.sh"

mkdir -p "$STAGING/.built"
echo "$want" > "$stamp"
