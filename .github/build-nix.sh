#!/usr/bin/env bash
# Build Nix itself against the staging prefix (DESIGN §9.1 steps 5–7).
# Run from the repo root with STAGING set; installs into $NIX_OUT.
# Build tools (meson/ninja/cmake/pkg-config/bison/flex) from the demoted Nix.
set -euo pipefail
: "${STAGING:?set STAGING to the absolute staging prefix}"
export PAYLOAD="${PAYLOAD:-$PWD/outputs/payload}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export PKG_CONFIG_LIBDIR="$STAGING/lib/pkgconfig:$STAGING/share/pkgconfig"
# Staging bin first: meson captures bash (and git/ssh) at configure time —
# /bin/bash is Apple 3.2, too old for the functional-test scripts.
export PATH="$STAGING/bin:$PATH"
export BOOST_ROOT="$STAGING"        # meson finds boost via env, not pkg-config
export CMAKE_PREFIX_PATH="$STAGING" # aws-crt-cpp is found via cmake
# The nix-shell tool closures carry nixpkgs clang — pin Apple's toolchain
# explicitly or the Compiler decision (§3) silently inverts.
export CC=/usr/bin/clang CXX=/usr/bin/clang++
# Bare /usr/bin/clang hides the SDK from meson's find_library directory
# scan (no SDK in -print-search-dirs, unlike nixpkgs wrapped clang) — hand
# it over explicitly so system .tbd libs (libsandbox) are findable.
export SDKROOT=$(xcrun --show-sdk-path)
export LDFLAGS="-L$SDKROOT/usr/lib"
# Build tools come from the nix profile — debug-session.yml installs the
# consolidated stanza (meson ninja cmake pkg-config bison flex autoconf
# automake libtool m4 bmake jsonschema) via `nix profile add`.
export PATH="$HOME/.nix-profile/bin:$PATH"
for t in meson ninja cmake pkg-config bison flex jv; do
  command -v "$t" >/dev/null || { echo "missing build tool: $t (see debug-session.yml build-tools step)" >&2; exit 1; }
done
meson setup build --prefix=/opt/nix \
  -Dsysconfdir=/etc -Dlocalstatedir=/nix/var \
  -Dlibfetchers:git-program=/opt/nix/libexec/git/bin/git \
  -Dlibstore:ssh-program=/opt/nix/libexec/openssh/bin/ssh \
  -Dlibstore:lsof-program=/opt/nix/libexec/lsof/bin/lsof \
  -Dnix:bash-program=/opt/nix/libexec/bash/bin/bash \
  -Dbuildtype=release -Dstrip=true \
      -Dprefer_static=true \
      -Ddefault_library=static \
      "-Dcpp_link_args=-framework Network -framework Security -mmacosx-version-min=14.0" \
      "-Dcpp_args=-isystem $STAGING/include -mmacosx-version-min=14.0" \
      "-Dc_args=-isystem $STAGING/include -mmacosx-version-min=14.0" \
      -Dunit-tests=true -Dfunctional-tests=true -Ddoc-gen=false -Djson-schema-checks=true \
      -Dlibstore:s3-aws-auth=enabled \
      -Dlibstore:embedded-sandbox-shell=false \
      -Dlibcmd:markdown=enabled \
  -Dlibfetchers:mercurial-fetcher=false
    ninja -C build -j"$(sysctl -n hw.ncpu)"
    meson install -C build --destdir "$PAYLOAD"

# Slim the payload: the .pkg is a runtime artifact (§11.2a). Dev headers,
# static component archives + pkg-config, and the unit-test executables
# meson installs all stay in the build tree only.
rm -rf "$PAYLOAD/opt/nix/include" "$PAYLOAD/opt/nix/lib"
rm -f "$PAYLOAD/opt/nix/bin/"nix-*-tests

# Populate the REAL /opt/nix so the baked absolute paths resolve during the
# test ladder (one build flavor: what ships is what's tested — §11.2a). The
# runner is ephemeral; sudo is passwordless.
sudo mkdir -p /opt/nix
sudo ditto "$STAGING/payload/opt/nix" /opt/nix
sudo ditto "$PAYLOAD/opt/nix" /opt/nix
