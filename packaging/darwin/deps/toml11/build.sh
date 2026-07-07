#!/usr/bin/env bash
# toml11, header-only, cmake install. STAGING set.
set -euo pipefail
cmake -S . -B build -DCMAKE_INSTALL_PREFIX="$STAGING" -DTOML11_BUILD_TESTS=OFF
cmake --install build
