#!/usr/bin/env bash
# aws-c-compression, static, cmake. STAGING set (finds aws-c-common via CMAKE_PREFIX_PATH).
set -euo pipefail
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$STAGING" -DCMAKE_PREFIX_PATH="$STAGING" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF
cmake --build build -j"$(sysctl -n hw.ncpu)"
cmake --install build
