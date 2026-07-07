#!/usr/bin/env bash
# lsof, for GC root discovery (lsof -n -w -F n, DESIGN §7.2). STAGING set.
# Release-tarball source (see fetch.sh) with pregenerated ./configure.
set -euo pipefail
./configure --prefix=/opt/nix/libexec/lsof
make -j"$(sysctl -n hw.ncpu)"
make DESTDIR="$STAGING/payload" install

# lsof installs a vestigial liblsof dylib (the binary does not link it)
# and man pages; neither belongs in the payload.
lsofroot="$STAGING/payload/opt/nix/libexec/lsof"
rm -rf "$lsofroot/lib" "$lsofroot/share" "$lsofroot/include"
