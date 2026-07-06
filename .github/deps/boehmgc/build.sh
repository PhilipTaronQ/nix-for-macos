#!/usr/bin/env bash
# boehm-gc, static. Run from the unpacked source root; STAGING set.
# Upstream flags (nix eval …#boehmgc.configureFlags): --enable-cplusplus
# --with-libatomic-ops=none --enable-mmap. Plus packaging/dependencies.nix
# overrides: enableLargeConfig and the initial mark-stack size (avoids mark
# stack overflows that inhibit parallel marking — see the comment there).
set -euo pipefail
if [ ! -x ./configure ]; then
    # autotools come from the nix profile (debug-session.yml installs the
    # consolidated build-tool stanza); its share/aclocal merges libtool m4.
    export PATH="$HOME/.nix-profile/bin:$PATH"
    export ACLOCAL_PATH="${ACLOCAL_PATH:-$HOME/.nix-profile/share/aclocal}"
    autoreconf -fiv
fi
CPPFLAGS="-DINITIAL_MARK_STACK_SIZE=1048576" \
./configure --prefix="$STAGING" --disable-shared --enable-static \
  --enable-cplusplus --with-libatomic-ops=none --enable-mmap \
  --enable-large-config
make -j"$(sysctl -n hw.ncpu)"
make install
