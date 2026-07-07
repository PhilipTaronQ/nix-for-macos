#!/usr/bin/env bash
# libgit2 1.9.4 (flake override — see fetch.sh), static, cmake. STAGING set.
# Upstream cmakeFlags: REGEX_BACKEND=pcre2, USE_HTTP_PARSER=llhttp,
# USE_GSSAPI=FALSE, USE_SSH=ON, shared. Divergences: USE_SSH=OFF (libssh2 is
# a deliberate cut; libgit2 does no transport for Nix — git-utils.cc shells out),
# static. USE_ICONV stays at its darwin default (ON).
set -euo pipefail
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$STAGING" -DCMAKE_PREFIX_PATH="$STAGING" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF \
  -DREGEX_BACKEND=pcre2 -DUSE_HTTP_PARSER=llhttp \
  -DUSE_GSSAPI=FALSE -DUSE_SSH=OFF
cmake --build build -j"$(sysctl -n hw.ncpu)"
cmake --install build
