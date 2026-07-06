#!/usr/bin/env bash
# brotli (libbrotlicommon/dec/enc), static, cmake. STAGING set.
set -euo pipefail
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$STAGING" -DBUILD_SHARED_LIBS=OFF
cmake --build build -j"$(sysctl -n hw.ncpu)"
cmake --install build
