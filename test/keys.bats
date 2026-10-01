#!/usr/bin/env bats

# Keys: one reaches tailscale in a file, never on its argv.

load helpers

setup() {
    common_setup
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
