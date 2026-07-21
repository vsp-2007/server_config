# Pangolin VPN Setup Guide for Pi Server Setup v3

**Website:** https://pangolin.net/  
**Documentation:** https://pangolin.net/docs  
**Admin Console:** https://pangolin.net/admin

---

## Overview

Pangolin is a zero-configuration VPN alternative to Tailscale, built on WireGuard. It provides:
- **MagicDNS** - Automatic hostname resolution across your network
- **Exit Nodes** - Route traffic through your home server
- **Subnet Routes** - Access your LAN from anywhere
- **Global Nameservers** - Use your Pi-hole for DNS anywhere
- **Device Management** - Web-based admin console

---

## Prerequisites

1. A Pangolin account (free for personal use)
2. Internet connection on the target machine
3. Root/sudo access

---

## Step 1: Create Pangolin Account

1. Go to https://pangolin.net/
2. Click "Sign Up" and create an account
3. Verify your email address

---

## Step 2: Generate Auth Key (for unattended setup)

1. Log into https://pangolin.net/admin
2. Navigate to **Settings** → **Auth Keys**
3. Click **Generate Auth Key**
4. Configure:
   - **Name:** `InitOps` (or descriptive name)
   - **Expiry:** No expiry (or set as needed)
   - **Reusable:** Yes (allows re-authentication)
   - **Ephemeral:** No (keep device registered)
   - **Pre-authorized:** Yes (auto-approve device)
   - **Tags:** `tag:pi-server` (optional, for ACL organization)
5. Copy the generated key (starts with `pg-` or similar)

**Add to settings.conf:**
```bash
PANGOLIN_AUTH_KEY="pg-your-auth-key-here"
PANGOLIN_EXIT_NODE="false"
PANGOLIN_HOSTNAME="pi-server"  # Optional custom hostname
```

---

## Step 3: Configure Exit Node (Optional)

To use your Pi as an exit node (route all traffic through home):

1. In `settings.conf`:
   ```bash
   PANGOLIN_EXIT_NODE="true"
   ```

2. After installation, enable in admin console:
   - Go to https://pangolin.net/admin/machines
   - Find your Pi device
   - Click **...** → **Edit route settings**
   - Enable **Use as exit node**
   - Save

3. On client devices:
   - Pangolin app → **Exit Node** → Select your Pi

---

## Step 4: Configure Subnet Routes (Access LAN from VPN)

The script auto-detects your LAN subnet and advertises it. To verify:

1. Go to https://pangolin.net/admin/machines
2. Find your Pi device
3. Check **Advertised routes** - should show your LAN (e.g., `192.168.1.0/24`)
4. If missing, click **Edit route settings** → Add your subnet manually

---

## Step 5: Configure MagicDNS & Global Nameservers (Pi-hole Integration)

**This is the key advantage over Tailscale - full Pi-hole integration!**

1. Go to https://pangolin.net/admin/dns
2. **Enable MagicDNS** - Toggle ON
3. **Add Global Nameserver:**
   - Click **Add nameserver**
   - Enter your Pi's Pangolin IP (e.g., `100.x.x.x`)
   - **Enable "Override local DNS"** - This forces ALL DNS through Pi-hole
4. Save

**Result:** All devices on Pangolin will use your Pi-hole for DNS, blocking ads/tracking everywhere!

---

## Step 6: Configure ACLs (Access Control Lists)

For security, restrict which devices can access what:

1. Go to https://pangolin.net/admin/acls
2. Example secure configuration:
   ```
   # Allow all tagged devices to talk to each other
   group:tag:pi-server -> group:tag:pi-server
   group:tag:personal -> group:tag:pi-server
   
   # Allow personal devices to use exit node
   group:tag:personal -> exit-node(group:tag:pi-server)
   ```

---

## Step 7: Install on Your Pi

Run the InitOps script with network module:

```bash
# Interactive (will prompt for auth key if not in settings.conf)
sudo ./install.sh -m "system,network,pihole"

# Non-interactive (requires PANGOLIN_AUTH_KEY in settings.conf)
sudo ./install.sh -y -m "system,network,pihole"
```

---

## Verification

After installation:

```bash
# Check Pangolin status
pangolin status

# Get Pangolin IP
pangolin ip -4

# Ping another device on Pangolin by MagicDNS hostname
ping other-device.pangolin.net

# Test Pi-hole DNS from remote device
dig @100.x.x.x example.com
```

---

## Troubleshooting

### Pangolin won't connect
```bash
# Check logs
journalctl -u pangolin -f

# Try manual auth
pangolin up --authkey=pg-xxxx
```

### Can't access LAN through VPN
1. Verify subnet route is advertised in admin console
2. Check Pi's firewall: `ufw status`
3. Ensure IP forwarding enabled: `sysctl net.ipv4.ip_forward`

### Pi-hole not blocking ads on remote devices
1. Verify Global Nameserver is set to Pi's Pangolin IP
2. Check "Override local DNS" is ENABLED
3. Verify Pi-hole is listening on all interfaces:
   ```bash
   # In Pi-hole admin: Settings → DNS → Listen on all interfaces
   ```

### Exit node not working
1. Ensure exit node enabled in admin console
2. Client device must select exit node in Pangolin app
3. Check Pi's firewall allows forwarding

---

## Admin Console Reference

| Section | URL | Purpose |
|---------|-----|---------|
| Machines | /admin/machines | View/manage all devices |
| DNS | /admin/dns | MagicDNS, Global Nameservers |
| ACLs | /admin/acls | Access control policies |
| Auth Keys | /admin/settings/auth-keys | Generate/revoke auth keys |
| Settings | /admin/settings | Network name, domain, etc. |

---

## Comparison: Pangolin vs Tailscale

| Feature | Pangolin | Tailscale |
|---------|----------|-----------|
| MagicDNS | ✅ | ✅ |
| Exit Nodes | ✅ | ✅ |
| Subnet Routes | ✅ | ✅ |
| Global Nameservers | ✅ | ✅ |
| Override Local DNS | ✅ | ✅ |
| ACLs | ✅ | ✅ (Tailnet policies) |
| Free Personal Use | ✅ | ✅ |
| Self-hosted Option | ❌ | ✅ (Headscale) |
| Admin Console | Web-based | Web-based |

---

## Integration with Pi Server Setup Modules

| Module | Integration |
|--------|-------------|
| **Pi-hole** | Global nameserver + Override local DNS = Ad-blocking everywhere |
| **Monitoring** | Prometheus/Grafana accessible via MagicDNS (grafana.pangolin.net) |
| **Nginx Proxy** | Local domains work over VPN (dashboard.home → pangolin.net) |
| **Telegram Bot** | Can send Pangolin status alerts |
| **Cockpit/n8n/Stirling** | All accessible remotely via MagicDNS |

---

## Security Best Practices

1. **Use tags + ACLs** - Don't allow all devices to talk to all devices
2. **Enable MFA** on your Pangolin account
3. **Rotate auth keys** periodically
4. **Review device list** monthly in admin console
5. **Use ephemeral keys** for temporary/CI devices
6. **Disable exit node** when not needed

---

## Useful Commands

```bash
# Status
pangolin status
pangolin ip -4

# Network diagnostics
pangolin netcheck
pangolin ping <device-name>

# Management
pangolin logout
pangolin up --authkey=pg-xxx
pangolin set --exit-node=allow

# Debug
journalctl -u pangolin -f
pangolin version
```

---

## Support

- **Documentation:** https://pangolin.net/docs
- **Community:** https://github.com/pangolin-vpn/pangolin/discussions
- **Status Page:** https://status.pangolin.net
- **Email:** support@pangolin.net

---

## Migration from Tailscale

If migrating from Tailscale:

1. Install Pangolin alongside Tailscale (they can coexist)
2. Test connectivity with Pangolin
3. Update Pi-hole DNS settings to use Pangolin IP
4. Update Nginx/MagicDNS references
5. Once verified, remove Tailscale:
   ```bash
   tailscale logout
   apt-get remove tailscale
   ```

---

*This guide is part of Pi Server Setup v3 - https://github.com/vsp-2007/InitOps*