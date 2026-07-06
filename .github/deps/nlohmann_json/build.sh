#!/usr/bin/env bash
# nlohmann_json, header-only, cmake install. STAGING set.
set -euo pipefail
cmake -S . -B build -DCMAKE_INSTALL_PREFIX="$STAGING" -DJSON_BuildTests=OFF
cmake --install build
