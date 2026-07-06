#!/usr/bin/env bash
# Build Nix itself against the staging prefix (DESIGN §9.1 steps 5–7).
# Run from the repo root with STAGING set; installs into $NIX_OUT.
# Build tools (meson/ninja/cmake/pkg-config/bison/flex) from the demoted Nix.
set -euo pipefail
: "${STAGING:?set STAGING to the absolute staging prefix}"
export NIX_OUT="${NIX_OUT:-$PWD/outputs/nix}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export PKG_CONFIG_LIBDIR="$STAGING/lib/pkgconfig:$STAGING/share/pkgconfig"
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
pin=$(jq -r ".nodes.nixpkgs.locked.rev" flake.lock)
nix --extra-experimental-features "nix-command flakes" shell \
  "github:NixOS/nixpkgs/$pin#meson" \
  "github:NixOS/nixpkgs/$pin#ninja" \
  "github:NixOS/nixpkgs/$pin#cmake" \
  "github:NixOS/nixpkgs/$pin#pkg-config" \
  "github:NixOS/nixpkgs/$pin#bison" \
  "github:NixOS/nixpkgs/$pin#flex" \
  --command bash -c "
    set -euo pipefail
    meson setup build --prefix=\"\$NIX_OUT\" \
      -Dprefer_static=true \
      -Ddefault_library=static \
      \"-Dcpp_link_args=-framework Network -framework Security\" \
      \"-Dcpp_args=-isystem \$STAGING/include\" \
      \"-Dc_args=-isystem \$STAGING/include\" \
      -Dunit-tests=false -Dfunctional-tests=false -Ddoc-gen=false -Djson-schema-checks=false \
      -Dlibstore:s3-aws-auth=enabled \
      -Dlibstore:embedded-sandbox-shell=false \
      -Dlibcmd:markdown=enabled
    ninja -C build -j\"\$(sysctl -n hw.ncpu)\"
    meson install -C build
  "
