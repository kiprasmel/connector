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
        # a base domain of its own, kept by a re-run that names none (every node'"'"'s name with it)
        ( cnc_init_local https://hs.example.com corp.mesh tls-alpn-01 ) >/tmp/third 2>&1; echo "third rc=$?"
        ( cnc_init_local https://hs.example.com "" tls-alpn-01 ) >/tmp/fourth 2>&1; echo "fourth rc=$?"
        grep "^  base_domain:" /etc/headscale/config.yaml
    '
    assert_success
    assert_line "first rc=0"
    assert_line --index 1 "  base_domain: connector.mesh"
    assert_line "second rc=1"
    assert_line --index 3 "  base_domain: connector.mesh"
    assert_line --index 4 "1"
    # headscale was restarted onto the config it took, never onto the one it refused
    assert_line --index 5 "1"
    assert_line "third rc=0"
    assert_line "fourth rc=0"
    assert_line --index 8 "  base_domain: corp.mesh"
}

@test "a Linux provider follows the CNC to its new name, and its CA store loses the old root" {
    run in_node '
        tailscale() {
            echo "tailscale $*" >>/tmp/ts
            local a prev=""; for a in "$@"; do [ "$prev" != --auth-key ] || cat "${a#file:}" >/tmp/key; prev="$a"; done
            [ "$1" != debug ] || echo "{\"ControlURL\":\"https://203.0.113.1:8443\",\"Hostname\":\"box1\"}"
        }
        cd /tmp
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 30 \
            -subj /CN=203.0.113.1 -addext subjectAltName=IP:203.0.113.1 -keyout old.key -out old.pem >/dev/null 2>&1
        install -m 0644 old.pem /usr/local/share/ca-certificates/headscale-cnc.crt
        update-ca-certificates >/dev/null 2>&1
        mkdir -p ~/.config/connector; echo provider >~/.config/connector/role; cp old.pem ~/.config/connector/cnc-ca.crt
        ( cmd_migrate_cnc https://hs.example.com --authkey hskey-m ) >/tmp/out 2>&1; echo "rc=$?"
        grep " up " /tmp/ts | sed "s#file:[^ ]*#file:KEYFILE#"
        echo "key: $(cat /tmp/key)"
        [ -e /usr/local/share/ca-certificates/headscale-cnc.crt ] && echo "root kept" || echo "root gone"
        echo "in bundle: $(grep -c -F "$(sed -n 2p old.pem)" /etc/ssl/certs/ca-certificates.crt)"
        [ -e ~/.config/connector/cnc-ca.crt ] && echo "record kept" || echo "record gone"
    '
    assert_success
    assert_line "rc=0"
    assert_line "tailscale up --reset --login-server https://hs.example.com --accept-dns=true --force-reauth --hostname box1 --ssh --auth-key file:KEYFILE"
    assert_line "key: hskey-m"
    assert_line "root gone"
    assert_line "in bundle: 0"
    assert_line "record gone"
}

# A script fragment: headscale serving /tmp/hs-config.yaml in the node, with
# connector's users, so `hs_check <policy>` asks it what it makes of a policy.
HS_SERVE='
    mkdir -p /tmp/hs
    /usr/local/bin/headscale -c /tmp/hs-config.yaml serve >/tmp/hs/serve.log 2>&1 &
    for _ in $(seq 1 100); do [ -S /tmp/hs/headscale.sock ] && break; sleep 0.1; done
    for u in mesh ops; do /usr/local/bin/headscale -c /tmp/hs-config.yaml users create "$u" >/dev/null 2>&1; done
    hs_check() { /usr/local/bin/headscale -c /tmp/hs-config.yaml policy check -f "$1" 2>&1 | tail -n 1; return "${PIPESTATUS[0]}"; }
'

@test "the policy connector writes keeps the site's rules, never overwrites them, and headscale takes it" {
    local bin
    bin="$(headscale_bin)"
    run in_node -v "$bin:/usr/local/bin/headscale:ro" -v "$REPO_ROOT/test/docker/headscale-test.yaml:/tmp/hs-config.yaml:ro" '
        # the site made the fragment its own: a rule of its own in it
        mkdir -p /etc/headscale
        render_site_acl | jq ".acls += [{\"action\":\"accept\",\"src\":[\"group:ops\"],\"dst\":[\"tag:consumer:22\"]}]" >/etc/headscale/acl.site.json
        before="$(sha256sum /etc/headscale/acl.site.json)"
        ( write_acl ) && ( write_acl ); echo "write rc=$?"
        [ "$(sha256sum /etc/headscale/acl.site.json)" = "$before" ] && echo "site as it was"
        jq -c ".acls[-1]" /etc/headscale/acl.hujson
        '"$HS_SERVE"'
        hs_check /etc/headscale/acl.hujson; echo "check rc=$?"
        # and the check bites: a tag no one owns
        jq ".acls += [{\"action\":\"accept\",\"src\":[\"group:ops\"],\"dst\":[\"tag:nobody:22\"]}]" /etc/headscale/acl.hujson >/tmp/bad.json
        hs_check /tmp/bad.json; echo "bad rc=$?"
    '
    assert_success
    assert_line "write rc=0"
    assert_line "site as it was"
    assert_line '{"action":"accept","src":["group:ops"],"dst":["tag:consumer:22"]}'
    assert_line "Policy is valid"
    assert_line "check rc=0"
    assert_line --partial 'tag not found: "tag:nobody"'
    assert_line "bad rc=1"
}

@test "cnc-init keeps the policy before when the site fragment would open a prod machine" {
    local bin
    bin="$(headscale_bin)"
    run in_node -v "$bin:/usr/local/bin/headscale:ro" '
        systemctl() { :; }
        ss() { :; }
        headscale() { case "$1" in users) echo "[]" ;; *) /usr/local/bin/headscale "$@" ;; esac; }
        export ASSUME_YES=1
        ( cnc_init_local https://hs.example.com connector.mesh tls-alpn-01 ) >/tmp/first 2>&1; echo "first rc=$?"
        before="$(sha256sum /etc/headscale/acl.hujson)"
        jq ".ssh += [{\"action\":\"accept\",\"src\":[\"group:ops\"],\"dst\":[\"tag:prod\"],\"users\":[\"root\"]}]" \
            /etc/headscale/acl.site.json >/tmp/site && cp /tmp/site /etc/headscale/acl.site.json
        ( cnc_init_local https://hs.example.com connector.mesh tls-alpn-01 ) >/tmp/second 2>&1; echo "second rc=$?"
        [ "$(sha256sum /etc/headscale/acl.hujson)" = "$before" ] && echo "policy as it was"
        grep -c "no one gets SSH to one; refused" /tmp/second
    '
    assert_success
    assert_line "first rc=0"
    assert_line "second rc=1"
    assert_line "policy as it was"
    assert_line --index 3 "1"
}
