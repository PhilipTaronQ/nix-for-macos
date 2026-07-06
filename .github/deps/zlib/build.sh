#!/usr/bin/env bash
# zlib, static. Run from the unpacked source root with STAGING set to the
# absolute staging prefix. Source: nixpkgs pin, zlib.src.
set -euo pipefail
./configure --prefix="$STAGING" --static
make -j"$(sysctl -n hw.ncpu)"
make install
