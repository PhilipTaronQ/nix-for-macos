#!/usr/bin/env bash
# libblake3, static, cmake (source lives in c/). STAGING set. TBB off:
# upstream computes useTBB=false for static + LLVM libc++.
set -euo pipefail
cmake -S c -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$STAGING" -DBUILD_SHARED_LIBS=OFF \
  -DBLAKE3_USE_TBB=OFF
cmake --build build -j"$(sysctl -n hw.ncpu)"
cmake --install build
