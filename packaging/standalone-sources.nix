# The source manifest for the macOS-standalone build (DESIGN.md §6/§9).
#
# Every external dependency the standalone build compiles is named in
# .github/deps/order.json (which is also the build order). Each name
# resolves through the same `nixDependencies` scope the flake build uses,
# so packaging/dependencies.nix overrides flow through structurally —
# libgit2 is 1.9.4 today because the scope says so, and when the Nixpkgs
# pin catches up, the scope's versionAtLeast conditional flips both worlds
# in the same commit. Names the scope does not override fall back to the
# raw Nixpkgs attribute.
#
# The output is one derivation:
#   sources/<name>  — symlink to the dep's src (tarball or directory)
#   manifest.json   — { <name>: { version, source }, ... }
# The standalone build runs `nix build .#standalone-sources` once, and the
# dependency loop is nix-free from there (.github/deps/dep.sh). Individual
# sources stay addressable for spelunking:
#   nix build .#standalone-sources.sources.libgit2.src
#
# Deliberately absent from order.json (see DESIGN.md):
#   libiconv — both BOM copies; the build links /usr/lib/libiconv.dylib (§6.5)
#   c-ares, ncurses (BOM copy), publicsuffix-list, gettext, libedit,
#   libssh2, krb5, libxslt, libpsl — curl-slicing cuts (§6.3)
#   mercurial — not bundled; the fetcher is disabled with a sentinel (§7.3)
{
  lib,
  pkgs,
  nixDependencies,
}:

let
  names = builtins.fromJSON (builtins.readFile ../.github/deps/order.json);

  sources = lib.genAttrs names (
    name:
    let
      pkg = nixDependencies.${name} or pkgs.${name};
    in
    {
      # Some Linux bootstrap packages (libidn2) expose src only via .out;
      # irrelevant on Darwin, but it keeps the manifest buildable anywhere.
      src = pkg.src or pkg.out.src;
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
