#!/usr/bin/env bash
# Fetch-or-build every dependency listed in order.txt (tier order) into
# $STAGING. Each line of order.txt is a dep name; blank lines and #-comments
# are ignored. See dep.sh for the skip semantics.
set -euo pipefail

deps_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

while read -r name; do
    case "$name" in "" | \#*) continue ;; esac
    "$deps_dir/dep.sh" "$name"
done < "$deps_dir/order.txt"
