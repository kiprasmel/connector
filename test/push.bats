#!/usr/bin/env bats

# connector reaching another machine (cnc-init, cnc-update, propagate-update)
# copies itself into a directory of its own there -- mktemp -d, made by the
# far side -- installs from it, and removes it in the same command: never a
# fixed name in /tmp that anyone on that host could make first or swap.

load helpers

setup() {
    common_setup
    mkdir -p "$HOME/far"
    export FAR_DIRS="$BATS_TEST_TMPDIR/far-dirs"
    # ssh runs what it is asked right here, standing in for the far side; a
    # FAR_DIR answers mktemp instead. scp copies to the path after the colon.
    stub ssh '
        for a in "$@"; do last="$a"; done
        if [ "$last" = "mktemp -d /tmp/connector.XXXXXXXXXX" ]; then
            if [ -n "${FAR_DIR:-}" ]; then echo "$FAR_DIR"; exit 0; fi
            d="$(mktemp -d /tmp/connector.XXXXXXXXXX)" && echo "$d" >>"$FAR_DIRS" && echo "$d"
            exit
        fi
        exec bash -c "$last"'
    stub scp 'for a in "$@"; do src="${dst:-}"; dst="$a"; done
        [ "${SCP_FAIL:-0}" = 0 ] || exit 1
        cp "$src" "${dst#*:}"'
}

teardown() {
    local d
    while IFS= read -r d; do rm -rf "$d"; done <"$FAR_DIRS" 2>/dev/null || true
}

# push_connector, with the far side's install under $HOME/far. Args: push_connector's
push() {
    connector_eval "CONNECTOR_BIN=\"\$HOME/far/connector\" CON_BIN=\"\$HOME/far/con\"
        push_connector $(printf '%q ' "$@")"
}

# The directory the far side made, from scp's call.
far_dir() {
    calls_of scp | sed -n 's#.*:\(/tmp/connector\.[A-Za-z0-9]*\)/connector$#\1#p'
}

@test "connector goes into a directory of its own on the far side, is installed from it, and the directory goes" {
    run push nyc "" 0 2222
    assert_success
    cmp "$HOME/far/connector" "$CONNECTOR"
    [ -n "$(find "$HOME/far/connector" -perm 755)" ]
    [ "$(readlink "$HOME/far/con")" = "$HOME/far/connector" ]
    run calls_of scp
    assert_output --regexp "^scp -q -o ConnectTimeout=10 -P 2222 .*/connector nyc:/tmp/connector\.[A-Za-z0-9]{10}/connector$"
    run calls_of ssh
    assert_line --index 0 'ssh -o ConnectTimeout=10 -p 2222 nyc mktemp\ -d\ /tmp/connector.XXXXXXXXXX'
    [ -n "$(far_dir)" ]
    [ ! -e "$(far_dir)" ]
}

@test "a far side that names any other directory gets nothing" {
    local d
    for d in "/tmp/connector.\$(touch $HOME/pwned)" "/tmp/x; touch $HOME/pwned" "/tmp/connector" " "; do
        FAR_DIR="$d" run push nyc "" 0
        assert_failure
        assert_output --partial "made no directory of its own"
    done
    [ -z "$(calls_of scp)" ]
    [ ! -e "$HOME/pwned" ]
    [ ! -e "$HOME/far/connector" ]
}

@test "a copy that fails, or an install that fails, takes the directory with it" {
    SCP_FAIL=1 run push nyc "" 0
    assert_failure
    assert_output --partial "copy to nyc failed"
    run calls_of ssh
    assert_line --regexp "^ssh -o ConnectTimeout=10 nyc rm\\\\ -rf\\\\ /tmp/connector\.[A-Za-z0-9]{10}$"
    while IFS= read -r d; do [ ! -e "$d" ]; done <"$FAR_DIRS"
    # the install fails (no such directory to install into): it says so, and the directory goes
    : >"$CALLS"
    run connector_eval 'CONNECTOR_BIN="$HOME/nowhere/connector" CON_BIN="$HOME/nowhere/con"; push_connector nyc "" 0'
    assert_failure
    [ -n "$(far_dir)" ]
    [ ! -e "$(far_dir)" ]
}

@test "cnc-update and propagate-update go through it, and no fixed name in /tmp is left in connector" {
    run grep -c 'connector\.\$\$' "$CONNECTOR"
    assert_output 0
    mkdir -p "$HOME/.config/connector"
    printf 'CNC_SSH="nyc"\nCNC_URL="https://hs.example.com"\nCNC_PORT=""\nCNC_USER="root"\n' >"$HOME/.config/connector/cnc"
    run connector_eval 'CONNECTOR_BIN="$HOME/far/connector" CON_BIN="$HOME/far/con"; cnc_update_push'
    assert_success
    assert_output --partial "updated + verified"
    run calls_of scp
    assert_output --regexp "nyc:/tmp/connector\.[A-Za-z0-9]{10}/connector$"
    # a provider: sudo there may ask for a password, so its install keeps a terminal
    : >"$CALLS"
    run connector_eval 'CONNECTOR_BIN="$HOME/far/connector" CON_BIN="$HOME/far/con"; sudo() { "$@"; }; provider_update_push box1'
    run calls_of ssh
    assert_line --regexp "^ssh -t -o ConnectTimeout=10 .*@box1 sudo\\\\ install\\\\ -m\\\\ 0755\\\\ /tmp/connector\."
}
