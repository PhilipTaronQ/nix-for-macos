#!/usr/bin/env bash
# lsof, for GC root discovery (lsof -n -w -F n, DESIGN §7.2). STAGING set.
# Release-tarball source (see fetch.sh) with pregenerated ./configure.
set -euo pipefail
./configure --prefix="$STAGING"
make -j"$(sysctl -n hw.ncpu)"
make install
