# connector's test helpers: a sandbox HOME, a directory of stubs first on
# PATH (each logs its argv to $CALLS), and connector's functions loaded into
# a child shell without running its main.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CONNECTOR="$REPO_ROOT/connector"
load "vendor/bats-support/load"
load "vendor/bats-assert/load"

common_setup() {
    # docker keeps reading its context from the real home, which HOME stops being
    export DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    unset XDG_CONFIG_HOME
    STUBS="$BATS_TEST_TMPDIR/stubs"
    CALLS="$BATS_TEST_TMPDIR/calls"
    mkdir -p "$STUBS"
    : >"$CALLS"
    KEY_SEEN="$BATS_TEST_TMPDIR/key-seen"
    export PATH="$STUBS:$PATH" STUBS CALLS CONNECTOR REPO_ROOT KEY_SEEN
    # sudo runs what it is given, as us, and says so; nothing reaches this
    # machine's own tailscale, headscale or keychain
    stub sudo 'exec "$@"'
    stub tailscale 'exit 1'
    stub headscale 'exit 1'
    stub security 'exit 1'
}

# A stub for <cmd>: logs its argv (%q-quoted, one line) to $CALLS, then runs
# <body> with the same arguments. Args: cmd, [body]
stub() {
    local cmd="$1" body="${2:-exit 0}"
    cat >"$STUBS/$cmd" <<STUB
#!/usr/bin/env bash
{ printf '%s' "$cmd"; for a in "\$@"; do printf ' %q' "\$a"; done; printf '\n'; } >>"$CALLS"
$body
STUB
    chmod +x "$STUBS/$cmd"
}

# A tailscale stub's body: `debug prefs` answers $TS_PREFS, and the key an
# `up` was handed in a file (--auth-key file:...) is kept in $KEY_SEEN.
TS_STUB='prev=""; for a in "$@"; do [ "$prev" != --auth-key ] || cat "${a#file:}" >"$KEY_SEEN"; prev="$a"; done; [ "$1" != debug ] || printf "%s\n" "${TS_PREFS:-{\}}"'

# The calls a stub saw, one per line. Args: cmd
calls_of() {
    grep -E "^$1( |\$)" "$CALLS" || true
}

# connector's <fn> [args], everything defined and main not run.
connector_fn() {
    # shellcheck disable=SC2016  # expands in the child
    bash -c 'source "$CONNECTOR"; "$@"' _ "$@"
}

# connector's functions loaded, then <script> evaluated (to set a constant
# first, say). Args: script
connector_eval() {
    # shellcheck disable=SC2016  # expands in the child
    bash -c 'source "$CONNECTOR"; eval "$1"' _ "$1"
}

# The docker tier is skipped where docker is not running, or when asked.
require_docker() {
    [ "${CONNECTOR_TEST_DOCKER:-1}" != 0 ] || skip "CONNECTOR_TEST_DOCKER=0"
    docker info >/dev/null 2>&1 || skip "docker is not running"
}

# What the docker tier runs, pinned by digest and never pulled as a moving
# tag: headscale at the release connector pins (a test holds the two
# together), and ubuntu, the CNC's and a node's distro.
HEADSCALE_IMAGE="headscale/headscale:0.29.4@sha256:8833f828b414c0907b7e5c71da76473216fe17cce0818a166b536ec552c0903f"
UBUNTU_IMAGE="ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3"

# The Linux machine connector runs on as root (test/docker/Dockerfile), built
# once per content of its Dockerfile. Stdout: its tag.
node_image() {
    local df="$REPO_ROOT/test/docker/Dockerfile" sum tag
    sum="$( { sha256sum 2>/dev/null || shasum -a 256; } <"$df" | cut -c1-12)"
    tag="connector-test-node:$sum"
    docker image inspect "$tag" >/dev/null 2>&1 \
        || docker build -q --build-arg BASE="$UBUNTU_IMAGE" -t "$tag" "$REPO_ROOT/test/docker" >/dev/null \
        || return 1
    printf '%s\n' "$tag"
}

# An image with systemd in it, for systemd-analyze (test/docker/systemd),
# built once per content of its Dockerfile. Stdout: its tag.
systemd_image() {
    local df="$REPO_ROOT/test/docker/systemd/Dockerfile" sum tag
    sum="$( { sha256sum 2>/dev/null || shasum -a 256; } <"$df" | cut -c1-12)"
    tag="connector-test-systemd:$sum"
    docker image inspect "$tag" >/dev/null 2>&1 \
        || docker build -q --build-arg BASE="$UBUNTU_IMAGE" -t "$tag" "$REPO_ROOT/test/docker/systemd" >/dev/null \
        || return 1
    printf '%s\n' "$tag"
}

# Run <script> as root in a fresh node container, connector at
# /usr/local/bin/connector and its functions loaded. Extra docker run
# arguments before the script. Args: [docker args...] script
in_node() {
    local script="${!#}" img
    img="$(node_image)" || return 1
    docker run --rm -i -v "$CONNECTOR:/usr/local/bin/connector:ro" "${@:1:$#-1}" "$img" \
        bash -c 'set -euo pipefail; source /usr/local/bin/connector; set +e; eval "$1"' _ "$script"
}

# A self-signed CA:TRUE certificate for an address, as an older connector made
# for a bare-IP CNC. Args: ip, file
make_cert() {
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 30 \
        -subj "/CN=$1" -addext "subjectAltName=IP:$1" -keyout "$2.key" -out "$2" >/dev/null 2>&1
}

# A certificate file's SHA-256 (lowercase, no colons) and SHA-1 (uppercase).
cert_sha256() { openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f'; }
cert_sha1() { openssl x509 -in "$1" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F'; }

# headscale's own binary, from the pinned image, once per run. Stdout: its path.
headscale_bin() {
    local out="$BATS_RUN_TMPDIR/headscale" c
    if [ ! -x "$out" ]; then
        c="$(docker create "$HEADSCALE_IMAGE")" || return 1
        docker cp "$c:/ko-app/headscale" "$out" >/dev/null || { docker rm "$c" >/dev/null; return 1; }
        docker rm "$c" >/dev/null
    fi
    printf '%s\n' "$out"
}
