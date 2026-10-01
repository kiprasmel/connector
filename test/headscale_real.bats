#!/usr/bin/env bats

# What connector renders, read by the programs that act on it: headscale's
# configtest on the pinned release, and a Linux node's CA store -- rebuilt by
# its own tools -- when an older connector's CNC certificate goes.

# bats file_tags=tier:docker

load helpers

setup() {
    common_setup
    require_docker
}

# headscale's configtest, on /etc/headscale <etc> and /var/lib/headscale <lib>.
configtest() {
    docker run --rm -v "$1:/etc/headscale:ro" -v "$2:/var/lib/headscale" "$HEADSCALE_IMAGE" configtest
}

@test "headscale takes the config connector renders, for either challenge, and refuses a broken one" {
    local ch etc lib url
    for ch in tls-alpn-01 http-01; do
        etc="$BATS_TEST_TMPDIR/$ch/etc" lib="$BATS_TEST_TMPDIR/$ch/lib" url=https://hs.example.com
        [ "$ch" = tls-alpn-01 ] || url=https://hs.example.com:8443
        mkdir -p "$etc" "$lib"
        connector_fn render_headscale_config "$url" connector.mesh "$ch" >"$etc/config.yaml"
        connector_fn render_acl >"$etc/acl.hujson"
        run configtest "$etc" "$lib"
        assert_success
    done
    # the check is not a formality: a base domain the CNC's own name falls under
    # fails it (written fresh: a bind mount may not see a file changed in place)
    etc="$BATS_TEST_TMPDIR/broken/etc" lib="$BATS_TEST_TMPDIR/broken/lib"
    mkdir -p "$etc" "$lib"
    connector_fn render_headscale_config https://hs.example.com example.com tls-alpn-01 >"$etc/config.yaml"
    connector_fn render_acl >"$etc/acl.hujson"
    run configtest "$etc" "$lib"
    assert_failure
    assert_output --partial "server_url cannot be part of base_domain"
}

@test "a Linux node stops trusting exactly the old CNC certificate, and its CA store is rebuilt without it" {
    run in_node '
        cd /tmp
        mk() { openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 30 \
            -subj "/CN=$1" -addext "subjectAltName=IP:$1" -keyout "$1.key" -out "$1.pem" >/dev/null 2>&1; }
        in_bundle() { grep -c -F "$(sed -n 2p "$1")" /etc/ssl/certs/ca-certificates.crt; }
        mk 203.0.113.1; mk 198.51.100.7
        # as an older connector left it, beside a certificate of the owner'"'"'s
        install -m 0644 203.0.113.1.pem /usr/local/share/ca-certificates/headscale-cnc.crt
        install -m 0644 198.51.100.7.pem /usr/local/share/ca-certificates/owner.crt
        update-ca-certificates >/dev/null 2>&1
        echo "before old=$(in_bundle 203.0.113.1.pem) owner=$(in_bundle 198.51.100.7.pem)"
        untrust_cert_sha256 "$(fp_of_pem <203.0.113.1.pem)"; echo "rc=$?"
        has() { [ -e "/usr/local/share/ca-certificates/$1" ] && echo "$1 kept" || echo "$1 gone"; }
        has headscale-cnc.crt; has owner.crt
        echo "after old=$(in_bundle 203.0.113.1.pem) owner=$(in_bundle 198.51.100.7.pem)"
        # a file of that name holding another certificate is not the one asked for
        install -m 0644 198.51.100.7.pem /usr/local/share/ca-certificates/headscale-cnc.crt
        untrust_cert_sha256 "$(fp_of_pem <203.0.113.1.pem)"
        has headscale-cnc.crt
    '
    assert_success
    assert_line "before old=1 owner=1"
    assert_line "rc=0"
    assert_line --index 3 "headscale-cnc.crt gone"
    assert_line --index 4 "owner.crt kept"
    assert_line "after old=0 owner=1"
    assert_line --partial "is not the certificate"
    assert_line --index 8 "headscale-cnc.crt kept"
}

@test "the headscale the docker tier runs is the release connector pins" {
    run docker run --rm "$HEADSCALE_IMAGE" version
    assert_success
    assert_line --partial "headscale version v$(connector_eval 'echo "$HEADSCALE_VERSION"')"
}

@test "cnc-init puts in what headscale takes, and keeps the CNC's config when headscale refuses the new one" {
    local bin
    bin="$(headscale_bin)"
    run in_node -v "$bin:/usr/local/bin/headscale:ro" '
        # a CNC with no systemd, nothing else on its ports, and no server for the CLI to ask
        systemctl() { echo "systemctl $*" >>/tmp/systemctl; }
        ss() { :; }
        headscale() { case "$1" in users) echo "[]" ;; *) /usr/local/bin/headscale "$@" ;; esac; }
        export ASSUME_YES=1
        ( cnc_init_local https://hs.example.com connector.mesh tls-alpn-01 ) >/tmp/first 2>&1; echo "first rc=$?"
        grep "^  base_domain:" /etc/headscale/config.yaml
        ( cnc_init_local https://hs.example.com example.com tls-alpn-01 ) >/tmp/second 2>&1; echo "second rc=$?"
        grep "^  base_domain:" /etc/headscale/config.yaml
        grep -c "server_url cannot be part of base_domain" /tmp/second
        grep -c "restart headscale" /tmp/systemctl
    '
    assert_success
    assert_line "first rc=0"
    assert_line --index 1 "  base_domain: connector.mesh"
    assert_line "second rc=1"
    assert_line --index 3 "  base_domain: connector.mesh"
    assert_line --index 4 "1"
    # headscale was restarted onto the config it took, never onto the one it refused
    assert_line --index 5 "1"
}

@test "a Linux provider follows the CNC to its new name, and its CA store loses the old root" {
    run in_node '
        tailscale() { echo "tailscale $*" >>/tmp/ts; [ "$1" != debug ] || echo "{\"ControlURL\":\"https://203.0.113.1:8443\",\"Hostname\":\"box1\"}"; }
        cd /tmp
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 30 \
            -subj /CN=203.0.113.1 -addext subjectAltName=IP:203.0.113.1 -keyout old.key -out old.pem >/dev/null 2>&1
        install -m 0644 old.pem /usr/local/share/ca-certificates/headscale-cnc.crt
        update-ca-certificates >/dev/null 2>&1
        mkdir -p ~/.config/connector; echo provider >~/.config/connector/role; cp old.pem ~/.config/connector/cnc-ca.crt
        ( cmd_migrate_cnc https://hs.example.com --authkey hskey-m ) >/tmp/out 2>&1; echo "rc=$?"
        grep " up " /tmp/ts
        [ -e /usr/local/share/ca-certificates/headscale-cnc.crt ] && echo "root kept" || echo "root gone"
        grep -c -F "$(sed -n 2p old.pem)" /etc/ssl/certs/ca-certificates.crt
        [ -e ~/.config/connector/cnc-ca.crt ] && echo "record kept" || echo "record gone"
    '
    assert_success
    assert_line "rc=0"
    assert_line "tailscale up --reset --login-server https://hs.example.com --accept-dns=true --force-reauth --hostname box1 --ssh --authkey hskey-m"
    assert_line "root gone"
    assert_line --index 3 "0"
    assert_line "record gone"
}
