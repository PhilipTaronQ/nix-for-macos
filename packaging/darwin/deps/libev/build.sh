#!/usr/bin/env bash
# libev, static, autotools. STAGING set. Upstream ships no .pc file.
set -euo pipefail
./configure --prefix="$STAGING" --disable-shared --enable-static
make -j"$(sysctl -n hw.ncpu)"
make install
