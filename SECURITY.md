# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 2.x     | ✅ Current         |
| 1.x     | ❌ End of life     |

## Reporting a Vulnerability

**Please do not create public GitHub issues for security vulnerabilities.**

Instead, report them through one of these channels:

1. **GitHub Security Advisories** (Preferred): [Open a Security Advisory](https://github.com/vsp-2007/InitOps/security/advisories/new)
2. **Email**: security@your-domain.com (replace with actual)
3. **Encrypted Email**: Use our PGP key from [KEYBASE](https://keybase.io/your-username) (replace with actual)

We will acknowledge receipt within **48 hours** and provide a timeline for fixes.

## Security Architecture

### Defense in Depth

This project implements multiple security layers:

```
┌─────────────────────────────────────────────────────────────┐
│                    NETWORK LAYER                            │
│  • UFW Firewall (default-deny incoming)                     │
│  • Tailscale VPN (all remote access)                        │
│  • Fail2Ban (brute-force protection)                        │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│                    HOST LAYER                               │
│  • SSH Hardening (key-only, custom port, no root)           │
│  • Unattended Security Upgrades                             │
│  • Journald Retention Limits                                │
│  • Systemd Service Hardening                                │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│                  APPLICATION LAYER                          │
│  • Non-root service users (pi-bot, n8n, prometheus, etc.)   │
│  • Read-only filesystems where possible                     │
│  • Secrets in 600-permission files                          │
│  • Input validation & rate limiting (Telegram bot)          │
│  • Audit logging                                            │
└─────────────────────────────────────────────────────────────┘
```

### Systemd Hardening

All custom services use these hardening directives:

```ini
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=<minimal required paths>
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
```

### Secret Management

- Configuration file: `settings.conf` (chmod 600, root only)
- Service environment files: `/etc/InitOps/*.conf` (chmod 640, root:service-user)
- Telegram bot tokens: Stored in config, loaded via EnvironmentFile
- No secrets in git history (enforced by .gitignore)

### Service Users & Privileges

| Service | User | Groups | Capabilities |
|---------|------|--------|--------------|
| Prometheus | prometheus | prometheus | None |
| Node Exporter | node_exporter | node_exporter | None |
| Alertmanager | alertmanager | alertmanager | None |
| Grafana | grafana | grafana | None |
| Samba | smbdata | smbdata | None |
| Stirling-PDF | stirlingpdf | stirlingpdf | None |
| n8n | n8n | n8n | None |
| Telegram Bot | pi-bot | pi-bot | None |
| Pi-hole | pihole | pihole | NET_BIND_SERVICE (port 53) |

## Network Exposure

**No services are exposed to the public internet by default.**

All services bind to:
- `0.0.0.0` for local LAN access
- Tailscale interface (`tailscale0`) for remote access

To access remotely:
1. Install Tailscale on your devices
2. Connect to your tailnet
3. Access via Tailscale IP or MagicDNS

## Hardening Checklist

Post-installation verification:

- [ ] SSH on custom port, key-only auth (`SSH_PASSWORD_AUTH="no"`)
- [ ] UFW active with minimal rules (`ufw status verbose`)
- [ ] Fail2Ban active with SSH, nginx, Pi-hole, Webmin jails (`fail2ban-client status`)
- [ ] All services running as non-root users (`systemd-analyze security <service>`)
- [ ] Systemd hardening applied (`systemd-analyze security telegram-bot.service`)
- [ ] Config files at 600/640 permissions (`stat -c "%a %n" settings.conf /etc/InitOps/*.conf`)
- [ ] Telegram bot audit logging working (`tail /var/log/pi-server-bot/audit.log`)
- [ ] Tailscale MagicDNS + Global Nameserver configured
- [ ] Unattended upgrades enabled (`systemctl status unattended-upgrades`)
- [ ] Log retention configured (journald 500MB, logrotate)

## Known Security Considerations

### Pi-hole Web Interface
- Runs on port 8081 (moved from 80 for Nginx)
- Admin password required
- No HTTPS by default (local network only)
- Consider Tailscale-only access

### Webmin
- Runs on port 10000 with self-signed certificate
- System user authentication
- Consider Tailscale-only access

### Grafana
- Default admin user configurable
- No HTTPS by default (behind Nginx/Tailscale)
- Anonymous access disabled

### Stirling-PDF
- Runs in no-login mode by default
- Consider enabling auth for multi-user environments
- File upload size limited to 100MB

### n8n
- Basic auth disabled (handled by Nginx/Tailscale)
- Webhook URL uses `.home` domain
- Encryption key auto-generated

## Vulnerability Disclosure Timeline

1. **Day 0**: Vulnerability reported
2. **Day 1-2**: Acknowledgment & initial assessment
3. **Day 3-7**: Root cause analysis & fix development
4. **Day 7-14**: Testing & patch preparation
5. **Day 14**: Coordinated disclosure & release

Critical vulnerabilities (CVSS ≥ 9.0) may receive expedited timelines.

## Security Updates

- Enable `UNATTENDED_UPGRADES="true"` in settings.conf
- Monitor GitHub Security Advisories for this repo
- Subscribe to [releases](https://github.com/vsp-2007/InitOps/releases) for updates
- Run `sudo ./install.sh -y` periodically to apply updates

## Contact

For security questions or concerns:
- **Email**: security@your-domain.com
- **PGP**: Available on Keybase

---

*This policy is adapted from industry best practices and will be updated as the project evolves.*