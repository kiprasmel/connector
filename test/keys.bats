#!/usr/bin/env bats

# Keys: an operator's machine is untagged, the ops user's; and a key reaches
# tailscale in a file, never on its argv.

load helpers

setup() {
    common_setup
    mkdir -p "$HOME/.config/connector"
    printf 'CNC_SSH="nyc"\nCNC_URL="https://hs.example.com"\nCNC_PORT=""\nCNC_USER="admin"\n' >"$HOME/.config/connector/cnc"
    # the CNC over ssh: users mesh (1) and ops (2), and a key per create
    stub ssh 'case "$*" in
        *"users list"*) echo "[{\"id\":1,\"name\":\"mesh\"},{\"id\":2,\"name\":\"ops\"}]" ;;
        *"preauthkeys create"*) echo "{\"key\":\"hskey-node\"}" ;;
    esac'
}

@test "an operator's machine is the ops user's, untagged, and nothing beside" {
    run connector_fn cmd_invite ops laptop
    assert_success
    assert_output --partial "connector register ops https://hs.example.com --authkey hskey-node --hostname laptop"
    run calls_of ssh
    assert_line --regexp "preauthkeys create --user 2 --expiration 1h --output json$"
    refute_output --partial -- "--tags"
    run connector_fn parse_node_roles ops,consumer
    assert_failure
    assert_output --partial "not with provider or consumer"
}

@test "a key reaches tailscale in a file, never on its argv, and may come on stdin" {
    stub uname 'echo Linux'
    stub tailscale "$TS_STUB"
    run connector_eval 'CONNECTOR_BIN="$HOME/bin/connector" CON_BIN="$HOME/bin/con"
        cmd_register consumer https://hs.example.com --authkey hskey-argv --yes'
    assert_success
    run calls_of tailscale
    assert_line --regexp "^tailscale up .* --auth-key file:"
    refute_output --partial hskey-argv
    run cat "$KEY_SEEN"
    assert_output hskey-argv
    # the file goes with the run
    run bash -c 'grep -o "file:[^ ]*" "$CALLS" | head -n 1 | cut -d: -f2'
    [ ! -e "$output" ]
    run connector_eval 'CONNECTOR_BIN="$HOME/bin/connector" CON_BIN="$HOME/bin/con"
        cmd_register consumer https://hs.example.com --authkey - --yes' <<<"hskey-stdin"
    assert_success
    run cat "$KEY_SEEN"
    assert_output hskey-stdin
}
