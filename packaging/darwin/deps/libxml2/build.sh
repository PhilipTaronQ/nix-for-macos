#!/usr/bin/env bash
# libxml2, static, cmake. STAGING set. Kept for libarchive (xar) — NOT a
# a deliberate cut. Feature flags mirror upstream configureFlags (--without-icu/
# python/http/zlib/docs). cmake instead of autotools: the git-snapshot tree
# does not survive a fresh autoreconf under the nix-shell toolchain (core-
# macro m4 errors); features, not build system, are the fidelity surface.
set -euo pipefail
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$STAGING" -DBUILD_SHARED_LIBS=OFF \
  -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_PYTHON=OFF \
  -DLIBXML2_WITH_HTTP=OFF -DLIBXML2_WITH_ZLIB=OFF \
  -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PROGRAMS=OFF
cmake --build build -j"$(sysctl -n hw.ncpu)"
cmake --install build
