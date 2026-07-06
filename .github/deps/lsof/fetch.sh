#!/usr/bin/env bash
# lsof: fetch the RELEASE TARBALL, not the git snapshot — the tarball ships
# a pregenerated autotools ./configure, while the snapshot needs autoreconf
# (which its tree does not survive) and its legacy ./Configure shadows
# ./configure on macOS's case-insensitive filesystem.
set -euo pipefail
version=4.99.6
if [ "${1:-}" = "version" ]; then echo "$version"; exit 0; fi
dest=$1
src=$(nix --extra-experimental-features "nix-command flakes" build \
  --no-link --print-out-paths --impure --expr \
  "import <nix/fetchurl.nix> { url = \"https://github.com/lsof-org/lsof/releases/download/$version/lsof-$version.tar.gz\"; sha256 = \"03xacx0lfwc5ii93jg7agnj1i2fp9vhcpxrg0a51zmhwhkgxx0b0\"; }")
rm -rf "$dest"; mkdir -p "$dest"
tar -xf "$src" -C "$dest" --strip-components=1
echo "lsof $version"
