#!/usr/bin/env bash
# bashInteractive, the interactive-fallback shell. STAGING set.
# Upstream flags: --without-bash-malloc --with-installed-readline (staging
# readline + ncurses, both static).
set -euo pipefail
./configure --prefix=/opt/nix/libexec/bash \
  --without-bash-malloc --with-installed-readline \
  bash_cv_termcap_lib=libncurses \
  CPPFLAGS="-I$STAGING/include" LDFLAGS="-L$STAGING/lib -Wl,-search_paths_first"
make -j"$(sysctl -n hw.ncpu)"
make DESTDIR="$STAGING/payload" install

# Runtime artifact: translations and documentation stay out of the payload.
bashroot="$STAGING/payload/opt/nix/libexec/bash"
rm -rf "$bashroot/share/locale" "$bashroot/share/man" \
       "$bashroot/share/doc" "$bashroot/share/info"
