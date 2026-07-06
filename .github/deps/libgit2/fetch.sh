#!/usr/bin/env bash
# libgit2 is flake-overridden (packaging/dependencies.nix): the pin ships
# 1.9.3 but Nix requires 1.9.4, fetched by exact tag + hash. Keep version
# and hash in lockstep with packaging/dependencies.nix — upstream drops the
# override once the pin catches up, and so should this file.
set -euo pipefail
version=1.9.4
hash=sha256-ZKUiz3pdFE2SKxh53X2oyr7hs32Njj5YVA0OXDXz7h0=
if [ "${1:-}" = "version" ]; then echo "$version"; exit 0; fi
dest=$1
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
pin=$(jq -r ".nodes.nixpkgs.locked.rev" "$repo_root/flake.lock")
src=$(nix --extra-experimental-features "nix-command flakes" build \
  --no-link --print-out-paths --impure --expr \
  "(builtins.getFlake \"github:NixOS/nixpkgs/$pin\").legacyPackages.\${builtins.currentSystem}.fetchFromGitHub { owner = \"libgit2\"; repo = \"libgit2\"; tag = \"v$version\"; hash = \"$hash\"; }")
rm -rf "$dest"; mkdir -p "$dest"
cp -R "$src/." "$dest/"; chmod -R u+w "$dest"
echo "libgit2 $version"
