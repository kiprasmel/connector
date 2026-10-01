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

`connector whoami` prints the detected set; `connector status` shows it too.

Only a **cnc or manager** may invite or approve machines, or promote a new
manager. A plain provider/consumer has no admin authority.

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
already connected.

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

## ACL policy (`/etc/headscale/acl.hujson`)

Note: headscale policy v2 (0.26+) requires usernames to be written with a
trailing `@` (the owner `mesh@` refers to the user registered as `mesh`).

```hujson
{
  "tagOwners": { "tag:provider": ["mesh@"], "tag:consumer": ["mesh@"] },
  "acls": [
    { "action": "accept", "src": ["tag:consumer"], "dst": ["tag:provider:*"] }
  ],
  "ssh": [
    { "action": "accept", "src": ["tag:consumer"], "dst": ["tag:provider"],
      "users": ["autogroup:nonroot"] }
  ]
}
```

Tailnet membership is already gated at join time (invite key / approve), so
network access here is a static, tag-based policy instead of per-host
`sshd_config`/`authorized_keys` edits. Switching the SSH rule to
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
an address -- and `cleanup` removes the old root: that certificate, matched
by its SHA-256 and nothing else (on macOS every
certificate in the System keychain is hashed and only the match is deleted,
with its trust setting; on Linux only a file connector wrote that holds that
certificate is removed, and the store is rebuilt).

## The headscale release

connector installs one headscale release, pinned in the script:
`HEADSCALE_VERSION` and the sha256 of each artifact it installs (the `.deb`
on apt hosts, the binary elsewhere; amd64 and arm64). `cnc-init` downloads
it, checks it against its pinned sha256 before anything is installed, and
puts it in over an older one; a headscale newer than the pin is never
downgraded -- its database has moved on. A release is a pin bump: the version
and the sha256s from the release's `checksums.txt`, each artifact hashed
again, and the docker tier's image (`test/helpers.bash`) at the same version.
Read headscale's upgrade notes for every minor release in between, and copy
`/var/lib/headscale` first.

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
| `/etc/headscale/acl.hujson`            | CNC: tag/SSH ACL policy                    |
| `/var/lib/headscale/`                  | CNC: keys + sqlite DB                      |
| `/var/lib/headscale/cache/`            | CNC: headscale's Let's Encrypt account + certificate |
| `/var/lib/headscale/certs/`            | CNC: an older connector's self-signed `cnc.crt` (until removed) |
| `~/.config/connector/cnc`             | manager: linked CNC (`CNC_SSH/URL/PORT`)|
| `~/.config/connector/role`            | node: last registered role (provider/…)    |
| `~/.config/connector/cnc-ca.crt`      | node: an older connector's trusted CNC cert (`cleanup` removes it) |
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
firewall (e.g. DigitalOcean) if it's unreachable.

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
