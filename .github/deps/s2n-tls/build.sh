#!/usr/bin/env bash
# s2n-tls, static, cmake. STAGING set (openssl libcrypto from staging).
# Upstream: BUILD_SHARED_LIBS=ON + UNSAFE_TREAT_WARNINGS_AS_ERRORS=OFF;
# we flip shared off.
set -euo pipefail
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$STAGING" -DCMAKE_PREFIX_PATH="$STAGING" \
  -DBUILD_SHARED_LIBS=OFF -DUNSAFE_TREAT_WARNINGS_AS_ERRORS=OFF \
  -DBUILD_TESTING=OFF
cmake --build build -j"$(sysctl -n hw.ncpu)"
cmake --install build
