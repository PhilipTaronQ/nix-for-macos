#!/usr/bin/env bash
# ngtcp2, static, lib-only, cmake. STAGING set. Upstream builds shared,
# examples on; we build static lib-only. ENABLE_OPENSSL builds
# libngtcp2_crypto_ossl against openssl 3.5+ QUIC TLS API — REQUIRED for
# curl HTTP/3 with the openssl backend; verify it exists after install.
set -euo pipefail
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$STAGING" -DCMAKE_PREFIX_PATH="$STAGING" \
  -DENABLE_LIB_ONLY=ON -DENABLE_STATIC_LIB=ON -DENABLE_SHARED_LIB=OFF \
  -DENABLE_OPENSSL=ON
cmake --build build -j"$(sysctl -n hw.ncpu)"
cmake --install build
test -f "$STAGING/lib/libngtcp2_crypto_ossl.a"
