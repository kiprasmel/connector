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

A machine can hold several roles at once (a laptop is usually controller +
consumer). `connector` detects them from cheap, local state:

| Role           | Detected by                                             | Can do                                  |
|----------------|---------------------------------------------------------|-----------------------------------------|
| **cnc**        | `headscale` binary present **and** `/etc/headscale/config.yaml` exists | runs admin commands locally |
| **controller** | a saved link at `~/.config/connector/cnc`               | runs admin commands on the CNC over SSH |
| **provider**   | local role file says `provider`/`both` (`tag:provider`) | accepts Tailscale SSH                   |
| **consumer**   | local role file says `consumer`/`both` (`tag:consumer`) | initiates SSH to providers              |

`connector whoami` prints the detected set; `connector status` shows it too.

Only a **cnc or controller** may invite or approve machines, or promote a new
controller. A plain provider/consumer has no admin authority.

## Topology

```
        local controller (admin laptop)
        drives the CNC over the admin's own SSH
                       │
                       │  connector invite / approve / list / revoke
                       ▼
   ┌─────────────────────────────────────────┐
   │ VPS = CNC                                │
   │  headscale (systemd)  HTTPS :443         │
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
   linked controller, proxied over SSH). It mints a **single-use, short-expiry**
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

### Controller (C&C commander) invites

A controller commands the CNC over SSH, so promoting one is the single place
where SSH-key handling remains. `connector invite` → option `[3]` (only shown to
a cnc/controller) authorizes the invitee's SSH public key on the CNC admin
account and prints the `connector link …` command for them. The invitee gets
their key via `connector commander-key`. Revoking a controller = removing that
key from the CNC admin's `authorized_keys`.

## Admin-command routing

`invite`, `approve`, `list`, `revoke`, and `cleanup-cnc` go through one helper:

1. if this machine **is the CNC** → run `headscale …` locally (via sudo);
2. else if it **is a controller** → `ssh <CNC> [sudo] headscale …` and relay output;
3. else → fail with guidance to `cnc-init` or `link` a CNC.

Interactive prompts (the invite menu, etc.) happen locally; only concrete
commands are sent to the CNC.

## ACL policy (`/etc/headscale/acl.hujson`)

```hujson
{
  "tagOwners": { "tag:provider": ["mesh"], "tag:consumer": ["mesh"] },
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

`cnc-init --url https://host` configures headscale's built-in Let's Encrypt via
`tls_letsencrypt_hostname` (`TLS-ALPN-01` challenge by default). A reachable DNS
name for the VPS is strongly recommended.

Fallbacks if you can't use ALPN/Let's Encrypt:
- switch `tls_letsencrypt_challenge_type` to `HTTP-01` (needs :80 reachable);
- terminate TLS at a reverse proxy and point `server_url` at it;
- for IP-only/lab use, set `tls_cert_path`/`tls_key_path` to your own cert, or
  pass a plain `http://…` URL (clients then need their own TLS-terminating proxy).

## WSL specifics (auto-handled)

`register` detects WSL and:
- if systemd is **not** PID 1, **asks** before adding `[boot] systemd=true` to
  `/etc/wsl.conf` (idempotent; `--yes` skips the prompt), then tells you to
  `wsl --shutdown` and re-run;
- pins the `tailscale0` MTU to 1280 **only if** the current value is larger,
  avoiding large-packet drops over WSL's NAT.

## State & files

| Location                               | Purpose                                    |
|----------------------------------------|--------------------------------------------|
| `/etc/headscale/config.yaml`           | CNC: headscale config (written by `cnc-init`) |
| `/etc/headscale/acl.hujson`            | CNC: tag/SSH ACL policy                    |
| `/var/lib/headscale/`                  | CNC: keys + sqlite DB                      |
| `~/.config/connector/cnc`             | controller: linked CNC (`CNC_SSH/URL/PORT`)|
| `~/.config/connector/role`            | node: last registered role (provider/…)    |
| `~/.config/connector/aliases.conf`    | saved `connector <name>` SSH shortcuts     |
| `~/.ssh/config`                       | optional Host entries written by `alias`   |

The only persisted controller secret is the SSH access it already has to the
CNC. Everything else is read live from headscale/tailscale.

## Ports (open on the CNC)

| Port        | Use                                   |
|-------------|---------------------------------------|
| 443/tcp     | headscale control + DERP (HTTPS)      |
| 3478/udp    | STUN (NAT traversal)                  |
| 41641/udp   | tailscale direct connections          |

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
