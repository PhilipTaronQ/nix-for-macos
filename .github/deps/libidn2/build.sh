#!/usr/bin/env bash
# libidn2, static, autotools. STAGING set. Upstream default flags; iconv
# comes from the SDK (DESIGN §6.5), libunistring from staging.
set -euo pipefail
./configure --prefix="$STAGING" --disable-shared --enable-static \
  --with-libunistring-prefix="$STAGING"
make -j"$(sysctl -n hw.ncpu)"
make install
# Static-only staging: consumers must link libunistring; curl's pkg-config
# probe does not use --static, so promote it from Libs.private to Libs.
sed -i "s|^Libs: -L\${libdir} -lidn2$|Libs: -L\${libdir} -lidn2 -lunistring|" \
  "$STAGING/lib/pkgconfig/libidn2.pc"
