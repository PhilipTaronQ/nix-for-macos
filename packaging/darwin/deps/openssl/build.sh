#!/usr/bin/env bash
# openssl, static. Run from the unpacked source root; STAGING set.
# Upstream flags (nix eval …#openssl.configureFlags): shared --libdir=lib
# --openssldir=etc/ssl no-afalgeng. Deliberate divergences:
# no-shared (store-free build), and OPENSSLDIR=/etc/ssl ABSOLUTE — the
# Apple-maintained trust store, not a prefix-relative dir. install_sw only:
# install_ssldirs would write into the real /etc/ssl.
set -euo pipefail
perl ./Configure no-shared --prefix="$STAGING" --libdir=lib \
  --openssldir=/etc/ssl no-afalgeng darwin64-arm64-cc
make -j"$(sysctl -n hw.ncpu)"
make install_sw
