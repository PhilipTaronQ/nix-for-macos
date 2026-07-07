#!/usr/bin/env bash
# boost, static, b2. STAGING set. The slice mirrors packaging/
# dependencies.nix exactly: container, context, coroutine, iostreams, url;
# no ICU (Nix uses boost::regex header-only, no u32regex/locale). iostreams
# is pointed at staging for zlib/bzip2/xz/zstd.
set -euo pipefail
./bootstrap.sh --prefix="$STAGING" --without-icu \
  --with-libraries=container,context,coroutine,iostreams,url
./b2 -j"$(sysctl -n hw.ncpu)" install \
  link=static variant=release threading=multi \
  -sZLIB_INCLUDE="$STAGING/include" -sZLIB_LIBPATH="$STAGING/lib" \
  -sBZIP2_INCLUDE="$STAGING/include" -sBZIP2_LIBPATH="$STAGING/lib" \
  -sZSTD_INCLUDE="$STAGING/include" -sZSTD_LIBPATH="$STAGING/lib" \
  -sLZMA_INCLUDE="$STAGING/include" -sLZMA_LIBPATH="$STAGING/lib"
