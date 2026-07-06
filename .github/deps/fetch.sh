#!/usr/bin/env bash
# Fetch and unpack one dependency's source from the nixpkgs pin.
#
# Usage: .github/deps/fetch.sh <nixpkgs-attr> <dest-dir>
#
# The pin is read from flake.lock (nodes.nixpkgs.locked.rev) — the single
# source of truth — never hardcoded. The demoted Nix resolves and fetches
# the exact source the pin specifies; this script normalizes the two shapes
# a `.src` can take (a tarball, or a fetchFromGitHub directory — zstd is the
# latter) into a fresh, writable <dest-dir>. Prints "<attr> <version>".
#
# CAVEAT: raw `nixpkgs#<attr>` is correct only for deps the flake does not
# override. Overridden deps (libgit2 → 1.9.4, boost, libblake3, boehmgc, …)
# must be sourced through the flake's own eval when we reach them — see
# DESIGN.md §6.2/§9.3.
set -euo pipefail

attr=$1
dest=$2
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

pin=$(jq -r '.nodes.nixpkgs.locked.rev' "$repo_root/flake.lock")
nix=(nix --extra-experimental-features nix-command --extra-experimental-features flakes)

src=$("${nix[@]}" build --no-link --print-out-paths "github:NixOS/nixpkgs/$pin#$attr.src")
version=$("${nix[@]}" eval --raw "github:NixOS/nixpkgs/$pin#$attr.version")

rm -rf "$dest"
mkdir -p "$dest"
if [ -d "$src" ]; then
    cp -R "$src/." "$dest/"
    chmod -R u+w "$dest"
else
    tar -xf "$src" -C "$dest" --strip-components=1
fi

echo "$attr $version"
