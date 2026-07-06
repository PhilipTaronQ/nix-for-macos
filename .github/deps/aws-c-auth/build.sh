#!/usr/bin/env bash
# aws-c-auth, static, cmake. STAGING set (aws chain + s2n-tls there).
set -euo pipefail
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$STAGING" -DCMAKE_PREFIX_PATH="$STAGING" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF
cmake --build build -j"$(sysctl -n hw.ncpu)"
cmake --install build
