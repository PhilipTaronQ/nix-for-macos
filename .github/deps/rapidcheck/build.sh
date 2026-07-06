#!/usr/bin/env bash
# rapidcheck, static, cmake. TEST-ONLY staging dep (DESIGN §10). Upstream
# passes RC_INSTALL_ALL_EXTRAS (gtest integration headers); we flip shared
# off.
set -euo pipefail
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$STAGING" -DCMAKE_PREFIX_PATH="$STAGING" \
  -DBUILD_SHARED_LIBS=OFF -DRC_INSTALL_ALL_EXTRAS=TRUE
cmake --build build -j"$(sysctl -n hw.ncpu)"
cmake --install build
