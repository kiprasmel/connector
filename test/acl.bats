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
        '.ssh += [{"action":"accept","src":["group:ops"],"dst":["autogroup:tagged"],"users":["autogroup:nonroot"]}]'
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
