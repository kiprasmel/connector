#!/usr/bin/env bats

# A node follows the CNC to its new name: re-joined with a fresh key as the
# roles and the name it had, and the root an older connector installed for
# the old address taken away -- that certificate, by its fingerprint.

load helpers

setup() {
    common_setup
    # a Mac on the Tailscale app, logged in to the old bare-IP CNC as laptop2
    stub uname 'echo Darwin'
    stub Tailscale "$TS_STUB"
    export TS_PREFS='{"ControlURL":"https://203.0.113.1:8443","Hostname":"laptop2"}'
    mkdir -p "$HOME/.config/connector"
    echo consumer >"$HOME/.config/connector/role"
    make_cert 203.0.113.1 "$BATS_TEST_TMPDIR/old.pem"
    make_cert 198.51.100.7 "$BATS_TEST_TMPDIR/other.pem"
    cp "$BATS_TEST_TMPDIR/old.pem" "$HOME/.config/connector/cnc-ca.crt"
    cat "$BATS_TEST_TMPDIR/other.pem" "$BATS_TEST_TMPDIR/old.pem" >"$BATS_TEST_TMPDIR/keychain"
    export KEYCHAIN="$BATS_TEST_TMPDIR/keychain"
    stub security '[ "$1" != find-certificate ] || cat "$KEYCHAIN"'
}

# migrate-cnc on this Mac, the stub as its Tailscale app. Args: migrate-cnc's
migrate() {
    connector_eval "TS_MAC_APP_CLI=\"\$STUBS/Tailscale\" CONNECTOR_BIN=\"\$HOME/bin/connector\" CON_BIN=\"\$HOME/bin/con\"
        cmd_migrate_cnc $(printf '%q ' "$@")"
}

# This machine as a manager linked to the CNC <url> on ssh host nyc.
linked() {
    printf 'CNC_SSH="nyc"\nCNC_URL="%s"\nCNC_PORT=""\nCNC_USER="admin"\n' "$1" >"$HOME/.config/connector/cnc"
}

@test "a node re-joins at the CNC's new name as the roles and name it had, and stops trusting the old root" {
    run migrate https://hs.example.com --authkey hskey-m --tailscale app
    assert_success
    run calls_of Tailscale
    assert_line --regexp "^Tailscale up --reset --login-server https://hs\.example\.com --accept-dns=true --force-reauth --hostname laptop2 --auth-key file:"
    refute_output --partial hskey-m
    run cat "$KEY_SEEN"
    assert_output hskey-m
    run calls_of security
    assert_line "security delete-certificate -Z $(cert_sha1 "$BATS_TEST_TMPDIR/old.pem") /Library/Keychains/System.keychain"
    refute_line --partial "$(cert_sha1 "$BATS_TEST_TMPDIR/other.pem")"
    [ ! -e "$HOME/.config/connector/cnc-ca.crt" ]
    run cat "$HOME/.config/connector/role"
    assert_output consumer
}

@test "a fingerprint that is not the certificate this node trusted stops it before anything changes" {
    run migrate https://hs.example.com --authkey hskey-m --old-sha256 "$(cert_sha256 "$BATS_TEST_TMPDIR/other.pem")" --tailscale app
    assert_failure
    assert_output --partial "is not the one named"
    [ -z "$(calls_of Tailscale)" ]
    [ -z "$(calls_of security)" ]
    [ -e "$HOME/.config/connector/cnc-ca.crt" ]
}

@test "a node already at the new name is not re-joined, and the old root still goes" {
    export TS_PREFS='{"ControlURL":"https://hs.example.com","Hostname":"laptop2"}'
    run migrate https://hs.example.com --tailscale app
    assert_success
    assert_output --partial "Already on https://hs.example.com"
    run calls_of Tailscale
    refute_line --partial " up "
    run calls_of security
    assert_line "security delete-certificate -Z $(cert_sha1 "$BATS_TEST_TMPDIR/old.pem") /Library/Keychains/System.keychain"
}

@test "a node that has to re-join needs a fresh key, and one never registered is told to register" {
    run migrate https://hs.example.com --tailscale app
    assert_failure
    assert_output --partial "needs a fresh key"
    rm "$HOME/.config/connector/role"
    run migrate https://hs.example.com --authkey hskey-m --tailscale app
    assert_failure
    assert_output --partial "never registered with connector"
}

@test "a manager follows the CNC to its new name, its ssh side as it was" {
    linked https://203.0.113.1:8443
    run migrate https://hs.example.com --authkey hskey-m --tailscale app
    assert_success
    assert_output --partial "The manager link now names https://hs.example.com"
    run cat "$HOME/.config/connector/cnc"
    assert_output "$(printf 'CNC_SSH="nyc"\nCNC_URL="https://hs.example.com"\nCNC_PORT=""\nCNC_USER="admin"')"
    [ -n "$(find "$HOME/.config/connector/cnc" -perm 600)" ]
    # a link without a URL gets one; and never one load_cnc_link would refuse
    printf 'CNC_SSH="nyc"\n' >"$HOME/.config/connector/cnc"
    run connector_fn set_cnc_link_url https://hs2.example.com
    assert_success
    run connector_eval 'load_cnc_link; echo "$CNC_URL"'
    assert_output https://hs2.example.com
    run connector_fn set_cnc_link_url 'https://hs.example.com/$(id)'
    assert_failure
    run connector_eval 'load_cnc_link; echo "$CNC_URL"'
    assert_output https://hs2.example.com
}

@test "invite --migrate prints the command a node follows the CNC with, naming the old root" {
    linked https://hs.example.com
    export OLD_PEM="$BATS_TEST_TMPDIR/old.pem"
    stub ssh 'case "$*" in
        *"users list"*) echo "[{\"id\":1,\"name\":\"mesh\"}]" ;;
        *"preauthkeys create"*) echo "{\"key\":\"hskey-fresh\"}" ;;
        *"cat /var/lib/headscale/certs/cnc.crt"*) cat "$OLD_PEM" ;;
    esac'
    run connector_fn cmd_invite --migrate consumer
    assert_success
    assert_output --partial "connector migrate-cnc https://hs.example.com --authkey hskey-fresh --old-sha256 $(cert_sha256 "$BATS_TEST_TMPDIR/old.pem")"
    run calls_of ssh
    assert_line --partial "preauthkeys create --user 1 --expiration 1h --output json --tags tag:consumer"
}

@test "invite --migrate on a CNC that holds no old certificate prints the command, naming no root" {
    # a CNC that moves from one name to another: no older connector's root on it
    linked https://hs.example.com
    stub ssh 'case "$*" in
        *"users list"*) echo "[{\"id\":1,\"name\":\"mesh\"}]" ;;
        *"preauthkeys create"*) echo "{\"key\":\"hskey-fresh\"}" ;;
        *"cat /var/lib/headscale/certs/cnc.crt"*) echo "cat: /var/lib/headscale/certs/cnc.crt: No such file or directory" >&2; exit 1 ;;
    esac'
    run connector_fn cmd_invite --migrate consumer
    assert_success
    assert_output --partial "connector migrate-cnc https://hs.example.com --authkey hskey-fresh"
    refute_output --partial "--old-sha256"
}
