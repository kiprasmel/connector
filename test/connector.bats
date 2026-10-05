#!/usr/bin/env bats

# connector as a library: sourcing it defines everything and runs nothing;
# and the parsers every command leans on.

load helpers

setup() { common_setup; }

@test "sourcing connector runs nothing; running it does" {
    run bash -c 'source "$CONNECTOR"; echo sourced'
    assert_success
    assert_output "sourced"
    run "$CONNECTOR" help
    assert_success
    assert_output --partial "connector v"
}

@test "roles parse to one canonical list, and an unknown one is refused" {
    run connector_fn parse_node_roles "consumer,provider"
    assert_output "provider,consumer"
    run connector_fn parse_node_roles "both"
    assert_output "provider,consumer"
    run connector_fn parse_node_roles "admin"
    assert_failure
    assert_output --partial "Invalid role: 'admin'"
}

@test "a url's host and port, for a name, an IPv4 and an IPv6" {
    run connector_fn url_host "https://hs.example.com:8443/x"
    assert_output "hs.example.com"
    run connector_fn url_port "https://hs.example.com:8443/x"
    assert_output "8443"
    run connector_fn url_host "https://[2001:db8::1]:443"
    assert_output "2001:db8::1"
    run connector_fn is_ip 203.0.113.1
    assert_success
    run connector_fn is_ip hs.example.com
    assert_failure
}

@test "an ops machine has no tags, and its empty list expands on a bash before 4.4 too" {
    run connector_fn tags_for_roles ops
    assert_success
    assert_output ""
    run connector_fn tags_for_roles provider,consumer
    assert_output "tag:provider,tag:consumer"
    # macOS's /bin/bash is 3.2: an empty array is unbound under set -u there
    if [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}${BASH_VERSINFO[1]}" -lt 44 ]'; then
        # shellcheck disable=SC2016  # expands in the child
        run /bin/bash -c 'source "$CONNECTOR"; tags_for_roles ops'
        assert_success
        assert_output ""
    fi
}

@test "register leaves a connector already on PATH as itself, and installs one that is not" {
    local sys="$BATS_TEST_TMPDIR/sys" user="$BATS_TEST_TMPDIR/user"
    mkdir -p "$sys" "$user"
    ln -s "$CONNECTOR" "$user/connector"
    # a checkout's symlink first on PATH: a copy would shadow it
    # shellcheck disable=SC2016  # expands in the child
    run env PATH="$user:$PATH" bash -c 'source "$CONNECTOR"; CONNECTOR_BIN="$1/connector" CON_BIN="$1/con"; install_self_local' _ "$sys"
    assert_success
    assert_output --partial "'connector' on PATH is this one ($user/connector)"
    [ ! -e "$sys/connector" ]
    # none on PATH (a machine that ran it from a download): installed, with con
    # shellcheck disable=SC2016  # expands in the child
    run env PATH="$STUBS:/usr/bin:/bin" bash -c 'source "$CONNECTOR"; CONNECTOR_BIN="$1/connector" CON_BIN="$1/con"; install_self_local' _ "$sys"
    assert_success
    assert_output --partial "Installed 'connector' + 'con'"
    cmp -s "$CONNECTOR" "$sys/connector"
    [ "$(readlink "$sys/con")" = "$sys/connector" ]
}
