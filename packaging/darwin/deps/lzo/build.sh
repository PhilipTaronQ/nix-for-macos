#!/usr/bin/env bash
# lzo, static. Run from the unpacked source root; STAGING set.
# Source: nixpkgs pin, lzo.src.
set -euo pipefail
./configure --prefix="$STAGING" --disable-shared --enable-static
make -j"$(sysctl -n hw.ncpu)"
make install
