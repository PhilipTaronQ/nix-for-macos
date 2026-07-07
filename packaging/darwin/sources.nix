# The source manifest for building Nix's dependencies outside of Nix.
#
# Every dependency the standalone build compiles is named in
# deps/order.json (which is also the build order). Each name resolves
# through the same `nixDependencies` scope the flake build uses, so
# packaging/dependencies.nix overrides flow through structurally —
# libgit2 is 1.9.4 because the scope says so, and when the Nixpkgs pin
# catches up, the scope's versionAtLeast conditional flips both worlds in
# the same commit. Names the scope does not override fall back to the raw
# Nixpkgs attribute.
#
# The output is one derivation:
#   sources/<name>  — symlink to the dep's source
#   manifest.json   — { <name>: { version, source }, ... }
# The standalone build runs `nix build .#standalone-sources` once, and
# the dependency loop is nix-free from there (deps/dep.sh). Individual
# sources stay addressable for spelunking:
#   nix build .#standalone-sources.sources.libgit2.src
{
  lib,
  pkgs,
  nixDependencies,
}:

let
  names = builtins.fromJSON (builtins.readFile ./deps/order.json);

  # Deps whose Nixpkgs patches are the upstream patch series — the "pN"
  # in the version number. For these, srcOnly delivers the patched tree
  # (with Nixpkgs' own patch hooks cleared: hooks are where store paths
  # sneak into sources — git's git-sh-i18n.patch + postPatch hard-wires a
  # /nix/store gettext path, which is why raw src stays the default).
  upstreamPatchSeries = [
    "readline" # 8.3p3: readline83-001..003 (+ two static-irrelevant build patches)
    "bashInteractive" # 5.3p9: bash53-001..009 (+ pgrp-pipe)
  ];

  sources = lib.genAttrs names (
    name:
    let
      pkg = nixDependencies.${name} or pkgs.${name};
      # Some Linux bootstrap packages (libidn2) expose src only via .out;
      # irrelevant on Darwin, but it keeps the manifest buildable anywhere.
      drv = if pkg ? src then pkg else pkg.out;
    in
    {
      src =
        if lib.elem name upstreamPatchSeries then
          pkgs.srcOnly (drv.overrideAttrs {
            prePatch = "";
            postPatch = "";
          })
        else
          drv.src;
      inherit (pkg) version;
    }
  );
in

pkgs.runCommand "standalone-sources"
  {
    manifest = builtins.toJSON (
      lib.mapAttrs (name: s: {
        inherit (s) version;
        source = s.src;
      }) sources
    );
    passAsFile = [ "manifest" ];
    passthru = {
      inherit sources;
    };
  }
  ''
    mkdir -p "$out/sources"
    cp "$manifestPath" "$out/manifest.json"
    ${lib.concatMapStrings (name: ''
      ln -s ${sources.${name}.src} "$out/sources/${name}"
    '') names}
  ''
