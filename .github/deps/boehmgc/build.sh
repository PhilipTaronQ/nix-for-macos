#!/usr/bin/env bash
# boehm-gc, static. Run from the unpacked source root; STAGING set.
# Upstream flags (nix eval …#boehmgc.configureFlags): --enable-cplusplus
# --with-libatomic-ops=none --enable-mmap. Plus packaging/dependencies.nix
# overrides: enableLargeConfig and the initial mark-stack size (avoids mark
# stack overflows that inhibit parallel marking — see the comment there).
# Source is a git snapshot without ./configure; autoreconf comes from the
# demoted Nix (build tools are nix-provided by design). ACLOCAL_PATH must
# point at libtool's m4 macros — the wiring autoreconfHook normally does.
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
CPPFLAGS="-DINITIAL_MARK_STACK_SIZE=1048576" \
./configure --prefix="$STAGING" --disable-shared --enable-static \
  --enable-cplusplus --with-libatomic-ops=none --enable-mmap \
  --enable-large-config
make -j"$(sysctl -n hw.ncpu)"
make install
