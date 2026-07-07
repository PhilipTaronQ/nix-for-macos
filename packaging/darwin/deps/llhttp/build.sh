#!/usr/bin/env bash
# llhttp, static, cmake (release tags ship generated C sources). STAGING set.
# Options are namespaced LLHTTP_* — plain BUILD_SHARED_LIBS=OFF silently
# builds only the shared lib.
set -euo pipefail
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$STAGING" \
  -DLLHTTP_BUILD_SHARED_LIBS=OFF -DLLHTTP_BUILD_STATIC_LIBS=ON
cmake --build build -j"$(sysctl -n hw.ncpu)"
cmake --install build
