#!/usr/bin/env bats

# A CNC's state, encrypted to the admin's key alone, and restored from it --
# as root in the pinned ubuntu, with age, sqlite3, and headscale's own binary
# to say whether what came back runs.

# bats file_tags=tier:docker

load helpers

setup() {
    common_setup
    require_docker
    HS_BIN="$(headscale_bin)"
}

# A CNC with state: a config and policy headscale takes (its database and
# keys made by configtest), a user of the test's own in that database --
# headscale refuses a table it does not know -- and the admin's age key.
CNC_STATE='
    systemctl() { echo "systemctl $*" >>/tmp/systemctl; }
    mkdir -p /etc/headscale /var/lib/headscale
    render_headscale_config https://hs.example.com connector.mesh tls-alpn-01 >/etc/headscale/config.yaml
    render_site_acl >/etc/headscale/acl.site.json
    render_acl >/tmp/base.json
    compose_acl /tmp/base.json /etc/headscale/acl.site.json >/etc/headscale/acl.hujson
    headscale configtest >/dev/null 2>&1 || echo "configtest failed"
    sqlite3 /var/lib/headscale/db.sqlite "INSERT INTO users (name, created_at, updated_at) VALUES (\"marker\", datetime(), datetime());"
    age-keygen -o /tmp/admin.key 2>/dev/null
    ADMIN="$(age-keygen -y /tmp/admin.key)"
'

@test "a backup holds the CNC's state encrypted to the admin's key alone, and a restore brings it back" {
    run in_node -v "$HS_BIN:/usr/local/bin/headscale:ro" "$CNC_STATE"'
        ( cmd_backup --out /tmp/b.tar.age --recipient "$ADMIN" ) >/tmp/out 2>&1; echo "backup rc=$?"
        echo "mode $(stat -c %a /tmp/b.tar.age)"
        echo "header $(head -c 21 /tmp/b.tar.age)"
        echo "noise in clear: $(grep -c -F "$(cat /var/lib/headscale/noise_private.key)" /tmp/b.tar.age)"
        noise="$(sha256sum </var/lib/headscale/noise_private.key)"
        # the CNC loses what it had
        sqlite3 /var/lib/headscale/db.sqlite "DELETE FROM users WHERE name = \"marker\";"
        ( cmd_restore /tmp/b.tar.age --identity /tmp/admin.key --yes ) >/tmp/restore 2>&1; echo "restore rc=$?"
        echo "users: $(sqlite3 /var/lib/headscale/db.sqlite "SELECT name FROM users;")"
        [ "$(sha256sum </var/lib/headscale/noise_private.key)" = "$noise" ] && echo "noise key back"
        echo "aside: $(sqlite3 /var/lib/headscale.before-restore-*/db.sqlite "SELECT count(*) FROM users;")"
        echo "started: $(grep -c "systemctl start headscale" /tmp/systemctl)"
    '
    assert_success
    assert_line "backup rc=0"
    assert_line "mode 600"
    assert_line "header age-encryption.org/v1"
    assert_line "noise in clear: 0"
    assert_line "restore rc=0"
    assert_line "users: marker"
    assert_line "noise key back"
    assert_line "aside: 0"
    assert_line "started: 1"
}

@test "no recipient, no backup; a key not the recipient's restores nothing; nor does an archive of anything else" {
    run in_node -v "$HS_BIN:/usr/local/bin/headscale:ro" "$CNC_STATE"'
        ( cmd_backup --out /tmp/none.tar.age ) >/tmp/out 2>&1; echo "none rc=$?"
        [ -e /tmp/none.tar.age ] && echo "none kept" || echo "none written"
        ( cmd_backup --out /tmp/b.tar.age --recipient "$ADMIN" ) >/dev/null 2>&1
        db="$(sha256sum </var/lib/headscale/db.sqlite)"
        age-keygen -o /tmp/other.key 2>/dev/null
        ( cmd_restore /tmp/b.tar.age --identity /tmp/other.key --yes ) >/tmp/r1 2>&1; echo "other key rc=$?"
        # an archive with a link in it, encrypted to the admin all the same
        mkdir -p /tmp/evil/var/lib/headscale /tmp/evil/etc/headscale
        cp /etc/headscale/config.yaml /tmp/evil/etc/headscale/
        cp /var/lib/headscale/db.sqlite /tmp/evil/var/lib/headscale/
        ln -s /root /tmp/evil/var/lib/headscale/cache
        tar -C /tmp/evil -cf - . | age -r "$ADMIN" >/tmp/evil.tar.age
        ( cmd_restore /tmp/evil.tar.age --identity /tmp/admin.key --yes ) >/tmp/r2 2>&1; echo "evil rc=$?"
        echo "refused: $(grep -c "refused" /tmp/r2)"
        [ "$(sha256sum </var/lib/headscale/db.sqlite)" = "$db" ] && echo "state as it was"
        echo "asides: $(ls -d /var/lib/headscale.before-restore-* 2>/dev/null | wc -l)"
    '
    assert_success
    assert_line "none rc=1"
    assert_line "none written"
    assert_line "other key rc=1"
    assert_line "evil rc=1"
    assert_line "refused: 1"
    assert_line "state as it was"
    assert_line "asides: 0"
}

@test "a recipient age takes no key for backs up nothing, schedules nothing, and leaves nothing in the clear" {
    run in_node -v "$HS_BIN:/usr/local/bin/headscale:ro" "$CNC_STATE"'
        # in bech32 alphabet and of the length, as a typo is: no key age reads
        BAD="age1$(printf "q%.0s" $(seq 1 58))"
        backup_recipient_ok "$BAD" && echo "looks like one"
        ( cmd_backup --out /tmp/bad.tar.age --recipient "$BAD" ) >/tmp/out 2>&1; echo "backup rc=$?"
        [ -e /tmp/bad.tar.age ] && echo "kept" || echo "nothing kept"
        # as a manager asks for it over ssh: the script itself, errexit and all
        /usr/local/bin/connector backup-stream "$BAD" >/tmp/stream 2>/dev/null; echo "stream rc=$?"
        echo "in the clear: $(find /tmp -path "*/state/*" \( -name db.sqlite -o -name noise_private.key \) | wc -l)"
        ( backup_schedule_local --recipient "$BAD" ) >/tmp/sched 2>&1; echo "schedule rc=$?"
        [ -e /etc/headscale/backup.recipients ] && echo "recipients written" || echo "no recipients"
        [ -e /etc/systemd/system/connector-backup.service ] && echo "units written" || echo "no units"
        # a list of comments alone, a recipient given: it is the one
        echo "# none yet" >/etc/headscale/backup.recipients
        ( cmd_backup --out /tmp/c.tar.age --recipient "$ADMIN" ) >/tmp/c 2>&1; echo "comments rc=$?"
        age -d -i /tmp/admin.key /tmp/c.tar.age | tar -tf - | grep -c "^./var/lib/headscale/db.sqlite$"
        # and a recipients file of comments and a key: scheduled, age reading it as written
        printf "# the admin\n%s\n" "$ADMIN" >/etc/headscale/backup.recipients
        ( backup_schedule_local ) >/tmp/listed 2>&1; echo "listed rc=$?"
        echo "in the clear: $(find /tmp -path "*/state/*" \( -name db.sqlite -o -name noise_private.key \) | wc -l)"
    '
    assert_success
    assert_line "looks like one"
    assert_line "backup rc=1"
    assert_line "nothing kept"
    assert_line "stream rc=1"
    assert_line --index 4 "in the clear: 0"
    assert_line "schedule rc=1"
    assert_line "no recipients"
    assert_line "no units"
    assert_line "comments rc=0"
    assert_line --index 9 "1"
    assert_line "listed rc=0"
    assert_line --index 11 "in the clear: 0"
}

@test "a restore headscale cannot run is undone, and the CNC runs what it had" {
    run in_node -v "$HS_BIN:/usr/local/bin/headscale:ro" "$CNC_STATE"'
        # a backup whose database headscale refuses: a table it does not know
        cp /var/lib/headscale/db.sqlite /tmp/db.keep
        sqlite3 /var/lib/headscale/db.sqlite "CREATE TABLE marks(v text);"
        ( cmd_backup --out /tmp/b.tar.age --recipient "$ADMIN" ) >/dev/null 2>&1; echo "backup rc=$?"
        cp /tmp/db.keep /var/lib/headscale/db.sqlite
        db="$(sha256sum </var/lib/headscale/db.sqlite)"
        : >/tmp/systemctl
        ( cmd_restore /tmp/b.tar.age --identity /tmp/admin.key --yes ) >/tmp/r 2>&1; echo "restore rc=$?"
        echo "said: $(grep -c "the state before is back in place" /tmp/r)"
        [ "$(sha256sum </var/lib/headscale/db.sqlite)" = "$db" ] && echo "state as it was"
        echo "asides: $(ls -d /var/lib/headscale.before-restore-* 2>/dev/null | wc -l)"
        headscale configtest >/dev/null 2>&1 && echo "it runs"
        cat /tmp/systemctl
    '
    assert_success
    assert_line "backup rc=0"
    assert_line "restore rc=1"
    assert_line "said: 1"
    assert_line "state as it was"
    assert_line "asides: 0"
    assert_line "it runs"
    assert_line "systemctl stop headscale"
    assert_line "systemctl start headscale"
}

@test "a backup cut short restores nothing, nor does a step that fails, and nothing of it stays in the clear" {
    run in_node -v "$HS_BIN:/usr/local/bin/headscale:ro" "$CNC_STATE"'
        ( cmd_backup --out /tmp/b.tar.age --recipient "$ADMIN" ) >/dev/null 2>&1; echo "backup rc=$?"
        db="$(sha256sum </var/lib/headscale/db.sqlite)"
        staged() { find /tmp -name backup.tar | wc -l; }
        # a copy cut short: age writes the chunks it could, then stops
        head -c 70000 /tmp/b.tar.age >/tmp/cut.tar.age
        ( cmd_restore /tmp/cut.tar.age --identity /tmp/admin.key --yes ) >/tmp/r1 2>&1; echo "cut rc=$?"
        echo "said: $(grep -c "does not decrypt whole" /tmp/r1)"
        # the stream itself cut short, at a member: tar would read what came
        age -d -i /tmp/admin.key /tmp/b.tar.age >/tmp/full.tar
        head -c 65536 /tmp/full.tar >/tmp/short.tar
        ( restore_stream_local </tmp/short.tar ) >/tmp/r2 2>&1; echo "short rc=$?"
        /usr/local/bin/connector restore-stream </tmp/short.tar >/tmp/r3 2>&1; echo "short stream rc=$?"
        # a name that climbs out, whole (a space before it no longer hides it)
        mkdir -p /tmp/s/etc/headscale && echo x >/tmp/s/etc/headscale/x
        tar -C /tmp/s --transform "s,etc/headscale/x,etc/headscale/a ../../../../tmp/pwned," -cf /tmp/climb.tar ./etc/headscale/x
        ( restore_stream_local </tmp/climb.tar ) >/tmp/r4 2>&1; echo "climb rc=$?"
        echo "climb refused: $(grep -c "refused" /tmp/r4)"
        # putting it in place fails partway: the state before goes back
        ( cp() { case "$*" in *"/x/var/lib/headscale/."*) return 1 ;; *) command cp "$@" ;; esac; }
          restore_stream_local </tmp/full.tar ) >/tmp/r5 2>&1; echo "put rc=$?"
        echo "said: $(grep -c "could not be put in place; the state before is back in place" /tmp/r5)"
        [ "$(sha256sum </var/lib/headscale/db.sqlite)" = "$db" ] && echo "state as it was"
        echo "asides: $(ls -d /var/lib/headscale.before-restore-* 2>/dev/null | wc -l)"
        echo "staged: $(staged)"
        [ -e /tmp/pwned ] && echo "climbed" || echo "stayed"
    '
    assert_success
    assert_line "backup rc=0"
    assert_line "cut rc=1"
    assert_line --index 2 "said: 1"
    assert_line "short rc=1"
    assert_line "short stream rc=1"
    assert_line "climb rc=1"
    assert_line "climb refused: 1"
    assert_line "put rc=1"
    assert_line --index 8 "said: 1"
    assert_line "state as it was"
    assert_line "asides: 0"
    assert_line "staged: 0"
    assert_line "stayed"
}

@test "the CNC backs itself up daily, to its recipients alone, keeps the newest, and restore takes what the timer wrote" {
    run in_node -v "$HS_BIN:/usr/local/bin/headscale:ro" "$CNC_STATE"'
        systemctl() { echo "systemctl $*" >>/tmp/systemctl; }
        ( backup_schedule_local --recipient "$ADMIN" --keep 2 ) >/tmp/out 2>&1; echo "schedule rc=$?"
        grep -x "ExecStart=/usr/local/bin/connector backup-local --dir /var/backups/headscale --keep 2" /etc/systemd/system/connector-backup.service >/dev/null && echo "the service keeps 2"
        grep -x "OnCalendar=daily" /etc/systemd/system/connector-backup.timer >/dev/null && echo "the timer is daily"
        echo "enabled: $(grep -c "^systemctl enable --now connector-backup.timer$" /tmp/systemctl)"
        echo "recipients: $(grep -v "^#" /etc/headscale/backup.recipients)" | sed "s/$ADMIN/the admin/"
        # three days of it, as the timer runs it
        for i in 1 2 3; do ( backup_local --dir /var/backups/headscale --keep 2 ) >>/tmp/runs 2>&1 || echo "day $i failed"; sleep 1.1; done
        echo "kept: $(ls /var/backups/headscale | wc -l)"
        echo "dir $(stat -c %a /var/backups/headscale)"
        newest="$(ls /var/backups/headscale/headscale-*.tar.age | sort -r | awk "NR == 1")"
        echo "mode $(stat -c %a "$newest")"
        echo "header $(head -c 21 "$newest")"
        echo "private keys on the CNC: $(grep -rl "AGE-SECRET-KEY" /etc/headscale /var/backups /etc/systemd/system 2>/dev/null | wc -l)"
        sqlite3 /var/lib/headscale/db.sqlite "DELETE FROM users WHERE name = \"marker\";"
        ( cmd_restore "$newest" --identity /tmp/admin.key --yes ) >/tmp/restore 2>&1; echo "restore rc=$?"
        echo "users: $(sqlite3 /var/lib/headscale/db.sqlite "SELECT name FROM users;")"
    '
    assert_success
    assert_line "schedule rc=0"
    assert_line "the service keeps 2"
    assert_line "the timer is daily"
    assert_line "enabled: 1"
    assert_line "recipients: the admin"
    refute_line --partial "failed"
    assert_line "kept: 2"
    assert_line "dir 700"
    assert_line "mode 600"
    assert_line "header age-encryption.org/v1"
    assert_line "private keys on the CNC: 0"
    assert_line "restore rc=0"
    assert_line "users: marker"
}

@test "a schedule needs a recipient and refuses a private key; --off leaves the backups; a refresh rewrites a schedule that is there and puts in none" {
    run in_node -v "$HS_BIN:/usr/local/bin/headscale:ro" "$CNC_STATE"'
        systemctl() { echo "systemctl $*" >>/tmp/systemctl; }
        ( backup_schedule_local ) >/tmp/none 2>&1; echo "none rc=$?"
        age-keygen -o /tmp/other.key 2>/dev/null
        ( backup_schedule_local --recipient "$(grep "^AGE-SECRET-KEY" /tmp/other.key)" ) >/tmp/secret 2>&1; echo "secret rc=$?"
        echo "secret echoed: $(grep -c "AGE-SECRET-KEY" /tmp/secret)"
        grep "^AGE-SECRET-KEY" /tmp/other.key >/etc/headscale/backup.recipients
        ( backup_schedule_local ) >/tmp/listed 2>&1; echo "listed secret rc=$?"
        [ -e /etc/systemd/system/connector-backup.service ] && echo "units written" || echo "no units"
        # nothing scheduled: a refresh puts in none
        rm -f /etc/headscale/backup.recipients
        ( backup_schedule_local --refresh ) >/dev/null 2>&1; echo "refresh rc=$?"
        [ -e /etc/systemd/system/connector-backup.service ] && echo "units written" || echo "no units"
        # scheduled, its units edited: a refresh writes them back, the count kept
        ( backup_schedule_local --recipient "$ADMIN" --keep 5 ) >/dev/null 2>&1
        echo "# an older connector" >/etc/systemd/system/connector-backup.timer
        sed -i "s/^NoNewPrivileges=yes$//" /etc/systemd/system/connector-backup.service
        ( backup_schedule_local --refresh ) >/dev/null 2>&1; echo "refresh rc=$?"
        grep -c "^NoNewPrivileges=yes$" /etc/systemd/system/connector-backup.service
        grep -c "^OnCalendar=daily$" /etc/systemd/system/connector-backup.timer
        grep -c -- "--keep 5$" /etc/systemd/system/connector-backup.service
        # off: no timer, and the backups stay
        ( backup_local --dir /var/backups/headscale --keep 5 ) >/dev/null 2>&1
        : >/tmp/systemctl
        ( backup_schedule_local --off ) >/dev/null 2>&1; echo "off rc=$?"
        [ -e /etc/systemd/system/connector-backup.service ] || [ -e /etc/systemd/system/connector-backup.timer ] && echo "units left" || echo "units gone"
        echo "disabled: $(grep -c "^systemctl disable --now connector-backup.timer$" /tmp/systemctl)"
        echo "backups: $(ls /var/backups/headscale | wc -l)"
    '
    assert_success
    assert_line "none rc=1"
    assert_line "secret rc=1"
    assert_line "secret echoed: 0"
    assert_line "listed secret rc=1"
    assert_line --index 4 "no units"
    assert_line "refresh rc=0"
    assert_line --index 6 "no units"
    assert_line --index 8 "1"
    assert_line --index 9 "1"
    assert_line --index 10 "1"
    assert_line "off rc=0"
    assert_line "units gone"
    assert_line "disabled: 1"
    assert_line "backups: 1"
}

@test "the daily backup's timer and service are units systemd reads" {
    local units="$BATS_TEST_TMPDIR/units" img
    mkdir -p "$units"
    connector_fn backup_service_unit 14 >"$units/connector-backup.service"
    connector_fn backup_timer_unit >"$units/connector-backup.timer"
    # what makes the silence below mean something: one systemd refuses
    sed "s/^Type=oneshot$/Typo=oneshot/" "$units/connector-backup.service" >"$units/connector-canary.service"
    img="$(systemd_image)"
    run docker run --rm -v "$units:/etc/systemd/system/units:ro" -v "$CONNECTOR:/usr/local/bin/connector:ro" "$img" \
        sh -c 'cp /etc/systemd/system/units/* /etc/systemd/system/ && systemd-analyze verify /etc/systemd/system/connector-canary.service 2>&1; echo "---"; systemd-analyze verify /etc/systemd/system/connector-backup.timer /etc/systemd/system/connector-backup.service 2>&1 | grep -F connector-backup; true'
    assert_success
    assert_output --partial "connector-canary.service"
    assert_output --partial "Typo"
    assert_equal "${output##*---}" ""
}
