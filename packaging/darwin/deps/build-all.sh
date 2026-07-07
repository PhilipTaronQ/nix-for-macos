#!/usr/bin/env bash
# Fetch-or-build every dependency listed in order.json (build order) into
# $STAGING. One flake build provisions every pinned source up front; the
# loop itself is nix-free. See dep.sh for the skip semantics.
set -euo pipefail

deps_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$deps_dir/../../.." && pwd)

SOURCES=$(nix --extra-experimental-features 'nix-command flakes' \
    build --no-link --print-out-paths "$repo_root#standalone-sources")
export SOURCES

for name in $(jq -r '.[]' "$deps_dir/order.json"); do
    "$deps_dir/dep.sh" "$name"
done
