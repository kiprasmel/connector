# connector's test helpers: a sandbox HOME, a directory of stubs first on
# PATH (each logs its argv to $CALLS), and connector's functions loaded into
# a child shell without running its main.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CONNECTOR="$REPO_ROOT/connector"
load "vendor/bats-support/load"
load "vendor/bats-assert/load"

common_setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    unset XDG_CONFIG_HOME
    STUBS="$BATS_TEST_TMPDIR/stubs"
    CALLS="$BATS_TEST_TMPDIR/calls"
    mkdir -p "$STUBS"
    : >"$CALLS"
    export PATH="$STUBS:$PATH" STUBS CALLS CONNECTOR REPO_ROOT
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
