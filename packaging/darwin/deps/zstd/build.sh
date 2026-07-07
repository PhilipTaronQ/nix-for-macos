#!/usr/bin/env bash
# zstd (libzstd), static, multithreaded — nixpkgs builds via cmake with
# ZSTD_MULTITHREAD_SUPPORT on; lib-mt is the Makefile equivalent. Run from
# the unpacked source root; STAGING set. Source: nixpkgs pin, zstd.src.
set -euo pipefail
make -C lib -j"$(sysctl -n hw.ncpu)" lib-mt
make -C lib install-static install-includes install-pc PREFIX="$STAGING"
