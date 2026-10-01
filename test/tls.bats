#!/usr/bin/env bats

# The CNC is a DNS name with a Let's Encrypt certificate headscale gets and
# renews itself: what cnc-init renders and refuses, that no machine is made
# to trust a root of connector's, and that the one an older connector
# installed goes -- by its fingerprint, and nothing beside it.

load helpers

setup() {
    common_setup
    stub update-ca-certificates
    stub update-ca-trust
    stub systemctl
}

# This machine as a manager linked to the CNC <url> on ssh host nyc.
linked() {
    mkdir -p "$HOME/.config/connector"
    printf 'CNC_SSH="nyc"\nCNC_URL="%s"\nCNC_PORT=""\nCNC_USER="admin"\n' "$1" >"$HOME/.config/connector/cnc"
}

@test "the CNC is https and a DNS name: an address, a path or a bare word is refused" {
    run connector_fn cnc_url_ok https://hs.example.com
    assert_success
    run connector_fn cnc_url_ok https://hs.example.com:8443/
    assert_success
    run connector_fn cnc_url_ok https://203.0.113.1:8443
    assert_failure
    assert_output --partial "a DNS name, not an address (203.0.113.1)"
    run connector_fn cnc_url_ok http://hs.example.com
    assert_failure
    run connector_fn cnc_url_ok https://hs.example.com/x
    assert_failure
    run connector_fn cnc_url_ok "https://hs.example.com';id;'"
    assert_failure
    run connector_fn cnc_url_ok https://localhost
    assert_failure
    run connector_fn cnc_url_ok https://hs.example.com:44x
    assert_failure
}

@test "headscale is told the CNC's name for Let's Encrypt; the challenge decides where it listens" {
    run connector_fn render_headscale_config https://hs.example.com connector.mesh tls-alpn-01
    assert_success
    assert_line "server_url: https://hs.example.com"
    assert_line "listen_addr: 0.0.0.0:443"
    assert_line 'tls_letsencrypt_hostname: "hs.example.com"'
    assert_line "tls_letsencrypt_challenge_type: TLS-ALPN-01"
    refute_output --partial "tls_cert_path"
    refute_output --partial "tls_letsencrypt_listen"
    run connector_fn render_headscale_config https://hs.example.com:8443 connector.mesh http-01
    assert_success
    assert_line "listen_addr: 0.0.0.0:8443"
    assert_line "tls_letsencrypt_challenge_type: HTTP-01"
    assert_line 'tls_letsencrypt_listen: ":http"'
    run connector_fn render_headscale_config https://hs.example.com connector.mesh dns-01
    assert_failure
}

@test "cnc-init answers tls-alpn-01 on :443 alone, and never binds over what else holds a port" {
    # as root, on a host where nginx holds :443
    stub ss 'case "$*" in *":443"*) echo "LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:((\"nginx\",pid=7,fd=6))" ;; esac'
    run connector_eval 'id() { echo 0; }; cnc_init_local https://hs.example.com:8443 "" tls-alpn-01'
    assert_failure
    assert_output --partial "tls-alpn-01 is answered on :443"
    run connector_eval 'id() { echo 0; }; cnc_init_local https://hs.example.com "" tls-alpn-01'
    assert_failure
    assert_output --partial "Something else listens on :443 here"
    assert_output --partial "nginx"
    run connector_eval 'id() { echo 0; }; cnc_init_local https://203.0.113.1:8443 "" tls-alpn-01'
    assert_failure
    assert_output --partial "Not a URL the CNC can be"
    # nothing installed, nothing started
    [ -z "$(calls_of systemctl)" ]
    [ -z "$(calls_of curl)" ]
}

@test "register joins a name, and no machine is made to trust a root of connector's" {
    stub uname 'echo Linux'
    stub tailscale 'exit 0'
    run connector_eval 'CONNECTOR_BIN="$HOME/bin/connector" CON_BIN="$HOME/bin/con"
        cmd_register consumer https://hs.example.com --authkey hskey-test --hostname n1 --yes'
    assert_success
    run calls_of tailscale
    assert_line --partial "tailscale up --reset --login-server https://hs.example.com"
    refute_output --partial hskey-test
    [ -z "$(calls_of security)" ]
    [ -z "$(calls_of update-ca-certificates)" ]
    [ ! -e "$HOME/.config/connector/cnc-ca.crt" ]
}

@test "register refuses a bare-IP CNC, and a pin" {
    stub uname 'echo Linux'
    run connector_fn cmd_register consumer https://203.0.113.1:8443 --authkey k
    assert_failure
    assert_output --partial "a DNS name, not an address"
    run connector_fn cmd_register consumer https://hs.example.com --authkey k --ca-sha256 ab12
    assert_failure
    assert_output --partial "--ca-sha256 is gone"
    [ -z "$(calls_of tailscale)" ]
}

@test "an invite carries no pin: the CNC's certificate is a public one" {
    linked https://hs.example.com
    stub ssh 'case "$*" in
        *"users list"*) echo "[{\"id\":1,\"name\":\"mesh\"}]" ;;
        *"preauthkeys create"*) echo "{\"key\":\"hskey-fresh\"}" ;;
    esac'
    run connector_fn cmd_invite consumer laptop2
    assert_success
    assert_output --partial "connector register consumer https://hs.example.com --authkey hskey-fresh --hostname laptop2"
    refute_output --partial "ca-sha256"
}

@test "a Mac stops trusting an older connector's root by its fingerprint, and nothing beside it" {
    make_cert 203.0.113.1 "$BATS_TEST_TMPDIR/old.pem"
    make_cert 198.51.100.7 "$BATS_TEST_TMPDIR/other.pem"
    cat "$BATS_TEST_TMPDIR/other.pem" "$BATS_TEST_TMPDIR/old.pem" >"$BATS_TEST_TMPDIR/keychain"
    export KEYCHAIN="$BATS_TEST_TMPDIR/keychain" UNTRUSTED="$BATS_TEST_TMPDIR/untrusted.pem"
    stub uname 'echo Darwin'
    stub security 'case "$1" in
        find-certificate) cat "$KEYCHAIN" ;;
        remove-trusted-cert) cp "$3" "$UNTRUSTED" ;;
    esac'
    run connector_fn untrust_cert_sha256 "$(cert_sha256 "$BATS_TEST_TMPDIR/old.pem")"
    assert_success
    run calls_of security
    assert_line "security find-certificate -a -p /Library/Keychains/System.keychain"
    assert_line "security delete-certificate -Z $(cert_sha1 "$BATS_TEST_TMPDIR/old.pem") /Library/Keychains/System.keychain"
    refute_line --partial "$(cert_sha1 "$BATS_TEST_TMPDIR/other.pem")"
    # its trust setting went with it: that certificate's
    cmp "$UNTRUSTED" "$BATS_TEST_TMPDIR/old.pem"
    # gone already: nothing to remove, and nothing removed
    cp "$BATS_TEST_TMPDIR/other.pem" "$KEYCHAIN"
    : >"$CALLS"
    run connector_fn untrust_cert_sha256 "$(cert_sha256 "$BATS_TEST_TMPDIR/old.pem")"
    assert_success
    assert_output --partial "nothing to remove"
    run calls_of security
    assert_output "security find-certificate -a -p /Library/Keychains/System.keychain"
    run connector_fn untrust_cert_sha256 203.0.113.1
    assert_failure
    assert_output --partial "is not a SHA-256 fingerprint"
}

@test "cleanup on a Mac takes away the trust root an older connector left, by its fingerprint" {
    make_cert 203.0.113.1 "$BATS_TEST_TMPDIR/old.pem"
    make_cert 198.51.100.7 "$BATS_TEST_TMPDIR/other.pem"
    cat "$BATS_TEST_TMPDIR/old.pem" "$BATS_TEST_TMPDIR/other.pem" >"$BATS_TEST_TMPDIR/keychain"
    mkdir -p "$HOME/.config/connector"
    cp "$BATS_TEST_TMPDIR/old.pem" "$HOME/.config/connector/cnc-ca.crt"
    export KEYCHAIN="$BATS_TEST_TMPDIR/keychain"
    stub uname 'echo Darwin'
    stub tailscale 'exit 0'
    stub security '[ "$1" != find-certificate ] || cat "$KEYCHAIN"'
    ASSUME_YES=1 run connector_fn cmd_cleanup
    assert_success
    run calls_of security
    assert_line "security delete-certificate -Z $(cert_sha1 "$BATS_TEST_TMPDIR/old.pem") /Library/Keychains/System.keychain"
    refute_line --partial "$(cert_sha1 "$BATS_TEST_TMPDIR/other.pem")"
    [ ! -e "$HOME/.config/connector/cnc-ca.crt" ]
}

@test "a manager links to a name, never an address" {
    stub ssh '[ "$1" != -G ] || printf "user admin\nhostname 203.0.113.1\n"'
    run connector_fn cmd_link nyc --url https://203.0.113.1:8443
    assert_failure
    assert_output --partial "a DNS name, not an address"
    [ ! -e "$HOME/.config/connector/cnc" ]
    run connector_fn cmd_link nyc --url https://hs.example.com
    assert_success
    run cat "$HOME/.config/connector/cnc"
    assert_line 'CNC_URL="https://hs.example.com"'
}
