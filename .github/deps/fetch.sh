#!/usr/bin/env bash
# Unpack one dependency's pinned source from the standalone-sources manifest.
#
# Usage: .github/deps/fetch.sh <name> <dest-dir>
#
# The source oracle is the flake itself: `nix build .#standalone-sources`
# yields manifest.json + sources/<name> links, resolved through the same
# nixDependencies scope the Nix build uses — packaging/dependencies.nix
# overrides (libgit2 1.9.4 today) flow through with zero shell-side
# bookkeeping. $SOURCES may point at a prebuilt manifest (build-all.sh
# exports it); otherwise one flake build provisions it here.
#
# Normalizes the shapes a `.src` can take (a tarball; a fetchFromGitHub
# directory — zstd; a zip — sqlite) into a fresh, writable <dest-dir>.
# Prints "<name> <version>".
set -euo pipefail

name=$1
dest=$2
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

if [ -z "${SOURCES:-}" ]; then
    SOURCES=$(nix --extra-experimental-features 'nix-command flakes' \
        build --no-link --print-out-paths "$repo_root#standalone-sources")
fi

src=$(jq -er --arg n "$name" '.[$n].source' "$SOURCES/manifest.json")
version=$(jq -er --arg n "$name" '.[$n].version' "$SOURCES/manifest.json")

rm -rf "$dest"
mkdir -p "$dest"
if [ -d "$src" ]; then
    cp -R "$src/." "$dest/"
    chmod -R u+w "$dest"
else
    case "$src" in
        *.zip)
            # sqlite pins a zip; bsdtar (Apple's /usr/bin/tar) reads it —
            # the GNU tar the tool stanza puts on PATH does not.
            /usr/bin/tar -xf "$src" -C "$dest" --strip-components=1 ;;
        *)
            tar -xf "$src" -C "$dest" --strip-components=1 ;;
    esac
fi

echo "$name $version"
