#!/usr/bin/env bash
# googletest (gtest+gmock), static, cmake. TEST-ONLY staging dep: linked
# into unit-test executables, never into shipped binaries (DESIGN §10).
set -euo pipefail
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$STAGING" -DBUILD_SHARED_LIBS=OFF
cmake --build build -j"$(sysctl -n hw.ncpu)"
cmake --install build
