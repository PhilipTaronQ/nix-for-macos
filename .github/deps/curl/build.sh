#!/usr/bin/env bash
# curl, static. STAGING set. Flags mirror the flake-overridden curl
# (packaging/dependencies.nix: http3 + zstd/brotli/zlib) as evaluated at the
# pin, with store paths → staging and the §6.3 cuts applied:
#   --without-libpsl --without-gssapi --without-libssh2  (upstream: with)
# HTTP/3: openssl 3.6.2 has QUIC APIv2 (SSL_set_quic_tls_cbs), so configure
# requires libngtcp2_crypto_ossl via pkg-config (curl m4/curl-openssl.m4 +
# configure.ac:3321 at curl-8_20_0). --with-ca-fallback + --without-ca-bundle/
# path delegate trust to OPENSSLDIR=/etc/ssl (§8).
set -euo pipefail
./configure --prefix="$STAGING" --disable-shared --enable-static \
  --enable-versioned-symbols --disable-manual --disable-ares \
  --disable-ldap --disable-ldaps --disable-websockets \
  --with-ca-fallback --without-ca-bundle --without-ca-path \
  --with-openssl="$STAGING" --with-zlib="$STAGING" \
  --with-brotli="$STAGING" --with-zstd="$STAGING" \
  --with-nghttp2="$STAGING" --with-nghttp3="$STAGING" --with-ngtcp2="$STAGING" \
  --with-libidn2="$STAGING" \
  --without-libpsl --without-gssapi --without-libssh2 \
  --without-librtmp --without-rustls --without-gnutls
make -j"$(sysctl -n hw.ncpu)"
make install
