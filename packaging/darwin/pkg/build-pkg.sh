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

# Optional config fragments: each is a real nix.conf snippet, packaged as its
# own Distribution choice. A selected choice drops its .conf into the STAGING
# dir /opt/nix/etc/includes.install; nix-install then reconciles the live dir
# /opt/nix/etc/includes to exactly what was staged (moving staged fragments in,
# dropping deselected ones) and wires the result into /etc/nix/nix.conf. The
# move makes staging a fresh per-install manifest, so unticking a choice on a
# reinstall removes it. Ordered before the core package so staging is populated
# when `nix-install install` runs.
fragment_pkg() {  # <name> <identifier> <conf line>
    local tree="$work/frag-$1"
    mkdir -p "$tree/opt/nix/etc/includes.install"
    printf '%s\n' "$3" > "$tree/opt/nix/etc/includes.install/$1.conf"
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

# Installer resources referenced by Distribution.xml: the Nix logomark used
# as the background (see resources/ATTRIBUTION).
resources="$work/resources"
mkdir -p "$resources"
cp "$here/resources/nix-logo.png" "$resources/nix-logo.png"

productbuild \
    --distribution "$work/Distribution.xml" \
    --package-path "$work" \
    --resources "$resources" \
    "$out"

echo "built: $out"
shasum -a 256 "$out"
