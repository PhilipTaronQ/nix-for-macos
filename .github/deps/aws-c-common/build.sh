#!/usr/bin/env bash
# aws-c-common, static, cmake. STAGING set. Leaf of the AWS chain.
set -euo pipefail
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$STAGING" -DBUILD_SHARED_LIBS=OFF
cmake --build build -j"$(sysctl -n hw.ncpu)"
cmake --install build
