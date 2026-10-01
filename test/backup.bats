#!/usr/bin/env bats

# A manager's backup and restore of the CNC: the archive is encrypted on the
# CNC to public keys alone and streamed into a new 0600 file here; a restore
# is decrypted here, where the private key is, and streamed to the CNC.
# (What the CNC does with either, as root: backup_real.bats.)

load helpers

setup() {
    common_setup
    mkdir -p "$HOME/.config/connector"
    printf 'CNC_SSH="nyc"\nCNC_URL="https://hs.example.com"\nCNC_PORT=""\nCNC_USER="admin"\n' >"$HOME/.config/connector/cnc"
    RCPT="age1$(printf 'q%.0s' $(seq 1 58))"
    export RCPT BACKUP_REPLY="age-encryption.org/v1
-> X25519 stanza
ciphertext"
    stub ssh 'case "$*" in
        *backup-stream*) printf "%s" "$BACKUP_REPLY" ;;
        *restore-stream*) cat >"$BATS_TEST_TMPDIR/restored" ;;
    esac'
    export BATS_TEST_TMPDIR
}

@test "a manager's backup streams from the CNC into a new 0600 file, encrypted to the recipients named" {
    run connector_fn cmd_backup --out "$BATS_TEST_TMPDIR/b.tar.age" --recipient "$RCPT"
    assert_success
    run head -c 21 "$BATS_TEST_TMPDIR/b.tar.age"
    assert_output "age-encryption.org/v1"
    [ -n "$(find "$BATS_TEST_TMPDIR/b.tar.age" -perm 600)" ]
    run calls_of ssh
    assert_line "ssh -o ConnectTimeout=10 nyc sudo\\ /usr/local/bin/connector\\ backup-stream\\ ${RCPT}"
    # never over a file
    run connector_fn cmd_backup --out "$BATS_TEST_TMPDIR/b.tar.age" --recipient "$RCPT"
    assert_failure
    assert_output --partial "goes into a new file only"
}

@test "a backup is encrypted to public keys alone: a secret key, or anything else, is refused" {
    local r
    for r in "AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ" "age1short" "-----BEGIN OPENSSH PRIVATE KEY-----" \
        "age1$(printf 'b%.0s' $(seq 1 58))" \
        $'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOf6XjP9q0 admin@laptop\nAGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ'; do
        run connector_fn cmd_backup --out "$BATS_TEST_TMPDIR/x" --recipient "$r"
        assert_failure
        assert_output --partial "Not a recipient"
        # not even its start: a secret key's first characters are its own
        [ "${#r}" -lt 24 ] || refute_output --partial "${r:16:8}"
        refute_output --partial "QQQQQQQQ"
    done
    [ ! -e "$BATS_TEST_TMPDIR/x" ]
    [ -z "$(calls_of ssh)" ]
    run connector_fn backup_recipient_ok "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOf6XjP9q0 admin@laptop"
    assert_success
}

@test "a reply that is not an encrypted backup is not kept" {
    export BACKUP_REPLY="plain tar, somehow"
    run connector_fn cmd_backup --out "$BATS_TEST_TMPDIR/b.tar.age" --recipient "$RCPT"
    assert_failure
    assert_output --partial "not an encrypted backup; nothing kept"
    [ ! -e "$BATS_TEST_TMPDIR/b.tar.age" ]
}

@test "a manager's restore decrypts here, where the private key is, and streams to the CNC" {
    stub age 'printf "the decrypted tar"'
    : >"$BATS_TEST_TMPDIR/b.tar.age"
    : >"$BATS_TEST_TMPDIR/admin.key"
    run connector_fn cmd_restore "$BATS_TEST_TMPDIR/b.tar.age" --identity "$BATS_TEST_TMPDIR/admin.key" --yes
    assert_success
    run calls_of age
    assert_output "age -d -i $BATS_TEST_TMPDIR/admin.key $BATS_TEST_TMPDIR/b.tar.age"
    run calls_of ssh
    assert_output --partial "sudo\\ /usr/local/bin/connector\\ restore-stream"
    run cat "$BATS_TEST_TMPDIR/restored"
    assert_output "the decrypted tar"
}

@test "a manager schedules the CNC's daily backup over SSH, to public keys alone, checked here before they go" {
    run connector_fn cmd_backup_schedule --recipient "$RCPT" --keep 7
    assert_success
    run calls_of ssh
    assert_line "ssh -o ConnectTimeout=10 nyc sudo\\ /usr/local/bin/connector\\ backup-schedule-local\\ --recipient\\ ${RCPT}\\ --keep\\ 7"
    : >"$CALLS"
    local secret="AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
    run connector_fn cmd_backup_schedule --recipient "$secret"
    assert_failure
    assert_output --partial "Not a recipient"
    refute_output --partial "$secret"
    run connector_fn cmd_backup_schedule --recipient "$RCPT" --keep 0
    assert_failure
    assert_output --partial "--keep is how many backups stay, 1 or more: not '0'"
    [ -z "$(calls_of ssh)" ]
    # and off, the same way
    run connector_fn cmd_backup_schedule --off
    assert_success
    run calls_of ssh
    assert_line "ssh -o ConnectTimeout=10 nyc sudo\\ /usr/local/bin/connector\\ backup-schedule-local\\ --off"
    # and with nothing, to the recipients the CNC lists: nothing is sent for an argument
    : >"$CALLS"
    run connector_fn cmd_backup_schedule
    assert_success
    run calls_of ssh
    assert_output "ssh -o ConnectTimeout=10 nyc sudo\\ /usr/local/bin/connector\\ backup-schedule-local"
}
