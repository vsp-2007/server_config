# Tailscale VPN Setup Guide for Pi Server Setup v3

**Website:** https://tailscale.com/  
**Documentation:** https://tailscale.com/kb/  
**Admin Console:** https://login.tailscale.com/admin

---

## Overview

Tailscale is a zero-configuration VPN built on WireGuard. It provides:
- **MagicDNS** - Automatic hostname resolution across your network
- **Exit Nodes** - Route traffic through your home server
- **Subnet Routes** - Access your LAN from anywhere
- **ACLs** - Fine-grained access control
- **Self-hosted option** - Headscale for complete control

---

## Prerequisites

1. A Tailscale account (free for personal use)
2. Internet connection on the target machine
3. Root/sudo access

---

## Step 1: Create Tailscale Account

1. Go to https://tailscale.com/
2. Click "Get Started Free"
3. Sign up with GitHub, Google, Microsoft, or email
4. Verify your email

---

## Step 2: Generate Auth Key (for unattended setup)

1. Log into https://login.tailscale.com/admin
2. Navigate to **Settings** → **Auth Keys**
3. Click **Generate Auth Key**
4. Configure:
   - **Description:** `pi-server-setup`
   - **Expiry:** No expiry (or set as needed)
   - **Reusable:** Yes
   - **Ephemeral:** No
   - **Pre-authorized:** Yes
   - **Tags:** `tag:pi-server` (optional, for ACL organization)
5. Copy the generated key (starts with `tskey-`)

**Add to settings.conf:**
```bash
TAILSCALE_AUTH_KEY="tskey-your-auth-key-here"
TAILSCALE_EXIT_NODE="false"
TAILSCALE_HOSTNAME="pi-server"  # Optional custom hostname
```

---

## Step 3: Configure Exit Node (Optional)

To use your Pi as an exit node (route all traffic through home):

1. In `settings.conf`:
   ```bash
   TAILSCALE_EXIT_NODE="true"
   ```

2. After installation, enable in admin console:
   - Go to https://login.tailscale.com/admin/machines
   - Find your Pi device
   - Click **...** → **Edit route settings**
   - Enable **Use as exit node**
   - Save

3. On client devices:
   - Tailscale app → **Exit Node** → Select your Pi

---

## Step 4: Configure Subnet Routes (Access LAN from VPN)

The script auto-detects your LAN subnet and advertises it. To verify:

1. Go to https://login.tailscale.com/admin/machines
2. Find your Pi device
3. Check **Advertised routes** - should show your LAN (e.g., `192.168.1.0/24`)
4. If missing, click **Edit route settings** → Add your subnet manually

---

## Step 5: Configure MagicDNS & Global Nameservers (Pi-hole Integration)

**This is the key advantage for ad-blocking everywhere!**

1. Go to https://login.tailscale.com/admin/dns
2. **Enable MagicDNS** - Toggle ON
3. **Add Global Nameserver:**
   - Click **Add nameserver**
   - Enter your Pi's Tailscale IP (e.g., `100.x.x.x`)
   - **Enable "Override local DNS"** - This forces ALL DNS through Pi-hole
4. Save

**Result:** All devices on Tailscale will use your Pi-hole for DNS, blocking ads/tracking everywhere!

---

## Step 6: Configure ACLs (Access Control Lists)

For security, restrict which devices can access what:

1. Go to https://login.tailscale.com/admin/acls
2. Example secure configuration:
   ```json
   {
     "groups": {
       "group:pi-server": ["pi-server"],
       "group:personal": ["phone", "laptop", "tablet"]
     },
     "acls": [
       {"action": "accept", "src": ["group:pi-server"], "dst": ["group:pi-server:*"]},
       {"action": "accept", "src": ["group:personal"], "dst": ["group:pi-server:*"]},
       {"action": "accept", "src": ["group:personal"], "dst": ["group:personal:*"]}
     ]
   }
   ```

---

## Step 7: Install on Your Pi

Run the pi-server-setup script with network module:

```bash
# Interactive (will prompt for auth key if not in settings.conf)
sudo ./install.sh -m "system,network,pihole"

# Non-interactive (requires TAILSCALE_AUTH_KEY in settings.conf)
sudo ./install.sh -y -m "system,network,pihole"
```

---

## Verification

After installation:

```bash
# Check Tailscale status
tailscale status

# Get Tailscale IP
tailscale ip -4

# Ping another device on Tailscale by MagicDNS hostname
ping other-device.tailnet-name.ts.net

# Test Pi-hole DNS from remote device
dig @100.x.x.x example.com
```

---

## Troubleshooting

### Tailscale won't connect
```bash
# Check logs
journalctl -u tailscaled -f

# Try manual auth
tailscale up --authkey=tskey-xxx
```

### Can't access LAN through VPN
1. Verify subnet route is advertised in admin console
2. Check Pi's firewall: `ufw status`
3. Ensure IP forwarding enabled: `sysctl net.ipv4.ip_forward`

### Pi-hole not blocking ads on remote devices
1. Verify Global Nameserver is set to Pi's Tailscale IP
2. Check "Override local DNS" is ENABLED
3. Verify Pi-hole is listening on all interfaces:
   - Pi-hole admin: Settings → DNS → Listen on all interfaces

### Exit node not working
1. Ensure exit node enabled in admin console
2. Client device must select exit node in Tailscale app
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

## Comparison: Tailscale vs Pangolin

| Feature | Tailscale | Pangolin |
|---------|-----------|----------|
| MagicDNS | ✅ | ✅ |
| Exit Nodes | ✅ | ✅ |
| Subnet Routes | ✅ | ✅ |
| Global Nameservers | ✅ | ✅ |
| Override Local DNS | ✅ | ✅ |
| ACLs | ✅ (Tailnet policies) | ✅ |
| Free Personal Use | ✅ | ✅ |
| Self-hosted Option | ✅ (Headscale) | ❌ |
| Admin Console | Web-based | Web-based |

---

## Migration from Pangolin

If switching from Pangolin:

1. Install Tailscale alongside Pangolin (they can coexist)
2. Test connectivity with Tailscale
3. Update Pi-hole DNS settings to use Tailscale IP
4. Update Nginx/MagicDNS references
5. Once verified, remove Pangolin:
   ```bash
   pangolin logout
   apt-get remove pangolin
   ```

---

## Support

- **Documentation:** https://tailscale.com/kb/
- **Community:** https://github.com/tailscale/tailscale/discussions
- **Status Page:** https://status.tailscale.com
- **Email:** support@tailscale.com

---

## Integration with Pi Server Setup Modules

| Module | Integration |
|--------|-------------|
| **Pi-hole** | Global nameserver + Override local DNS = Ad-blocking everywhere |
| **Monitoring** | Prometheus/Grafana accessible via MagicDNS (grafana.tailnet-name.ts.net) |
| **Nginx Proxy** | Local domains work over VPN (dashboard.home → tailnet-name.ts.net) |
| **Telegram Bot** | Can send Tailscale status alerts |
| **Cockpit/n8n/Stirling** | All accessible remotely via MagicDNS |

---

*This guide is part of Pi Server Setup v3 - https://github.com/vsp-2007/Interactive-server_config_script*