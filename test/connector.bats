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
