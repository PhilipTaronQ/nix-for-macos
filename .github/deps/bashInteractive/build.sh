#!/usr/bin/env bash
# bashInteractive, the §7.2 interactive-fallback shell. STAGING set.
# Upstream flags: --without-bash-malloc --with-installed-readline (staging
# readline + ncurses, both static).
set -euo pipefail
./configure --prefix=/opt/nix/libexec/bash \
  --without-bash-malloc --with-installed-readline \
  bash_cv_termcap_lib=libncurses \
  CPPFLAGS="-I$STAGING/include" LDFLAGS="-L$STAGING/lib -Wl,-search_paths_first"
make -j"$(sysctl -n hw.ncpu)"
make DESTDIR="$STAGING/payload" install
