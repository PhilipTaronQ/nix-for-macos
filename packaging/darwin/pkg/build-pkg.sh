#!/usr/bin/env bash
# Assemble the macOS installer package.
#
# Usage: build-pkg.sh <payload-tree> <nix-install-binary> <version> [out.pkg]
#   <payload-tree>       the /opt/nix tree (the macos-build artifact)
#   <nix-install-binary> the compiled installer engine
#
# The .pkg lays the payload down at /opt/nix (with the installer engine at
# /opt/nix/libexec/nix-install) and its postinstall runs
# `nix-install install`, which applies the install plan for everything that
# is system STATE rather than files: the APFS volume, fstab, users,
# launchd services, config, shell init — all recorded in the install
# ledger for exact reversal by `nix-install uninstall`.
#
# Unsigned for now; notarization once a Developer ID exists.
set -euo pipefail

payload=${1:?payload tree}
engine=${2:?nix-install binary}
version=${3:?version}
out=${4:-nix-$version-aarch64-darwin.pkg}

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Stage: the payload at ./opt/nix + the engine inside it.
mkdir -p "$work/root/opt"
cp -R "$payload" "$work/root/opt/nix"
install -m 0755 "$engine" "$work/root/opt/nix/libexec/nix-install"

mkdir -p "$work/scripts"
cat > "$work/scripts/postinstall" <<'EOF'
#!/bin/sh
# Files are down (this package's payload); now the system state.
exec /opt/nix/libexec/nix-install install
EOF
chmod 0755 "$work/scripts/postinstall"

pkgbuild \
    --root "$work/root" \
    --identifier org.nixos.nix \
    --version "$version" \
    --install-location / \
    --scripts "$work/scripts" \
    "$work/nix-component.pkg"

# Optional config fragments: each is a real nix.conf snippet shipped under
# /opt/nix/etc/includes, packaged as its own Distribution choice. Installed
# only if the user selects the choice; nix-install then wires whichever are
# present into /etc/nix/nix.conf via !include (recorded in the ledger, removed
# on uninstall). Ordered before the core package so the fragment exists when
# `nix-install install` runs.
fragment_pkg() {  # <name> <identifier> <conf line>
    local tree="$work/frag-$1"
    mkdir -p "$tree/opt/nix/etc/includes"
    printf '%s\n' "$3" > "$tree/opt/nix/etc/includes/$1.conf"
    pkgbuild \
        --root "$tree" \
        --identifier "$2" \
        --version "$version" \
        --install-location / \
        "$work/nix-$1.pkg"
}
fragment_pkg flakes  org.nixos.nix.flakes  "experimental-features = nix-command flakes"
fragment_pkg sandbox org.nixos.nix.sandbox "sandbox = true"

sed "s/@VERSION@/$version/g" "$here/Distribution.xml" > "$work/Distribution.xml"

productbuild \
    --distribution "$work/Distribution.xml" \
    --package-path "$work" \
    "$out"

echo "built: $out"
shasum -a 256 "$out"
