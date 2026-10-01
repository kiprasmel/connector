#!/usr/bin/env bats

# The manager link (~/.config/connector/cnc) is read as KEY=VALUE text and
# never sourced: four keys, each holding what it may, and anything else
# refused without running it; and connector never writes a link it would
# refuse.

load helpers

setup() {
    common_setup
    mkdir -p "$HOME/.config/connector"
    LINK="$HOME/.config/connector/cnc"
    stub ssh '[ "$1" != -G ] || printf "user admin\nhostname 203.0.113.1\n"'
}

# A link file of a good line each, then <line>.
link_with() {
    printf 'CNC_SSH="nyc"\nCNC_URL="https://hs.example.com"\nCNC_PORT=""\nCNC_USER="admin"\n%s\n' "$1" >"$LINK"
}

@test "a link connector writes is 0600 and reads back, quoted or bare, a comment and a CRLF aside" {
    run connector_fn save_cnc_link admin@nyc https://hs.example.com 2222
    assert_success
    [ -n "$(find "$LINK" -perm 600)" ]
    run connector_eval 'load_cnc_link; printf "%s|%s|%s|%s\n" "$CNC_SSH" "$CNC_URL" "$CNC_PORT" "$CNC_USER"'
    assert_output "admin@nyc|https://hs.example.com|2222|admin"
    printf '# linked by hand\r\nCNC_SSH=nyc\r\nCNC_URL=https://203.0.113.1:8443\r\n' >"$LINK"
    run connector_eval 'load_cnc_link; printf "%s|%s|%s\n" "$CNC_SSH" "$CNC_URL" "$CNC_USER"'
    assert_output "nyc|https://203.0.113.1:8443|admin"
}

@test "a link line that is code, another key, or a value its key cannot hold is refused, and nothing in it runs" {
    local line
    for line in \
        'CNC_SSH="$(touch ~/pwned)"' \
        'CNC_URL=`touch ~/pwned`' \
        'CNC_SSH=nyc; touch ~/pwned' \
        'CNC_SSH=$(touch ~/pwned)' \
        'touch ~/pwned' \
        'PATH="/tmp/evil"' \
        'export CNC_SSH=nyc' \
        'CNC_SSH="-oProxyCommand=touch"' \
        'CNC_SSH="nyc -oProxyCommand=touch"' \
        'CNC_PORT="22 -oProxyCommand=x"' \
        'CNC_USER="root; touch ~/pwned"' \
        'CNC_URL="https://hs.example.com/$(touch ~/pwned)"' \
        'CNC_SSH="nyc"x'
    do
        link_with "$line"
        run connector_fn load_cnc_link
        assert_failure
        assert_output --partial "refused"
    done
    [ ! -e "$HOME/pwned" ]
}

@test "a link that names no CNC is refused" {
    printf 'CNC_URL="https://hs.example.com"\n' >"$LINK"
    run connector_fn load_cnc_link
    assert_failure
    assert_output --partial "names no CNC"
}

@test "connector never writes a link it would refuse" {
    run connector_fn save_cnc_link "-oProxyCommand=touch ~/pwned" https://hs.example.com
    assert_failure
    assert_output --partial "is not an ssh target"
    run connector_fn save_cnc_link nyc 'https://hs.example.com/$(touch ~/pwned)'
    assert_failure
    assert_output --partial "is not a URL"
    run connector_fn save_cnc_link nyc https://hs.example.com "22; id"
    assert_failure
    assert_output --partial "is not a port"
    [ ! -e "$LINK" ]
    [ ! -e "$HOME/pwned" ]
}
