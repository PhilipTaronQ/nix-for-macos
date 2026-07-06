#!/usr/bin/env bash
# editline, static, autotools. STAGING set. Git-snapshot source: autoreconf
# via the demoted Nix with libtool m4 wiring (same pattern as boehmgc).
set -euo pipefail
if [ ! -x ./configure ]; then
    repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
    pin=$(jq -r ".nodes.nixpkgs.locked.rev" "$repo_root/flake.lock")
    nix --extra-experimental-features "nix-command flakes" shell \
        "github:NixOS/nixpkgs/$pin#autoconf" \
        "github:NixOS/nixpkgs/$pin#automake" \
        "github:NixOS/nixpkgs/$pin#libtool" \
        --command bash -c '
            lt_prefix=$(dirname "$(dirname "$(command -v libtoolize)")")
            export ACLOCAL_PATH="$lt_prefix/share/aclocal"
            autoreconf -fiv
        '
fi
./configure --prefix="$STAGING" --disable-shared --enable-static
make -j"$(sysctl -n hw.ncpu)"
make install
