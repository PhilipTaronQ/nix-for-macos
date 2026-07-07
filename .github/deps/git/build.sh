#!/usr/bin/env bash
# git — the §7.1 bundled git. STAGING set. Knobs per DESIGN:
#   NO_GETTEXT (parse-stable English output), NO_PERL/NO_PYTHON/NO_TCLTK,
#   NO_EXPAT (http-push only), no USE_LIBPCRE, NO_APPLE_COMMON_CRYPTO +
#   NO_OPENSSL (bundled collision-detecting DC_SHA1 + bundled SHA-256),
#   git-https via our sliced static curl (curl-config --static-libs).
# No git-credential-osxkeychain (netrc is the supported path, §7.1).
# Two static-link traps, both worked around below:
#   - configure probes bare -lcurl, which cannot link against static
#     libcurl; the cache var asserts curl exists, and CURL_LDFLAGS at make
#     time supplies the real closure.
#   - no blanket -I$STAGING/include: libarchive's archive.h would shadow
#     git's own archive.h. curl headers come via curl-config; zlib
#     compiles against the SDK header, links staging's static 1.3.2.
set -euo pipefail
KNOBS=(
  NO_GETTEXT=1 NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_EXPAT=1
  NO_APPLE_COMMON_CRYPTO=1 NO_OPENSSL=1 NO_INSTALL_HARDLINKS=1
  CURL_LDFLAGS="$("$STAGING/bin/curl-config" --static-libs)"
)
./configure --prefix=/opt/nix/libexec/git \
  ac_cv_prog_CURL_CONFIG="$STAGING/bin/curl-config" \
  ac_cv_lib_curl_curl_global_init=yes \
  LDFLAGS="-L$STAGING/lib -Wl,-search_paths_first"
make -j"$(sysctl -n hw.ncpu)" "${KNOBS[@]}"
make "${KNOBS[@]}" DESTDIR="$STAGING/payload" install
