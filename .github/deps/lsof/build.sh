#!/usr/bin/env bash
# lsof, for GC root discovery (lsof -n -w -F n, DESIGN §7.2). STAGING set.
#
# Nixpkgs-faithful build: the pinned src is the tag snapshot (no
# pregenerated autotools configure), driven through the LEGACY ./Configure
# dialect system exactly as nixpkgs does — which also sidesteps the
# configure/Configure clash on case-insensitive APFS, because nothing ever
# generates a `configure`. The legacy build has no `make install`; the
# payload is the one binary.
set -euo pipefail
LSOF_CC=cc LSOF_AR="ar cr" LSOF_RANLIB=ranlib ./Configure -n darwin
make -j"$(sysctl -n hw.ncpu)"

mkdir -p "$STAGING/payload/opt/nix/libexec/lsof/bin"
install -m 0755 lsof "$STAGING/payload/opt/nix/libexec/lsof/bin/lsof"
