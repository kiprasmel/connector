#!/usr/bin/env bash

# Vendor bats-core + helpers into test/vendor/ (git-ignored).
# Idempotent: clones missing trees and resets an existing clone to the pin.

set -euo pipefail

DIRNAME="$(cd "$(dirname "$0")" && pwd)"
VENDOR_DIR="$DIRNAME/vendor"

BATS_CORE_REF="v1.11.0"
BATS_SUPPORT_REF="v0.3.0"
BATS_ASSERT_REF="v2.1.0"

mkdir -p "$VENDOR_DIR"

clone_pinned() {
    local url="$1" ref="$2" dest="$3" head pin
    if [ -d "$dest/.git" ]; then
        head="$(git -C "$dest" rev-parse HEAD)"
        pin="$(git -C "$dest" rev-parse "$ref^{commit}" 2>/dev/null || true)"
        if [ -n "$pin" ] && [ "$head" = "$pin" ]; then
            echo "already vendored: $dest"
            return 0
        fi
        git -C "$dest" fetch --depth 1 origin "refs/tags/$ref:refs/tags/$ref"
        git -C "$dest" checkout -qf --detach "$ref"
        return 0
    fi
    git clone -q --depth 1 --branch "$ref" "$url" "$dest"
}

clone_pinned https://github.com/bats-core/bats-core.git    "$BATS_CORE_REF"    "$VENDOR_DIR/bats-core"
clone_pinned https://github.com/bats-core/bats-support.git "$BATS_SUPPORT_REF" "$VENDOR_DIR/bats-support"
clone_pinned https://github.com/bats-core/bats-assert.git  "$BATS_ASSERT_REF"  "$VENDOR_DIR/bats-assert"
