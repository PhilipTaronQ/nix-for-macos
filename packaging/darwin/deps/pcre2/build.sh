#!/usr/bin/env bash
# pcre2, static. Run from the unpacked source root; STAGING set.
# Source: nixpkgs pin, pcre2.src. Flags below mirror the pin exactly
# (nix eval …#pcre2.configureFlags): 16/32-bit widths + JIT.
set -euo pipefail
./configure --prefix="$STAGING" --disable-shared --enable-static \
  --enable-pcre2-16 --enable-pcre2-32 --enable-jit=auto --enable-jit-sealloc
make -j"$(sysctl -n hw.ncpu)"
make install
