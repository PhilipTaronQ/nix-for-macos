#!/usr/bin/env bash
# openssh — CLIENT ONLY (ssh binary; DESIGN §7.2). STAGING set. Upstream
# flags minus the slice: no libedit, no ldns (DNSSEC), no security-key
# builtin (FIDO2), no PAM. openssl + zlib from staging, static.
# --sysconfdir=/etc/ssh keeps the system-wide client config location.
set -euo pipefail
./configure --prefix="$STAGING" --sysconfdir=/etc/ssh \
  --with-ssl-dir="$STAGING" --with-zlib="$STAGING" \
  --without-pam --without-libedit --without-ldns \
  LDFLAGS="-L$STAGING/lib -Wl,-search_paths_first"
make -j"$(sysctl -n hw.ncpu)" ssh
install -m755 ssh "$STAGING/bin/ssh"
