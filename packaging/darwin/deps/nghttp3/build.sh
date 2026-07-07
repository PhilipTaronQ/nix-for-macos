#!/usr/bin/env bash
# nghttp3, static, cmake, library only (no examples/apps). STAGING set.
set -euo pipefail
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$STAGING" \
  -DENABLE_LIB_ONLY=ON -DENABLE_SHARED_LIB=OFF -DENABLE_STATIC_LIB=ON
cmake --build build -j"$(sysctl -n hw.ncpu)"
cmake --install build
