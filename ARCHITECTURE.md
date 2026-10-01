# Architecture

`connector` is a thin, role-aware bash wrapper around two tools that already do
the hard parts reliably:

- **[headscale](https://github.com/juanfont/headscale)** — a self-hosted
  implementation of the Tailscale control server. Runs on the VPS (the **CNC**).
- **[tailscale](https://tailscale.com/)** — the client daemon that every other
  machine runs to join the mesh.

The wrapper's only jobs are: install/configure these tools, gate onboarding so
new machines always need admin sign-off, and route admin commands to the CNC
(locally or transparently over SSH). Everything else — IP allocation, key
exchange, NAT traversal, DNS, SSH authz — is delegated to headscale/tailscale.

## Roles

A machine can hold several roles at once (a laptop is usually manager +
consumer). `connector` detects them from cheap, local state:

| Role           | Detected by                                             | Can do                                  |
|----------------|---------------------------------------------------------|-----------------------------------------|
| **cnc**        | `headscale` binary present **and** `/etc/headscale/config.yaml` exists | runs admin commands locally |
| **manager**    | a saved link at `~/.config/connector/cnc`               | runs admin commands on the CNC over SSH |
| **provider**   | local role file contains `provider` (`tag:provider`)    | accepts Tailscale SSH                   |
| **consumer**   | local role file contains `consumer` (`tag:consumer`)    | initiates SSH to providers              |
| **ops**        | local role file contains `ops` (untagged, user `ops`)   | reaches prod machines on ssh + https, and providers |

A **prod machine** (`tag:prod`) holds no connector role: it joins with a key
from `connector prod-key` and is only ever a destination.

`connector whoami` prints the detected set; `connector status` shows it too.

Only a **cnc or manager** may invite or approve machines, or promote a new
manager. A plain provider/consumer has no admin authority.

## Prod admin access on this mesh

The codespace control plane and its nodes join this tailnet as `tag:prod`
machines, so their admin SSH and HTTPS are reachable from operators'
machines and from nowhere else (the site policy above; their own firewalls
and sshd allow the tailnet). One tailnet carries both: an admin's laptop is
an ops machine and keeps reaching providers. What that relies on:

- the CNC is a DNS name with a public certificate, and no machine trusts a
  root of connector's;
- headscale is a pinned release, and the policy a site writes is its own and
  can never open a prod machine;
- prod keys are minted by `prod-key` alone, and reach a machine on stdin;
- the CNC's state has an encrypted backup whose private key is not on it,
  taken every day (`backup-schedule`);
- the CNC's own host is held by codespace's provisioning, as any prod host is
  (`cnc host provision --role headscale`, codespace-cloud's docs/nodes.md, "The
  tailnet's own host"): its firewall lets headscale's ports in from anyone and
  ssh from the tailnet alone, sshd takes a named admin's keys from the tailnet,
  and it patches itself, rebooting for a kernel at 04:30.

**Exit criterion.** This mesh has one admin. The day connector gets a second
admin, or users from outside, prod moves to a headscale of its own: the
codespace provisioning takes the login server as a parameter, so moving is a
re-join of each prod machine (a fresh `prod-key` from the new headscale), not
a rebuild; then the `tag:prod` rules leave this site's policy.

## Topology

```
        local manager (admin laptop)
        drives the CNC over the admin's own SSH
                       │
                       │  connector invite / approve / list / revoke
                       ▼
   ┌─────────────────────────────────────────┐
   │ VPS = CNC  (a DNS name)                  │
   │  headscale (systemd)  HTTPS :443         │
   │   Let's Encrypt cert, renewed in-process │
   │  embedded DERP relay  STUN :3478         │
   │  ACL policy: tag:provider / tag:consumer │
   │              + Tailscale SSH rules       │
   └─────────────────────────────────────────┘
            ▲                         ▲
            │ coordination            │ coordination
            │                         │
   ┌────────┴────────┐       ┌────────┴─────────┐
   │ consumer node   │──────▶│ provider node    │
   │ tailscale up    │ direct│ tailscale up     │
   │ tag:consumer    │  P2P  │ tag:provider --ssh│
   └─────────────────┘ (DERP │ (WSL or Linux)   │
                       fallback)─────────────────┘
        ssh provider-name  (MagicDNS, ACL-gated)
```

- The CNC is the **control plane** and a **DERP relay**. For direct connections
  it is *not* in the data path; peers talk P2P and fall back to DERP only when a
  direct path can't be established.
- Tailnet IPs (`100.64.0.0/10`) and MagicDNS names are assigned automatically by
  headscale. There is no manual IP allocation.

## Onboarding (always admin-gated)

There is **no auto-join and no shared reusable key**. Two paths, both controlled
by the admin:

1. **Invite (streamlined).** Admin runs `connector invite` on the CNC (or from a
   linked manager, proxied over SSH). It mints a **single-use, short-expiry**
   pre-auth key (`headscale preauthkeys create … --expiration 1h`) carrying the
   chosen tags, and prints the exact `connector register …` command to hand to
   that one machine. The key dies after one use / expiry, so it is not a secret
   to protect long-term.

2. **Approve (manual review).** A machine runs `connector register …` with no
   key and shows up in `headscale nodes list`. The admin reviews it and runs
   `connector approve <node> <type>` to tag/approve that **specific** node.
   Never "approve all".

`finalize` from the old tool is gone: after a successful `register`, the node is
already connected. `register` hands the key to `tailscale up` in a 0600 file
(`--auth-key file:…`), never on its command line, where any local user's `ps`
would see it; `--authkey -` reads it from stdin.

### Operators' machines (ops)

`connector invite ops [name]` mints a key for headscale user `ops` with no
tag: the machine is that user's, so it is in `group:ops`, and the site's
policy (below) lets it reach prod machines on ssh and https, and what a
consumer reaches. `ops` is a machine of its own: a tag would make it the
tag's, not the user's, so it is never combined with provider or consumer.

### Prod machines (tag:prod)

A prod machine (the codespace control plane, a codespace node) joins the
admin tailnet as `tag:prod`, and its key is minted by **`connector prod-key`
alone** -- `invite` and `approve` refuse `prod` and any `tag:` -- by an admin
(a CNC or manager), after a confirmation:

- single-use, `tag:prod` and no other tag (a prod machine that were also a
  consumer would be granted what consumers are), owned by the operators
  (`tagOwners`: `group:ops`);
- expiring within the hour (`--expiration` 1m..60m or 1h);
- printed once, to stdout and nothing else there, so it pipes straight into
  the prod machine's join, which reads it on stdin and never puts it on a
  command line: `connector prod-key | ssh <host> 'sudo <join reading stdin>'`;
  or `--out FILE`, a new 0600 file (never written over one).

### Manager invites

A manager commands the CNC over SSH, so promoting one is the single place
where SSH-key handling remains. `connector invite` → option `[3]` (only shown to
a cnc/manager) authorizes the invitee's SSH public key on the CNC admin
account and prints the `connector link …` command for them. The invitee gets
their key via `connector manager-key`. Revoking a manager = removing that
key from the CNC admin's `authorized_keys`.

## Admin-command routing

`invite`, `approve`, `list`, `revoke`, and `cleanup-cnc` go through one helper:

1. if this machine **is the CNC** → run `headscale …` locally (via sudo);
2. else if it **is a manager** → `ssh <CNC> [sudo] headscale …` and relay output;
3. else → fail with guidance to `cnc-init` or `link` a CNC.

Interactive prompts (the invite menu, etc.) happen locally; only concrete
commands are sent to the CNC.

## Putting connector on another machine

`cnc-init <host>`, `cnc-update` and `propagate-update` copy this machine's
connector to the CNC or a provider: into a directory of its own there --
`mktemp -d`, made by that machine and the login user's alone, whose path is
checked before anything is copied -- then install it from there as
`/usr/local/bin/connector` (and `con`) and remove the directory in the same
command, whatever happened. Never a fixed name in `/tmp`, which anyone on that
host could make first, or swap before root installs what it holds.

## ACL policy

headscale reads `/etc/headscale/acl.hujson`, which connector composes from two
parts, and writes only when the result passes the guards below and headscale's
`configtest` (otherwise the policy before stays):

- **connector's own rules** (`render_acl`), the same on every CNC:

  ```json
  {
    "tagOwners": { "tag:provider": ["mesh@"], "tag:consumer": ["mesh@"] },
    "acls": [ { "action": "accept", "src": ["tag:consumer"], "dst": ["tag:provider:*"] } ],
    "ssh":  [ { "action": "accept", "src": ["tag:consumer"], "dst": ["tag:provider"],
                "users": ["autogroup:nonroot"] } ]
  }
  ```

- **the site's own rules**, `/etc/headscale/acl.site.json` (strict JSON):
  written once, where there is none, and never overwritten by `cnc-init`, an
  update or anything else -- the site edits it. Its groups, tagOwners and
  hosts join connector's (the site's winning a name both use); its acls and
  ssh rules follow connector's. The default is the operators':

  ```json
  {
    "groups": { "group:ops": ["ops@"] },
    "tagOwners": { "tag:prod": ["group:ops"] },
    "acls": [
      { "action": "accept", "src": ["group:ops"], "dst": ["tag:prod:22,443"] },
      { "action": "accept", "src": ["group:ops"], "dst": ["tag:provider:*"] }
    ],
    "ssh": [ { "action": "accept", "src": ["group:ops"], "dst": ["tag:provider"],
               "users": ["autogroup:nonroot"] } ]
  }
  ```

  An operator's machine (an untagged machine of headscale user `ops`) reaches
  a prod machine (`tag:prod`) on ssh and https, and what a consumer reaches.

Whatever the site writes, the composed policy is refused when it grants a prod
machine anything (an acl whose source is a `tag:prod…` tag, `*` or
`autogroup:tagged`), or gives anyone Tailscale SSH to one (an ssh rule whose
destination is one of those): a prod machine is only ever a destination, and
OpenSSH keys stay the way in. Note: headscale policy v2 (0.26+) requires
usernames to be written with a trailing `@` (`mesh@` is the user `mesh`).

Tailnet membership is already gated at join time (invite key / approve), so
network access here is a static, tag-based policy instead of per-host
`sshd_config`/`authorized_keys` edits. Switching an SSH rule to
`"action": "check"` additionally requires re-auth per SSH session.

## TLS / control URL

Tailscale clients require HTTPS to the control server, and verify it against
the public roots their OS already has. The CNC is therefore a **DNS name**,
and headscale gets that name's certificate from Let's Encrypt itself (ACME)
and renews it in-process -- no certbot, no proxy, no cron:

```
connector cnc-init root@203.0.113.1 --url https://vpn.example.com   # A record -> 203.0.113.1
```

- **`--acme tls-alpn-01`** (the default): the challenge is answered on the
  TLS listener itself, so headscale serves `:443` and nothing else needs to.
- **`--acme http-01`**: answered on `:80` (headscale binds it for the
  challenge), for when `:443` belongs to something else; the control port is
  then the one in `--url` (`https://vpn.example.com:8443`).

`cnc-init` refuses to bind over a port another process already holds (it
would take the control plane down), warns when the name does not resolve to
the machine (Let's Encrypt validates at whatever it resolves to), and needs a
URL of exactly `https://<name>[:port]`. It puts a new config and policy in
place only if `headscale configtest` takes them (which reads the policy too):
the ones before are kept as `*.prev` and put back otherwise, and headscale is
never restarted onto what it refuses.

**connector installs no trust root on any machine.** An older connector
served a bare IP (`https://<ip>:8443`) with a self-signed **CA:TRUE**
certificate and made every node trust it as a root (the macOS System
keychain, the Linux CA store): whoever held its key could pass for any site
to all of them. That mode is gone -- `cnc-init`, `register` and `link` refuse
an address -- and `cleanup` and `migrate-cnc` (below) remove the old root:
that certificate, matched by its SHA-256 and nothing else (on macOS every
certificate in the System keychain is hashed and only the match is deleted,
with its trust setting; on Linux only a file connector wrote that holds that
certificate is removed, and the store is rebuilt).

## Moving the CNC to a new name

A CNC moves once from an older connector's bare IP to its DNS name (or from
one name to another), and every node follows it:

1. **DNS**: an A record for the new name pointing at the CNC.
2. **The CNC**: from the admin's manager, `connector cnc-init <ssh-host> --url
   https://<name>` (it asks before moving a CNC that already serves another
   URL). headscale keeps its database, keys and nodes; only the URL, its
   certificate (Let's Encrypt, on first connection) and the port change.
   Tunnels between nodes keep working; until a node follows, its control
   plane is the old URL, which no longer answers.
3. **Each node**: the admin runs `connector invite --migrate <roles> <node>`
   (a fresh single-use key) and the node runs what it prints:
   `connector migrate-cnc https://<name> --authkey KEY --old-sha256 FP`.
   It re-joins with `--force-reauth` (tailscale will not change its login
   server otherwise) as the roles it registered with and the tailnet
   hostname it had -- headscale knows the machine, so it keeps its node and
   address -- then stops trusting the old root: the certificate whose SHA-256
   the CNC still holds (`/var/lib/headscale/certs/cnc.crt`), which must agree
   with the one the node recorded; nothing changes when they differ. A
   manager's link moves to the new URL too. Run again, it re-joins nothing
   and removes nothing that is already gone.
4. **Last**: once every node has followed, remove the old certificate from
   the CNC (`/var/lib/headscale/certs/`).

## Backups

```
connector backup --recipient age1...            # a manager: a new 0600 headscale-<UTC>.tar.age here
connector restore headscale-<UTC>.tar.age --identity ~/.config/age/admin.key
connector backup-schedule --recipient age1...   # the CNC backs itself up every day
```

A backup is the CNC's state -- headscale's database (a consistent copy,
`sqlite3 .backup`, taken while it runs), its noise and DERP keys (the
server's identity to every node), the Let's Encrypt cache, its config,
policy and the site's rules -- as a tar encrypted **on the CNC** with `age` to
public keys alone: `--recipient` (an `age1…` key or an `ssh-ed25519` one) and
those listed in `/etc/headscale/backup.recipients`. The private half never
needs to be on the CNC, and a secret key passed by mistake is refused. age
itself takes every recipient before any of the state is copied, and the copy
staged in the clear (root's, under `mktemp -d`) is removed however the backup
ends. From a manager it streams over SSH into a new 0600 file (never over one,
and only if what came is an age file).

`backup-schedule` has the CNC take one every day itself (`connector-backup.timer`,
a random hour after midnight, and a day the CNC was down for once it is up):
the same archive, encrypted to the recipients it names -- written to
`backup.recipients`, or, with none given, those already listed -- into a new
0600 file in `/var/backups/headscale` (0700), the newest 14 kept (`--keep N`)
by the time in their names, so a day whose backup failed deletes none.
`--off` stops it and leaves the backups. Its units are rewritten by `cnc-init`
and `cnc-update` as the connector they install writes them, and never put in by
either. Copies off the CNC are the admin's: `scp` the newest from
`/var/backups/headscale`, or a manager's `connector backup` (cron, say). A
recipient is checked on the machine it is typed on, so a private key passed
by mistake never reaches the CNC; and a schedule is put in only for
recipients age takes, so a typo is refused then, not every day after.

A restore is decrypted where the private key is -- the admin's machine -- and
streamed to the CNC over SSH. The CNC takes only what a backup holds (files
and directories under `/var/lib/headscale` and `/etc/headscale`, no link, no
`..`), stops headscale, keeps its current state aside
(`/var/lib/headscale.before-restore-<UTC>`, its `/etc/headscale` files in
`etc/` within), puts the backup's in place and starts headscale only if
`headscale configtest` takes it -- otherwise the state before is put back and
started. A fresh CNC restores the same way after `cnc-init` (same name).

## The headscale release

connector installs one headscale release, pinned in the script:
`HEADSCALE_VERSION` and the sha256 of each artifact it installs (the `.deb`
on apt hosts, the binary elsewhere; amd64 and arm64). `cnc-init` downloads
it, checks it against its pinned sha256 before anything is installed, and
puts it in over an older one; a headscale newer than the pin is never
downgraded -- its database has moved on. A release is a pin bump: the version
and the sha256s from the release's `checksums.txt`, each artifact hashed
again, and the docker tier's image (`test/helpers.bash`) at the same version.
Read headscale's upgrade notes for every minor release in between, and take
a backup first (`connector backup`).

## Linux nodes: where tailscale comes from

`register` installs tailscale from **tailscale's apt repository** on Debian,
Ubuntu, Raspbian and their derivatives (by the distribution they are like,
`/etc/os-release`): the key is fetched from pkgs.tailscale.com and checked to
be the one pinned in connector (`2596A99EAAB33821893C0A79458CA832957F5868`,
"Tailscale Inc. (Package repository signing key)") and no other before apt
is told of the repository, and the source names that keyring alone
(`signed-by`), so it vouches for tailscale's packages and nothing else; apt
then verifies what it installs. Arch, Alpine, openSUSE and Fedora install
their own distribution's package. connector never pipes a script to a shell.

## WSL specifics (auto-handled)

`register` detects WSL and:
- if systemd is **not** PID 1, **asks** before adding `[boot] systemd=true` to
  `/etc/wsl.conf` (idempotent; `--yes` skips the prompt), then tells you to
  `wsl --shutdown` and re-run;
- pins the `tailscale0` MTU to 1280 **only if** the current value is larger,
  avoiding large-packet drops over WSL's NAT.

## macOS clients (auto-handled)

`register` detects macOS and supports both Tailscale variants:
- **GUI app** (Homebrew cask `tailscale` or tailscale.com download) — its CLI is
  `/Applications/Tailscale.app/Contents/MacOS/Tailscale`, driven without `sudo`.
- **open-source `tailscaled`** (Homebrew formula `tailscale`, started via
  `sudo brew services start tailscale`) — driven with `sudo`.

If both are present it asks which to use; if neither, it asks which to install
(`--tailscale app|oss` skips the prompt).

## State & files

| Location                               | Purpose                                    |
|----------------------------------------|--------------------------------------------|
| `/etc/headscale/config.yaml`           | CNC: headscale config (written by `cnc-init`) |
| `/etc/headscale/acl.hujson`            | CNC: the policy headscale reads (composed) |
| `/etc/headscale/acl.site.json`         | CNC: the site's own rules (never overwritten) |
| `/etc/headscale/backup.recipients`     | CNC: public keys a backup is encrypted to (optional) |
| `/var/backups/headscale/`              | CNC: its daily backups (`backup-schedule`), 0700, each 0600 |
| `/etc/systemd/system/connector-backup.{service,timer}` | CNC: the daily backup (`backup-schedule`) |
| `/var/lib/headscale/`                  | CNC: keys + sqlite DB                      |
| `/var/lib/headscale/cache/`            | CNC: headscale's Let's Encrypt account + certificate |
| `/var/lib/headscale/certs/`            | CNC: an older connector's self-signed `cnc.crt` (until removed) |
| `~/.config/connector/cnc`             | manager: linked CNC (`CNC_SSH/URL/PORT/USER`; 0600, read as `KEY=VALUE` text and never sourced -- any other line is refused) |
| `~/.config/connector/role`            | node: last registered role (provider/…)    |
| `~/.config/connector/cnc-ca.crt`      | node: an older connector's trusted CNC cert (`cleanup`/`migrate-cnc` remove it) |
| `~/.config/connector/aliases.conf`    | saved `connector <name>` SSH shortcuts     |
| `~/.ssh/config`                       | optional Host entries written by `alias`   |

The only persisted manager secret is the SSH access it already has to the
CNC. Everything else is read live from headscale/tailscale.

## Ports (open INBOUND on the CNC)

| Port         | Use                                          |
|--------------|----------------------------------------------|
| 443/tcp      | headscale control + DERP (HTTPS, Let's Encrypt; another port with `--acme http-01`) |
| 80/tcp       | only with `--acme http-01`: the ACME challenge |
| 3478/udp     | STUN (NAT traversal)                         |
| 41641/udp    | tailscale direct connections                 |

`cnc-init` does **not** enable a host firewall (lockout risk). It opens these
ports only on an already-active ufw/firewalld, and after a remote `cnc-init` it
probes the control port from your machine and **asks** you to open any cloud
firewall (e.g. DigitalOcean) if it's unreachable. The prod CNC's host
firewall, and DigitalOcean's in front of it, are codespace's (`cnc host
provision --role headscale`; `providers/digitalocean.sh --role headscale`):
these ports from anyone, ssh from the tailnet alone.

## Migration from the old WireGuard connector

This is a greenfield cut-over. After moving to headscale/tailscale, tear down
leftover state from the previous design (the relevant commands are printed by
`connector cleanup-cnc`):

- `wg-quick@wg-connector` service + `/etc/wireguard/wg-connector.conf`
- the `/var/lib/wsl-registry/` registry tree
- the `connector` staging user
- any `Match User connector` blocks in `/etc/ssh/sshd_config`

## References

- headscale — https://github.com/juanfont/headscale
- Tailscale ACLs — https://tailscale.com/kb/1018/acls
- Tailscale SSH — https://tailscale.com/kb/1193/tailscale-ssh
- DERP — https://tailscale.com/kb/1232/derp-servers
- WSL systemd — https://learn.microsoft.com/windows/wsl/systemd
