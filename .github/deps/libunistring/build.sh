#!/usr/bin/env bash
# libunistring, static, autotools. STAGING set. Upstream passes
# --with-libiconv-prefix=<GNU libiconv>; we deliberately omit it so configure
# finds the SDK iconv.h + /usr/lib/libiconv.dylib instead (DESIGN.md §6.5).
set -euo pipefail
./configure --prefix="$STAGING" --disable-shared --enable-static
make -j"$(sysctl -n hw.ncpu)"
make install
