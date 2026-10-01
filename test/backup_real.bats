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
