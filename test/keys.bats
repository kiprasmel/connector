#!/usr/bin/env bats

# Keys: a prod machine's comes from prod-key alone -- single-use, tag:prod
# and nothing else, an hour at most, out only to stdout or a new 0600 file --
# and invite and approve refuse prod; an operator's machine is untagged, the
# ops user's; and a key reaches tailscale in a file, never on its argv.

load helpers
bats_require_minimum_version 1.5.0

setup() {
    common_setup
    mkdir -p "$HOME/.config/connector"
    printf 'CNC_SSH="nyc"\nCNC_URL="https://hs.example.com"\nCNC_PORT=""\nCNC_USER="admin"\n' >"$HOME/.config/connector/cnc"
    # the CNC over ssh: users mesh (1) and ops (2), and a key per create
    stub ssh 'case "$*" in
        *"users list"*) echo "[{\"id\":1,\"name\":\"mesh\"},{\"id\":2,\"name\":\"ops\"}]" ;;
        *"preauthkeys create"*"tag:prod"*) echo "{\"key\":\"hskey-prod\"}" ;;
        *"preauthkeys create"*) echo "{\"key\":\"hskey-node\"}" ;;
    esac'
}

@test "invite and approve refuse a prod machine: its key comes from prod-key alone" {
    local args
    for args in "prod" "tag:prod" "consumer tag:prod" "consumer --tags=tag:prod"; do
        # shellcheck disable=SC2086  # each its own words
        run connector_fn cmd_invite $args
        assert_failure
        assert_output --partial "its key comes from 'connector prod-key' alone"
    done
    run connector_fn parse_node_roles provider,prod
    assert_failure
    assert_output --partial "'connector prod-key' alone"
    run connector_fn cmd_approve 7 tag:prod
    assert_failure
    assert_output --partial "'connector prod-key' alone"
    run calls_of ssh
    refute_output --partial "preauthkeys create"
    refute_output --partial "approve-routes"
    refute_output --partial "nodes tag"
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
    # approve tags, and an operator's machine has none: it is never approved into ops
    : >"$CALLS"
    run connector_fn cmd_approve 7 ops
    assert_failure
    assert_output --partial "it joins with a key from 'connector invite ops'"
    run calls_of ssh
    refute_output --partial "approve-routes"
    refute_output --partial "nodes tag"
}

@test "a prod key is tag:prod alone, single-use, the operators', and stdout carries the key and nothing else" {
    run --separate-stderr connector_fn cmd_prod_key --yes
    assert_success
    assert_output "hskey-prod"
    run calls_of ssh
    assert_line --regexp "sudo headscale preauthkeys create --user 2 --tags tag:prod --expiration 1h --output json$"
    refute_output --partial "--reusable"
}

@test "a prod key lives an hour at most, is minted by an admin only, and only when asked for" {
    run connector_fn cmd_prod_key --expiration 2h --yes
    assert_failure
    assert_output --partial "lives an hour at most"
    run connector_fn cmd_prod_key --expiration 30m --yes
    assert_success
    # not confirmed: nothing minted
    : >"$CALLS"
    run connector_fn cmd_prod_key </dev/null
    assert_failure
    assert_output --partial "Declined"
    [ -z "$(calls_of ssh)" ]
    rm "$HOME/.config/connector/cnc"
    run connector_fn cmd_prod_key --yes
    assert_failure
    assert_output --partial "Only a CNC or manager mints a prod key"
}

@test "a prod key goes into a new 0600 file, never over one" {
    run connector_fn cmd_prod_key --out "$BATS_TEST_TMPDIR/k" --yes
    assert_success
    run cat "$BATS_TEST_TMPDIR/k"
    assert_output "hskey-prod"
    [ -n "$(find "$BATS_TEST_TMPDIR/k" -perm 600)" ]
    run connector_fn cmd_prod_key --out "$BATS_TEST_TMPDIR/k" --yes
    assert_failure
    assert_output --partial "goes into a new file only"
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
