# Architecture Documentation

## System Overview

The WireGuard VPS-WSL Connector is a self-service registration system that allows WSL (Windows Subsystem for Linux) machines to connect to a central VPS through WireGuard VPN tunnels.

## Design Goals

1. **Simplicity**: Single executable handles all operations
2. **Security**: Admin approval required, unique keys per machine
3. **Self-Service**: WSL users can register without VPS access
4. **Automation**: Minimal manual configuration required
5. **Multi-Client**: Support multiple WSL instances simultaneously

## Network Topology

```
                         Internet
                            │
                            │
                    ┌───────▼────────┐
                    │   VPS Server   │
                    │  10.0.0.1/24   │
                    │  UDP:51820     │
                    └───────┬────────┘
                            │
                    WireGuard Tunnel
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
   ┌────▼─────┐       ┌────▼─────┐       ┌────▼─────┐
   │   WSL 1  │       │   WSL 2  │       │   WSL 3  │
   │ 10.0.0.2 │       │ 10.0.0.3 │       │ 10.0.0.4 │
   │  SSH:22  │       │  SSH:22  │       │  SSH:22  │
   └──────────┘       └──────────┘       └──────────┘
```

### IP Allocation

- **VPS**: 10.0.0.1/24 (WireGuard server)
- **Clients**: 10.0.0.2, 10.0.0.3, 10.0.0.4, ... (auto-assigned)
- **Subnet**: 10.0.0.0/24 (256 addresses available)

### Ports

- **WireGuard**: UDP 51820 (VPS must be accessible from internet)
- **SSH**: TCP 22 (accessible only via WireGuard tunnel)

## Components

### 1. Connector Tool

Single bash script (`connector`) that handles all operations:

**VPS Operations:**
- `vps-init`: Initialize VPS as WireGuard server
- `approve`: Approve pending machine registrations
- `list`: List all connected machines
- `revoke`: Revoke machine access

**WSL Operations:**
- `register`: Register WSL to VPS
- `finalize`: Complete setup after approval
- `status`: Check connection status

### 2. Registry System

Directory structure on VPS:

```
/var/lib/wsl-registry/
├── pending/              # Pending registrations (writable by staging user)
│   └── wsl-abc123.json
├── approved/             # Approved machines (root only)
│   └── wsl-abc123.json
├── configs/              # Client configs (readable for download)
│   └── wsl-abc123.conf
└── revoked/              # Revoked machines (audit trail)
    └── wsl-xyz789.json
```

### 3. Staging User

Special user account `connector`:
- Purpose: Accept registration uploads
- Permissions: Write-only to `pending/` directory
- Authentication: Password-based (shared with WSL users)
- Shell: Limited (cannot execute commands)

### 4. WireGuard Configuration

**Server Config** (`/etc/wireguard/wg0.conf`):
```ini
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = <server_private_key>
PostUp = iptables rules for NAT/forwarding
PostDown = cleanup rules

[Peer]  # Added for each approved client
PublicKey = <client_public_key>
AllowedIPs = 10.0.0.X/32
```

**Client Config** (`/etc/wireguard/wg0.conf` on WSL):
```ini
[Interface]
Address = 10.0.0.X/32
PrivateKey = <client_private_key>
DNS = 1.1.1.1

[Peer]
PublicKey = <server_public_key>
Endpoint = <vps_ip>:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
```

## Data Flow

### Registration Flow

```
WSL Machine                    VPS Server
    │                              │
    │  1. Generate keys            │
    │  (WireGuard + SSH)           │
    │                              │
    │  2. Create registration      │
    │  JSON with metadata          │
    │                              │
    │  3. Upload via SCP           │
    ├─────────────────────────────>│
    │  (using staging user)        │
    │                              │  4. JSON saved to pending/
    │                              │
    │  5. Wait for approval        │
    │                              │
```

### Approval Flow

```
VPS Admin                     VPS Server
    │                             │
    │  1. List pending            │
    │<────────────────────────────┤
    │                             │
    │  2. Select machine          │
    ├────────────────────────────>│
    │                             │
    │                             │  3. Allocate IP (10.0.0.X)
    │                             │
    │                             │  4. Add [Peer] to wg0.conf
    │                             │
    │                             │  5. Reload WireGuard
    │                             │
    │                             │  6. Add SSH key to authorized_keys
    │                             │
    │                             │  7. Generate client config
    │                             │
    │                             │  8. Move to approved/
    │                             │
    │  9. Display token           │
    │<────────────────────────────┤
    │                             │
```

### Finalization Flow

```
WSL Machine                    VPS Server
    │                              │
    │  1. Request config           │
    ├─────────────────────────────>│
    │  (using staging user + token)│
    │                              │  2. Validate token
    │                              │
    │  3. Download wg0.conf        │
    │<─────────────────────────────┤
    │                              │
    │  4. Install config           │
    │  to /etc/wireguard/          │
    │                              │
    │  5. Enable systemd services  │
    │  (wg-quick@wg0, sshd)        │
    │                              │
    │  6. Start WireGuard          │
    │                              │
    │  7. Establish tunnel         │
    │<────────────────────────────>│
    │  WireGuard handshake         │
    │                              │
    │  8. Test connectivity        │
    │  (ping 10.0.0.1)             │
    │                              │
```

## Data Structures

### Registration JSON

```json
{
  "machine_id": "wsl-abc12345",
  "timestamp": "2025-11-25T10:00:00Z",
  "hostname": "my-laptop",
  "username": "john",
  "wg_pubkey": "base64_encoded_wireguard_public_key",
  "ssh_pubkey": "ssh-ed25519 AAAAC3... john@wsl",
  "request_note": "WSL machine registration"
}
```

### Approved Machine JSON

```json
{
  "machine_id": "wsl-abc12345",
  "timestamp": "2025-11-25T10:00:00Z",
  "approved_at": "2025-11-25T10:05:00Z",
  "hostname": "my-laptop",
  "username": "john",
  "wg_ip": "10.0.0.2",
  "wg_pubkey": "base64_encoded_wireguard_public_key",
  "ssh_pubkey": "ssh-ed25519 AAAAC3... john@wsl",
  "request_note": "WSL machine registration"
}
```

## Security Model

### Threat Model

**Protected Against:**
- Unauthorized machine registration (requires admin approval)
- Key compromise (unique keys per machine)
- Man-in-the-middle (WireGuard encryption)
- Lateral movement (isolated VPN subnet)

**Attack Vectors:**
- Staging password compromise (can upload fake registrations)
- VPS compromise (full system access)
- Physical access to WSL machine

### Security Measures

1. **Separation of Duties**
   - WSL users can register but not approve
   - Admin approval required for network access
   - Staging user has minimal permissions

2. **Cryptographic Security**
   - WireGuard: Noise protocol framework
   - SSH: ed25519 keys (modern, secure)
   - All keys generated locally

3. **Network Isolation**
   - Each client isolated with AllowedIPs
   - No direct internet access via VPN (by default)
   - SSH only accessible via WireGuard tunnel

4. **Audit Trail**
   - All registrations logged with timestamps
   - Approved/revoked machines tracked
   - JSON files provide audit history

5. **Minimal Attack Surface**
   - Only UDP 51820 exposed on VPS
   - Staging user cannot execute commands
   - Write-only pending directory

### Best Practices

1. **Rotate staging password regularly**
2. **Monitor pending directory for suspicious registrations**
3. **Review approved machines periodically** (`connector list`)
4. **Revoke unused machines** (`connector revoke`)
5. **Backup `/var/lib/wsl-registry/` regularly**
6. **Keep WireGuard updated** on all systems

## Systemd Integration

### VPS Services

- `wg-quick@wg0.service`: WireGuard server
  - Enabled: Auto-start on boot
  - Manages interface and routing

### WSL Services

- `wg-quick@wg0.service`: WireGuard client
  - Enabled: Auto-start when systemd initializes
  - Connects to VPS automatically

- `sshd.service`: SSH daemon
  - Enabled: Auto-start when systemd initializes
  - Listens on port 22 (WireGuard interface)

### WSL Boot Process

```
Windows starts WSL
       │
       ▼
/etc/wsl.conf loaded
       │
       ▼
systemd enabled? ──No──> Traditional init
       │
      Yes
       ▼
systemd starts
       │
       ├─> wg-quick@wg0.service
       │   └─> Establishes WireGuard tunnel
       │
       └─> sshd.service
           └─> SSH server ready
```

## IP Allocation Algorithm

```python
def get_next_ip():
    max_ip = 1  # Start from .2 (VPS is .1)
    
    for each file in approved/:
        ip = extract_ip_from_json(file)
        last_octet = ip.split('.')[-1]
        if last_octet > max_ip:
            max_ip = last_octet
    
    return f"10.0.0.{max_ip + 1}"
```

This ensures:
- Sequential IP assignment
- No conflicts
- Simple to understand
- Recovers from deletions

## Error Handling

### Registration Errors

- **Network failure**: Retry with manual SCP
- **Permission denied**: Check staging password
- **Keys exist**: Reuse existing keys

### Approval Errors

- **Invalid JSON**: Skip and warn admin
- **IP exhaustion**: Fail with clear message
- **WireGuard reload fails**: Rollback changes

### Finalization Errors

- **Config download fails**: Check token and connectivity
- **systemd not available**: Warn user to restart WSL
- **Tunnel won't connect**: Check firewall and VPS status

## Performance Considerations

### Scalability

- **Client Limit**: 254 clients (10.0.0.2 - 10.0.0.255)
- **WireGuard Overhead**: ~4% (minimal CPU/bandwidth impact)
- **JSON Parsing**: O(n) for listing machines

### Optimization

- Use `wg syncconf` instead of full restart (zero downtime)
- JSON files are small (< 1KB each)
- No database required (filesystem is sufficient)

## Future Enhancements

Possible improvements:

1. **Web Interface**: Browser-based approval workflow
2. **Automatic Revocation**: Remove inactive machines after X days
3. **Multi-VPS**: Support federation of multiple VPS servers
4. **IPv6 Support**: Dual-stack configuration
5. **Metrics**: Bandwidth and connection statistics
6. **Notifications**: Email/webhook on registration
7. **Key Rotation**: Automatic key rotation for machines

## Comparison with Alternatives

### vs Traditional VPN (OpenVPN)

**Advantages:**
- Faster (WireGuard is significantly faster)
- Simpler configuration
- Modern cryptography
- Better NAT traversal

**Disadvantages:**
- Less mature (OpenVPN has 20+ years)
- Fewer client options

### vs Tailscale/ZeroTier

**Advantages:**
- Self-hosted (no third-party)
- Full control over infrastructure
- No account registration
- Simple architecture

**Disadvantages:**
- More manual setup
- No built-in relay servers
- Requires public VPS

### vs Direct SSH

**Advantages:**
- Persistent VPN tunnel
- Multiple services (not just SSH)
- Better for WSL (stable IPs)
- Network-level access

**Disadvantages:**
- More complex setup
- Additional moving parts
- Requires WireGuard installation

## References

- [WireGuard Official Site](https://www.wireguard.com/)
- [WireGuard Protocol Paper](https://www.wireguard.com/papers/wireguard.pdf)
- [systemd Documentation](https://www.freedesktop.org/wiki/Software/systemd/)
- [WSL Documentation](https://docs.microsoft.com/en-us/windows/wsl/)
