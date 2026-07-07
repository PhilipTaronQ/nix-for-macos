#!/usr/bin/env bash
# lsof, for GC root discovery (lsof -n -w -F n). STAGING set.
#
# Nixpkgs-faithful build: the pinned src is the tag snapshot (no
# pregenerated autotools configure), driven through the LEGACY ./Configure
# dialect system exactly as nixpkgs does — which also sidesteps the
# configure/Configure clash on case-insensitive APFS, because nothing ever
# generates a `configure`. The legacy build has no `make install`; the
# payload is the one binary.
set -euo pipefail
LSOF_CC=cc LSOF_AR="ar cr" LSOF_RANLIB=ranlib ./Configure -n darwin

# The darwin dialect appends -lcurses (repeat-mode screen clearing), which
# would dynamize /usr/lib/libncurses.5.4.dylib. nixpkgs links its own
# ncurses here; ours is the staging static archive.
sed -i "s|-lcurses|$STAGING/lib/libncursesw.a|" Makefile

make -j"$(sysctl -n hw.ncpu)"

mkdir -p "$STAGING/payload/opt/nix/libexec/lsof/bin"
install -m 0755 lsof "$STAGING/payload/opt/nix/libexec/lsof/bin/lsof"
