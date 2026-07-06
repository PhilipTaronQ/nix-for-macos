#!/usr/bin/env bash
# nghttp2, static, LIBRARY ONLY. STAGING set. Upstream builds the apps
# (--enable-app), which is what pulls c-ares/libev; lib-only is the blessed
# §6.3 divergence that cuts them. HTTP/3 in curl comes via ngtcp2/nghttp3,
# not nghttp2.
set -euo pipefail
./configure --prefix="$STAGING" --disable-shared --enable-static --enable-lib-only
make -j"$(sysctl -n hw.ncpu)"
make install
