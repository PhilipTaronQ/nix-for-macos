#!/usr/bin/env bash
# aws-crt-cpp, static, cmake — tier 6, top of the AWS chain. STAGING set.
# BUILD_DEPS=OFF: use the staged aws-c-*/s2n-tls, not vendored submodules.
set -euo pipefail
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$STAGING" -DCMAKE_PREFIX_PATH="$STAGING" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DBUILD_DEPS=OFF
cmake --build build -j"$(sysctl -n hw.ncpu)"
cmake --install build
