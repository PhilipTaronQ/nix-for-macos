#!/usr/bin/env bash
# readline, static. STAGING set. Helper-executable dep for bash.
set -euo pipefail
./configure --prefix="$STAGING" --disable-shared --enable-static \
  --with-curses
make -j"$(sysctl -n hw.ncpu)"
make install
