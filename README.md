# Pi Server Setup v2

> **Transform your Raspberry Pi into a production-ready, observable, and secure home server.**

[![Version](https://img.shields.io/badge/version-2.0.0-blue)](https://github.com/your-repo/pi-server-setup)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi%20OS%20(Trixie/Bookworm)-red)](https://www.raspberrypi.com/software/)
[![Architecture](https://img.shields.io/badge/arch-arm64%20%7C%20armv7%20%7C%20amd64-orange)]()
[![CI](https://github.com/your-repo/pi-server-setup/workflows/CI/badge.svg)](https://github.com/your-repo/pi-server-setup/actions)

---

## 🌟 Features

| Category | Components |
|----------|------------|
| **System** | Automated updates, user management, SSH hardening, UFW firewall, Fail2Ban, unattended upgrades |
| **Network** | Tailscale VPN (MagicDNS, Exit Node, Subnet Routes), optional Static IP |
| **DNS/Ad-block** | Pi-hole with curated blocklists, automated whitelisting, DNSSEC |
| **Monitoring** | Prometheus, Grafana (pre-provisioned dashboards), Alertmanager, Node Exporter |
| **File Sharing** | Samba (secure, service-account model), Webmin (web UI) |
| **Automation** | n8n (workflow automation), Telegram Bot (dual: Admin + User) |
| **Applications** | LocalSend, Stirling-PDF, Cockpit, Nginx Reverse Proxy |
| **Security** | Non-root services, systemd hardening, rate-limited bot, audit logging |

---

## 🏗 Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Raspberry Pi                              │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │   Tailscale  │  │    Pi-hole   │  │    Nginx     │           │
│  │   (VPN)      │  │   (DNS)      │  │  (Reverse    │           │
│  └──────┬───────┘  └──────┬───────┘  │   Proxy)     │           │
│         │                 │          └──────┬───────┘           │
│         │                 │                 │                   │
│  ┌──────▼─────────────────▼─────────────────▼───────┐           │
│  │              Local Services (LAN + Tailscale)   │           │
│  ├──────────────────────────────────────────────────┤           │
│  │  Prometheus ← Node Exporter                      │           │
│  │  Grafana (Dashboards)                            │           │
│  │  Alertmanager → Telegram Bot                     │           │
│  │  Samba + Webmin                                  │           │
│  │  n8n (Automation)                                │           │
│  │  Stirling-PDF, LocalSend, Cockpit                │           │
│  └──────────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🚀 Quick Start

### Prerequisites

- Raspberry Pi 4/5 (2GB+ RAM recommended)
- Raspberry Pi OS (64-bit) **Trixie** or **Bookworm**
- SSH access
- Internet connection

### Installation

```bash
# 1. Clone the repository
git clone https://github.com/your-repo/pi-server-setup.git
cd pi-server-setup

# 2. Copy and configure settings
cp config/settings.conf.example settings.conf
# Edit settings.conf with your values (see Configuration below)
nano settings.conf

# 3. Secure the config file
chmod 600 settings.conf

# 4. Run the installer
sudo ./install.sh
```

### Interactive Menu

The installer presents a menu to select modules:

```
Select modules to install:
  1) System Basics (Updates, User, SSH, Tools, Hardening)
  2) Network (Tailscale, Firewall, Fail2Ban)
  3) Pi-hole (DNS Ad-blocking)
  4) Monitoring Stack (Prometheus, Grafana, Alertmanager, Node Exporter)
  5) File Sharing (Samba, Webmin)
  6) Utilities (Reports, Cron jobs, Maintenance)
  7) Telegram Bot (Dual bot: Admin + User)
  8) LocalSend (File sharing app)
  9) Stirling-PDF (PDF tools)
  10) Nginx Reverse Proxy (Local domains)
  11) Cockpit (Web-based administration)
  12) n8n Automation Engine
  A) Install Everything
  Q) Quit
```

### Non-Interactive (Automated)

```bash
# Install specific modules
sudo ./install.sh -y -m "system,network,pihole,monitoring"

# Full automated install (requires pre-configured settings.conf)
sudo ./install.sh -y

# Dry run (validate config only)
sudo ./install.sh --dry-run
```

---

## ⚙️ Configuration

Copy `config/settings.conf.example` to `settings.conf` and customize:

### Required Settings

```bash
# System user (will be created with sudo access)
PI_USER="piadmin"
PI_PASSWORD=""              # Leave empty to generate random

# Telegram (optional but recommended for alerts)
TELEGRAM_ADMIN_TOKEN=""     # From @BotFather
TELEGRAM_ADMIN_CHAT_ID=""   # Your user ID from @userinfobot
TELEGRAM_USER_TOKEN=""      # For group status bot
TELEGRAM_USER_CHAT_ID=""    # Group chat ID (negative number)

# Tailscale (optional)
TAILSCALE_AUTH_KEY=""       # For unattended setup
TAILSCALE_EXIT_NODE="false"
```

### Service Passwords (leave empty to auto-generate)

```bash
GRAFANA_ADMIN_PASSWORD=""
PIHOLE_PASSWORD=""
SMB_PASSWORD=""
```

### Network (optional - prefer DHCP reservation on router)

```bash
STATIC_IP="192.168.1.100/24"
STATIC_GATEWAY="192.168.1.1"
STATIC_DNS="1.1.1.1"
```

### Security Hardening

```bash
SSH_PORT="2222"                    # Change from default 22
SSH_PASSWORD_AUTH="no"             # Disable after setting up keys
UFW_ENABLED="true"
FAIL2BAN_ENABLED="true"
UNATTENDED_UPGRADES="true"
```

> **⚠️ Security**: Never commit `settings.conf` to git! It's in `.gitignore`.

---

## 🔧 Module Details

### 1. System Basics (`system`)
- System updates & upgrades
- Creates `PI_USER` with sudo access
- SSH hardening (custom port, key-only auth, strong ciphers)
- UFW firewall with sensible defaults
- Fail2Ban (SSH, nginx, Pi-hole, Webmin jails)
- Unattended upgrades (security only)
- Journald log retention (500MB)
- Swap optimization (1-2GB)
- RealVNC setup

### 2. Network (`network`)
- Tailscale installation & authentication
- Exit node advertisement
- Subnet route advertisement (LAN access)
- MagicDNS + Global Nameserver guidance
- Optional static IP (with warnings)

### 3. Pi-hole (`pihole`)
- Unattended installation
- 25+ curated blocklists (ads, tracking, malware, phishing)
- Automated whitelisting (AnudeepND, weekly)
- Gravity updates via cron
- Web interface password

### 4. Monitoring (`monitoring`)
- **Prometheus** v2.54.1 with 15d/2GB retention
- **Node Exporter** v1.8.2 (full collectors)
- **Alertmanager** v0.27.0 (Telegram integration)
- **Grafana** v11.1.0 (pre-provisioned datasources & dashboards)
- Multi-arch: arm64, armv7, amd64
- systemd hardening on all services

### 5. File Sharing (`samba`)
- Secure Samba with `smbdata` service account
- No guest access by default
- Webmin for GUI management
- HTML guide for share creation

### 6. Utilities (`utils`)
- Daily/boot Telegram reports
- Disk space monitoring (alert at 85%)
- Weekly apt cleanup
- Logrotate for project logs

### 7. Telegram Bot (`telegram`)
- **Admin Bot**: Reboot, restart services, Pi-hole control, announcements
- **User Bot**: `/status`, `/pihole_stats`, disable requests (admin approval)
- Rate limiting (20/min, 100/hr)
- Input validation & audit logging
- Runs as `pi-bot` user (non-root)

### 8. LocalSend (`localsend`)
- Cross-platform file sharing
- Desktop shortcut
- Firewall rules

### 9. Stirling-PDF (`stirling`)
- Local PDF manipulation (no cloud)
- Java 21, optimized JVM settings for Pi
- 2GB swap, serial GC, tiered compilation
- No-login mode by default

### 10. Nginx Reverse Proxy (`nginx`)
- Local `.home` domains (dashboard.home, pi.home, etc.)
- Pi-hole FTL port moved to 8081
- WebSocket support for n8n, Cockpit, Stirling
- Auto-generated landing page

### 11. Cockpit (`cockpit`)
- Web-based system administration
- Port 9091 (configurable)
- systemd socket activation

### 12. n8n (`n8n`)
- Native Node.js 20 installation
- SQLite database
- Reverse proxy ready
- Secure cookie handling

---

## 🌐 Access URLs (after install)

| Service | Local URL | Domain (with Nginx) |
|---------|-----------|---------------------|
| Pi-hole | `http://<IP>/admin` | `http://pi.home/admin` |
| Grafana | `http://<IP>:3000` | `http://grafana.home` |
| Prometheus | `http://<IP>:9090` | `http://prometheus.home` |
| Alertmanager | `http://<IP>:9093` | `http://alertmanager.home` |
| n8n | `http://<IP>:5678` | `http://n8n.home` |
| Stirling-PDF | `http://<IP>:8080` | `http://pdf.home` |
| Cockpit | `https://<IP>:9091` | `http://dashboard.home` |
| Webmin | `https://<IP>:10000` | `http://webmin.home` |
| Samba | `\\<IP>\pishare` | - |

> **Note**: Configure Pi-hole Local DNS (`http://pi.home/admin/dns_records.php`) to map `.home` domains to your Pi's IP.

---

## 🔐 Security

See [SECURITY.md](SECURITY.md) for detailed security documentation including:

- Threat model & trust boundaries
- Service user privileges
- Secret management
- Network exposure
- Hardening checklist
- Incident response

### Quick Security Wins

```bash
# Verify SSH is hardened
ssh -p 2222 piadmin@<IP>

# Check systemd hardening
systemd-analyze security telegram-bot.service

# Verify config permissions
stat -c "%a %n" settings.conf /etc/pi-server-setup/settings.conf

# Check firewall
ufw status verbose

# Verify Fail2Ban
fail2ban-client status
```

---

## 🛠 Maintenance

### Updates

```bash
# System updates (automatic via unattended-upgrades)
sudo /usr/local/bin/pi-update.sh

# Update Pi-hole blocklists
pihole -g

# Update n8n
sudo npm update -g n8n

# Update Docker containers (if any)
docker pull <image> && docker compose up -d
```

### Backups

```bash
# Config backup
tar -czf pi-server-backup-$(date +%Y%m%d).tar.gz \
    settings.conf \
    /etc/pihole \
    /etc/prometheus \
    /etc/grafana \
    /etc/alertmanager \
    /etc/samba \
    /etc/nginx/sites-available \
    /opt/pi-server-bot \
    /var/lib/n8n
```

### Logs

```bash
# Installer log
tail -f /var/log/pi-server-setup/install_*.log

# Service logs
journalctl -u prometheus -f
journalctl -u telegram-bot -f
journalctl -u n8n -f

# Bot audit log
tail -f /var/log/pi-server-bot/audit.log
```

---

## 🧪 Testing

```bash
# Syntax check all scripts
bash -n install.sh
bash -n scripts/*.sh

# Lint with shellcheck
shellcheck install.sh scripts/*.sh

# Validate YAML
yamllint config/*.yml config/*.yaml

# Validate JSON
python3 -m json.tool config/*.json

# Validate systemd units
systemd-analyze verify systemd/*.service
```

---

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Run linting: `shellcheck scripts/*.sh && yamllint config/`
4. Commit with conventional commits (`feat:`, `fix:`, `docs:`, etc.)
5. Push and open a Pull Request

---

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

---

## 🙏 Acknowledgments

- [Pi-hole](https://pi-hole.net/) - Network-wide ad blocking
- [Prometheus](https://prometheus.io/) - Monitoring & alerting
- [Grafana](https://grafana.com/) - Observability dashboards
- [Tailscale](https://tailscale.com/) - Zero-config VPN
- [n8n](https://n8n.io/) - Workflow automation
- [Stirling-PDF](https://github.com/Stirling-Tools/Stirling-PDF) - PDF toolkit
- [LocalSend](https://localsend.org/) - Cross-platform file sharing
- [Cockpit](https://cockpit-project.org/) - Web-based server management
- [Webmin](https://www.webmin.com/) - System administration UI

---

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/your-repo/pi-server-setup/issues)
- **Discussions**: [GitHub Discussions](https://github.com/your-repo/pi-server-setup/discussions)
- **Security**: See [SECURITY.md](SECURITY.md) for responsible disclosure

---

**Made with ❤️ for the Raspberry Pi community**