#!/usr/bin/env bats

# tailscale put on a Linux node the way register does, as root in the pinned
# ubuntu, from tailscale's real repository: apt reads the source and its
# signed-by keyring, verifies what it installs, and a pin the served key is
# not installs nothing. (These reach pkgs.tailscale.com.)

# bats file_tags=tier:docker

load helpers

setup() {
    common_setup
    require_docker
}

@test "a Debian-family node gets tailscale from its repository, by the pinned key, verified by apt" {
    run in_node '
        ( install_tailscale ) >/tmp/out 2>&1; echo "rc=$?"
        cat /etc/apt/sources.list.d/tailscale.list
        gpg --show-keys --with-colons /usr/share/keyrings/tailscale-archive-keyring.gpg 2>/dev/null | awk -F: "/^fpr:/ { print \$10; exit }"
        [ "$(apt-cache policy tailscale | grep -c "pkgs.tailscale.com/stable/ubuntu noble/main")" -gt 0 ] && echo "from the repository"
        grep -c NO_PUBKEY /tmp/out
        tailscale version | head -n 1 | grep -c "^[0-9]"
    '
    assert_success
    assert_line "rc=0"
    assert_line "deb [arch=$(docker run --rm "$UBUNTU_IMAGE" dpkg --print-architecture) signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main"
    assert_line "2596A99EAAB33821893C0A79458CA832957F5868"
    assert_line --index 3 "from the repository"
    assert_line --index 4 "0"
    assert_line --index 5 "1"
}

@test "a pin the served key is not installs nothing, and tells no apt of the repository" {
    run in_node '
        TS_APT_KEY_FPR=0000000000000000000000000000000000000000
        ( install_tailscale ) >/tmp/out 2>&1; echo "rc=$?"
        grep -c "not the pinned 0000000000000000000000000000000000000000; nothing installed" /tmp/out
        [ -e /etc/apt/sources.list.d/tailscale.list ] && echo "source written" || echo "no source"
        [ -e /usr/share/keyrings/tailscale-archive-keyring.gpg ] && echo "key kept" || echo "no key"
        command -v tailscale >/dev/null && echo "installed" || echo "not installed"
    '
    assert_success
    assert_line "rc=1"
    assert_line --index 1 "1"
    assert_line "no source"
    assert_line "no key"
    assert_line "not installed"
}
