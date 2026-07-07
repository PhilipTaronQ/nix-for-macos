#!/usr/bin/env bash
# ncurses, static. STAGING set. Helper-executable dep: returns to the BOM
# only because bash needs it. Upstream flags minus
# --with-shared/--with-versioned-syms (ELF-ism), static instead.
set -euo pipefail
./configure --prefix="$STAGING" --without-shared --without-debug \
  --enable-pc-files --enable-symlinks --with-manpage-format=normal \
  --without-ada --without-tests \
  --with-pkg-config-libdir="$STAGING/lib/pkgconfig"
make -j"$(sysctl -n hw.ncpu)"
make install
# ncurses 6.6 installs wide-only (libncursesw.a); provide the non-wide
# names consumers ask for — the same compat symlinks nixpkgs creates.
for l in ncurses ncurses++; do
  ln -sf "lib${l}w.a" "$STAGING/lib/lib${l}.a"
done
