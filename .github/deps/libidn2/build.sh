#!/usr/bin/env bash
# libidn2, static, autotools. STAGING set. Upstream default flags; iconv
# comes from the SDK (DESIGN §6.5), libunistring from staging.
set -euo pipefail
./configure --prefix="$STAGING" --disable-shared --enable-static \
  --with-libunistring-prefix="$STAGING"
make -j"$(sysctl -n hw.ncpu)"
make install
