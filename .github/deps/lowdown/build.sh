#!/usr/bin/env bash
# lowdown, static. STAGING set. BSD-make project: bmake comes from the
# demoted Nix (nixpkgs builds lowdown with bmake too). The install also
# ships a dylib; remove it — staging is static-only.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
pin=$(jq -r ".nodes.nixpkgs.locked.rev" "$repo_root/flake.lock")
./configure PREFIX="$STAGING"
nix --extra-experimental-features "nix-command flakes" shell \
    "github:NixOS/nixpkgs/$pin#bmake" --command bash -c '
        bmake -j"$(sysctl -n hw.ncpu)"
        bmake install install_libs
    '
rm -f "$STAGING"/lib/liblowdown*.dylib "$STAGING"/lib/liblowdown*.so*
