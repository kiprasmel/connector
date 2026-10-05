#!/usr/bin/env bats

# headscale at its pinned release: checked by sha256 before anything is
# installed, put in over an older one, never over a newer one.

load helpers

setup() {
    common_setup
    stub apt-get
    stub uname 'if [ "$1" = -m ]; then echo x86_64; else echo Linux; fi'
    # the headscale installed (HS_INSTALLED), and what a download brings (CURL_BODY)
    stub headscale '[ "$1" != version ] || printf "headscale version v%s\ncommit: 0\n" "$HS_INSTALLED"'
    stub curl 'while [ $# -gt 0 ]; do if [ "$1" = -o ]; then printf "%s" "$CURL_BODY" >"$2"; exit 0; fi; shift; done; exit 22'
    export CURL_BODY="a release"
}

@test "the pin is a version and the sha256 of each artifact" {
    run connector_eval 'echo "$HEADSCALE_VERSION"'
    assert_output --regexp '^[0-9]+\.[0-9]+\.[0-9]+$'
    local a k
    for a in amd64 arm64; do
        for k in deb bin; do
            run connector_fn headscale_artifact "$a" "$k"
            assert_success
            assert_output --regexp "^headscale_[0-9.]+_linux_${a}(\.deb)? [0-9a-f]{64}$"
        done
    done
    run connector_fn headscale_artifact arm deb
    assert_failure
}

@test "the pinned release, installed, is left as it is" {
    export HS_INSTALLED="$(connector_eval 'echo "$HEADSCALE_VERSION"')"
    run connector_fn install_headscale
    assert_success
    assert_output --partial "the pinned release) is installed"
    [ -z "$(calls_of curl)" ]
    [ -z "$(calls_of apt-get)" ]
}

@test "a download that is not the pinned release installs nothing" {
    export HS_INSTALLED=0.26.1
    run connector_fn install_headscale
    assert_failure
    assert_output --partial "is not the pinned release"
    assert_output --partial "nothing installed"
    run calls_of curl
    assert_output --regexp "/releases/download/v[0-9.]+/headscale_[0-9.]+_linux_amd64\.deb$"
    [ -z "$(calls_of apt-get)" ]
}

@test "the pinned release goes in over an older one once its sha256 holds, asking nothing and keeping the config in place" {
    export HS_INSTALLED=0.26.1
    # shellcheck disable=SC2016  # expands in the stub
    stub apt-get 'echo "${DEBIAN_FRONTEND:-interactive} $*" >>"$BATS_TEST_TMPDIR/frontend"'
    # the pin names what this download is
    run connector_eval 'headscale_artifact() { printf "headscale_x_linux_amd64.deb %s\n" "$(printf "%s" "$CURL_BODY" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d" " -f1)"; }
        install_headscale'
    assert_success
    assert_output --partial "over 0.26.1"
    run calls_of apt-get
    assert_line --regexp "^apt-get install -y -o Dpkg::Options::=--force-confold .*/headscale_x_linux_amd64\.deb$"
    # the install, the one step that can ask, runs with nothing to ask
    run cat "$BATS_TEST_TMPDIR/frontend"
    assert_line --regexp "^noninteractive install -y -o Dpkg::Options::=--force-confold .*/headscale_x_linux_amd64\.deb$"
}

@test "a newer headscale is never downgraded" {
    export HS_INSTALLED=9.0.0
    run connector_fn install_headscale
    assert_failure
    assert_output --partial "never downgrades it"
    [ -z "$(calls_of curl)" ]
}

@test "a headscale that cannot say its version is not the pinned one: the pinned release is fetched for it" {
    stub headscale 'exit 1'
    run connector_fn install_headscale
    assert_failure
    assert_output --partial "Installing headscale"
    assert_output --partial "is not the pinned release"
}
