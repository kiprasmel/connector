#!/usr/bin/env bash

# Run connector's bats suite. Arguments go to bats (files, -f <name>, ...);
# none runs every test/*.bats.
#
# The docker tier (bats file_tags=tier:docker) runs connector as root in a
# pinned ubuntu container and headscale from its pinned image: what a CNC
# and a Linux node really do, with nothing on this machine touched.
# CONNECTOR_TEST_DOCKER=0 skips it.

set -euo pipefail

DIRNAME="$(cd "$(dirname "$0")" && pwd)"
BATS="$DIRNAME/vendor/bats-core/bin/bats"
[ -x "$BATS" ] || { echo "err: bats not vendored; run ./test/setup.sh" >&2; exit 1; }

if [ $# -eq 0 ]; then
    set -- "$DIRNAME"
fi
exec "$BATS" "$@"
