#!/usr/bin/env bash
# libsodium, static, autotools. STAGING set. Pin uses a git snapshot.
set -euo pipefail
if [ ! -x ./configure ]; then
    # autotools come from the nix profile (debug-session.yml installs the
    # consolidated build-tool stanza); its share/aclocal merges libtool m4.
    export PATH="$HOME/.nix-profile/bin:$PATH"
    export ACLOCAL_PATH="${ACLOCAL_PATH:-$HOME/.nix-profile/share/aclocal}"
    autoreconf -fiv
fi
./configure --prefix="$STAGING" --disable-shared --enable-static
make -j"$(sysctl -n hw.ncpu)"
make install
