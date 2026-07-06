#!/usr/bin/env bash
# libarchive, static, cmake. STAGING set. Upstream uses default features;
# detection is confined to staging (PKG_CONFIG_LIBDIR via dep.sh +
# CMAKE_PREFIX_PATH), so it finds zlib/bzip2/xz/zstd/lzo/openssl/libxml2
# there. lz4 explicitly off (not in the pin closure). cmake instead of
# autotools: same git-snapshot autoreconf problem as libxml2.
set -euo pipefail
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$STAGING" -DCMAKE_PREFIX_PATH="$STAGING" \
  -DBUILD_SHARED_LIBS=OFF -DENABLE_TEST=OFF -DENABLE_LZ4=OFF \
  -DENABLE_WERROR=OFF
cmake --build build -j"$(sysctl -n hw.ncpu)"
cmake --install build
