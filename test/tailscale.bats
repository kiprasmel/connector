#!/usr/bin/env bats

# tailscale on a Linux node: from its apt repository, by the key pinned for
# it and no other, named alone by the source -- or the distribution's own
# package -- and never a script piped to a shell.

load helpers

setup() {
    common_setup
    rm -f "$STUBS/tailscale"   # not installed yet: the package manager puts it in
    stub uname 'echo Linux'
    printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' >"$BATS_TEST_TMPDIR/os-release"
    # tailscale's key -- here a vendor's own -- served by "curl" from wherever it is asked for
    export GNUPGHOME="$BATS_TEST_TMPDIR/gnupg"
    mkdir -m 700 "$GNUPGHOME"
    gpg --batch --quiet --passphrase '' --quick-gen-key 'Vendor <v@example.org>' ed25519 sign 0 2>/dev/null
    VENDOR_FPR="$(gpg --batch --with-colons --list-keys v@example.org | awk -F: '/^fpr:/ { print $10; exit }')"
    gpg --batch --export v@example.org >"$BATS_TEST_TMPDIR/vendor.gpg"
    export SERVED="$BATS_TEST_TMPDIR/vendor.gpg" VENDOR_FPR BATS_TEST_TMPDIR
    stub curl 'while [ $# -gt 0 ]; do if [ "$1" = -o ]; then cp "$SERVED" "$2"; exit 0; fi; shift; done; exit 22'
    stub dpkg 'echo amd64'
    put_in='printf "#!/bin/sh\nexit 0\n" >"$STUBS/tailscale"; chmod +x "$STUBS/tailscale"'
    stub apt-get "case \"\$*\" in *'install -y tailscale'*) $put_in ;; esac"
    stub pacman "$put_in"
}

# install_tailscale, this machine's files under the sandbox and <fpr> pinned.
install() {
    connector_eval "OS_RELEASE=\"\$BATS_TEST_TMPDIR/os-release\" TS_APT_KEYRING=\"\$BATS_TEST_TMPDIR/keyrings/ts.gpg\" TS_APT_LIST=\"\$BATS_TEST_TMPDIR/ts.list\" TS_APT_KEY_FPR=\"$1\"
        have() { if [ \"\$1\" = tailscale ]; then [ -x \"\$STUBS/tailscale\" ]; else command -v \"\$1\" >/dev/null 2>&1; fi; }
        install_tailscale"
}

@test "tailscale comes from its apt repository, by its pinned key, named alone by the source" {
    run install "$VENDOR_FPR"
    assert_success
    run cat "$BATS_TEST_TMPDIR/ts.list"
    assert_output "deb [arch=amd64 signed-by=$BATS_TEST_TMPDIR/keyrings/ts.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main"
    cmp "$BATS_TEST_TMPDIR/keyrings/ts.gpg" "$SERVED"
    run calls_of curl
    assert_output --regexp " https://pkgs\.tailscale\.com/stable/ubuntu/noble\.noarmor\.gpg$"
    run calls_of apt-get
    assert_line --partial "apt-get install -y tailscale"
}

@test "a key that is not the pinned one, or one beside it, installs nothing" {
    run install 0000000000000000000000000000000000000000
    assert_failure
    assert_output --partial "not the pinned 0000000000000000000000000000000000000000; nothing installed"
    gpg --batch --quiet --passphrase '' --quick-gen-key 'Other <o@example.org>' ed25519 sign 0 2>/dev/null
    gpg --batch --export v@example.org o@example.org >"$SERVED"
    run install "$VENDOR_FPR"
    assert_failure
    assert_output --partial "tailscale's apt key is $VENDOR_FPR "
    [ ! -e "$BATS_TEST_TMPDIR/ts.list" ]
    [ ! -e "$BATS_TEST_TMPDIR/keyrings/ts.gpg" ]
    run calls_of apt-get
    refute_output --partial "install -y tailscale"
}

@test "a derivative gets the repository of the distribution it is like; others their own package, or nothing" {
    printf 'ID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_CODENAME=virginia\nUBUNTU_CODENAME=jammy\n' >"$BATS_TEST_TMPDIR/os-release"
    run install "$VENDOR_FPR"
    assert_success
    run cat "$BATS_TEST_TMPDIR/ts.list"
    assert_output --partial "https://pkgs.tailscale.com/stable/ubuntu jammy main"
    # Arch: its own package, from its own signed repository
    rm -f "$STUBS/tailscale" "$STUBS/apt-get"
    : >"$CALLS"
    printf 'ID=arch\n' >"$BATS_TEST_TMPDIR/os-release"
    run install "$VENDOR_FPR"
    assert_success
    run calls_of pacman
    assert_output --partial "pacman -Sy --needed --noconfirm tailscale"
    [ -z "$(calls_of curl)" ]
    # nothing that packages it: said, and nothing fetched
    rm -f "$STUBS/tailscale" "$STUBS/pacman"
    : >"$CALLS"
    printf 'ID=gentoo\n' >"$BATS_TEST_TMPDIR/os-release"
    run connector_eval "OS_RELEASE=\"\$BATS_TEST_TMPDIR/os-release\"
        have() { case \"\$1\" in tailscale|apt-get|pacman|dnf|yum|zypper|apk|brew) return 1 ;; *) command -v \"\$1\" >/dev/null 2>&1 ;; esac; }
        install_tailscale"
    assert_failure
    assert_output --partial "No tailscale package here"
    [ -z "$(calls_of curl)" ]
}

@test "no script is ever piped to a shell" {
    run grep -c -e 'install\.sh' -e '|[[:space:]]*sh\b' -e '|[[:space:]]*bash\b' "$CONNECTOR"
    assert_output 0
}
