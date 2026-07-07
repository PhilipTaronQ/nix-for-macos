#!/usr/bin/env bash
# lowdown, static. STAGING set. BSD-make project: bmake comes from the nix
# profile (consolidated build-tool stanza). The install also ships a dylib;
# remove it — staging is static-only.
set -euo pipefail
export PATH="$HOME/.nix-profile/bin:$PATH"
./configure PREFIX="$STAGING"
bmake -j"$(sysctl -n hw.ncpu)"
bmake install install_libs
rm -f "$STAGING"/lib/liblowdown*.dylib "$STAGING"/lib/liblowdown*.so*
