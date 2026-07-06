#!/usr/bin/env bash
# Run the store-free nix test suites (DESIGN §10) with the environment the
# functional tests assume. Upstream runs them inside nix builds/devshells;
# on a bare runner the stdenv-isms must be supplied explicitly.
set -euo pipefail
: "${STAGING:?set STAGING to the absolute staging prefix}"
export PATH="$HOME/.nix-profile/bin:$STAGING/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
# stdenv-isms:
#   shell — stdenv exports the build shell; formatter.sh writes
#   #!  scripts (see its TODO_NixOS comment).
export shell="$STAGING/bin/bash"
#   _NIX_TEST_NO_SANDBOX — upstream sets this implicitly (vars.sh flips it
#   whenever NIX_STORE is set, which inside nix builds is always): the
#   functional suite is DESIGNED to run unsandboxed. Real sandbox_init
#   coverage on a bare runner is extra credit, tracked separately.
export _NIX_TEST_NO_SANDBOX=1
exec meson test -C build "$@"
