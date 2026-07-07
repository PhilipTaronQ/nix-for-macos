#!/usr/bin/env bash
# bzip2 (libbz2), static. Run from the unpacked source root; STAGING set.
# Source: nixpkgs pin, bzip2.src. No configure, no .pc file upstream; the
# install target builds lib + tools without running the test suite.
set -euo pipefail
make -j"$(sysctl -n hw.ncpu)" install PREFIX="$STAGING" CC=cc
