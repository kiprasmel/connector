#!/usr/bin/env bats

# The policy headscale reads is connector's rules and the site's: the site
# fragment is the site's own, and no fragment opens a prod machine -- a prod
# machine is granted nothing, and no one gets Tailscale SSH to one.

load helpers

setup() {
    common_setup
    connector_fn render_acl >"$BATS_TEST_TMPDIR/base.json"
    connector_fn render_site_acl >"$BATS_TEST_TMPDIR/site.json"
}

# The policy composed from base and <site> (a file), into acl.json.
compose() {
    connector_fn compose_acl "$BATS_TEST_TMPDIR/base.json" "$1" >"$BATS_TEST_TMPDIR/acl.json"
}

# The default site with <jq> applied to it, as a file. Stdout: its path.
site_with() {
    jq "$1" "$BATS_TEST_TMPDIR/site.json" >"$BATS_TEST_TMPDIR/site.edited.json"
    printf '%s\n' "$BATS_TEST_TMPDIR/site.edited.json"
}

@test "the policy is connector's rules, then the site's: operators reach prod on 22 and 443 alone" {
    compose "$BATS_TEST_TMPDIR/site.json"
    run jq -c '.acls' "$BATS_TEST_TMPDIR/acl.json"
    assert_output '[{"action":"accept","src":["tag:consumer"],"dst":["tag:provider:*"]},{"action":"accept","src":["group:ops"],"dst":["tag:prod:22,443"]},{"action":"accept","src":["group:ops"],"dst":["tag:provider:*"]}]'
    run jq -c '.groups, .tagOwners' "$BATS_TEST_TMPDIR/acl.json"
    assert_line '{"group:ops":["ops@"]}'
    assert_line '{"tag:provider":["mesh@"],"tag:consumer":["mesh@"],"tag:prod":["group:ops"]}'
    # no Tailscale SSH to a prod machine
    run jq -c '[.ssh[].dst[]]' "$BATS_TEST_TMPDIR/acl.json"
    assert_output '["tag:provider","tag:provider"]'
    run connector_fn acl_keeps_prod_closed "$BATS_TEST_TMPDIR/acl.json"
    assert_success
}

@test "a site that grants a prod machine anything, or SSH to one, is refused" {
    local edit
    for edit in \
        '.acls += [{"action":"accept","src":["tag:prod"],"dst":["tag:provider:*"]}]' \
        '.acls += [{"action":"accept","src":["*"],"dst":["tag:provider:22"]}]' \
        '.acls += [{"action":"accept","src":["autogroup:tagged"],"dst":["group:ops:*"]}]' \
        '.ssh += [{"action":"accept","src":["group:ops"],"dst":["tag:prod"],"users":["root"]}]' \
        '.ssh += [{"action":"accept","src":["group:ops"],"dst":["autogroup:tagged"],"users":["autogroup:nonroot"]}]' \
        '.acls += [{"action":"accept","src":["autogroup:danger-all"],"dst":["tag:provider:*"]}]' \
        '.ssh += [{"action":"accept","src":["tag:prod"],"dst":["tag:provider"],"users":["autogroup:nonroot"]}]' \
        '.acls += [{"action":"accept","src":["100.64.0.0/10"],"dst":["tag:provider:*"]}]' \
        '.acls += [{"action":"accept","src":["0.0.0.0/0"],"dst":["tag:provider:*"]}]' \
        '.acls += [{"action":"accept","src":["100.127.255.254"],"dst":["tag:provider:*"]}]' \
        '.acls += [{"action":"accept","src":["100.96.0.0/12"],"dst":["tag:provider:*"]}]' \
        '.acls += [{"action":"accept","src":["fd7a:115c:a1e0::/48"],"dst":["tag:provider:*"]}]' \
        '.acls += [{"action":"accept","src":["fd7a:115c:a1e0:ab12:4843:cd96:6258:b240"],"dst":["tag:provider:*"]}]' \
        '.acls += [{"action":"accept","src":["fd7a::/16"],"dst":["tag:provider:*"]}]' \
        '.acls += [{"action":"accept","src":["::/0"],"dst":["tag:provider:*"]}]' \
        '.acls += [{"action":"accept","src":["::ffff:100.64.0.1"],"dst":["tag:provider:*"]}]' \
        '.hosts = {"everyone": "100.64.0.0/10"} | .acls += [{"action":"accept","src":["everyone"],"dst":["tag:provider:*"]}]' \
        '.acls += [{"action":"accept","src":["no-such-name"],"dst":["tag:provider:*"]}]'
    do
        compose "$(site_with "$edit")"
        run connector_fn acl_keeps_prod_closed "$BATS_TEST_TMPDIR/acl.json"
        assert_failure
        assert_output --partial "A prod machine is granted nothing, and no one gets SSH to one; refused:"
    done
}

@test "a site fragment that is not strict JSON is not composed" {
    printf '{ // the ops rules\n  "acls": [],\n}\n' >"$BATS_TEST_TMPDIR/hujson.json"
    run connector_fn compose_acl "$BATS_TEST_TMPDIR/base.json" "$BATS_TEST_TMPDIR/hujson.json"
    assert_failure
}

@test "a source that holds no prod machine passes: users, groups, untagged members, and addresses off the tailnet" {
    compose "$(site_with '.hosts = {"office": "192.168.1.0/24"}
        | .acls += [{"action":"accept","src":["office","192.168.7.1","10.0.0.0/8","100.128.0.0/16","100.63.255.255",
            "fd7a:115c:a1e1::/48","fd00::/64","2001:db8::1","autogroup:member","ops@","group:ops","tag:consumer"],"dst":["tag:provider:*"]}]
        | .ssh += [{"action":"accept","src":["group:ops"],"dst":["autogroup:self"],"users":["autogroup:nonroot"]}]')"
    run connector_fn acl_keeps_prod_closed "$BATS_TEST_TMPDIR/acl.json"
    assert_success
}

@test "a site fragment holding what connector does not compose is refused, never dropped unseen" {
    local edit
    for edit in \
        '.grants = [{"src":["tag:prod"],"dst":["tag:provider"],"ip":["*"]}]' \
        '.autoApprovers = {"routes":{"10.0.0.0/8":["tag:provider"]}}' \
        '[.]'
    do
        run connector_fn compose_acl "$BATS_TEST_TMPDIR/base.json" "$(site_with "$edit")"
        assert_failure
        assert_output --partial "connector composes groups, tagOwners, hosts, acls and ssh from the site, and nothing else"
    done
    # an empty fragment is no rules
    : >"$BATS_TEST_TMPDIR/empty.json"
    run connector_fn compose_acl "$BATS_TEST_TMPDIR/base.json" "$BATS_TEST_TMPDIR/empty.json"
    assert_success
}
