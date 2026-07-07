#!/usr/bin/env bash
# xz (liblzma), static. Run from the unpacked source root; STAGING = absolute
# staging prefix. Source: nixpkgs pin, xz.src.
set -euo pipefail
./configure --prefix="$STAGING" --disable-shared --enable-static
make -j"$(sysctl -n hw.ncpu)"
make install
