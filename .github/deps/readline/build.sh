#!/usr/bin/env bash
# readline, static. STAGING set. Helper-executable dep for bash (§7.2).
set -euo pipefail
./configure --prefix="$STAGING" --disable-shared --enable-static \
  --with-curses
make -j"$(sysctl -n hw.ncpu)"
make install
