# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 2.x     | ✅ Current         |
| 1.x     | ❌ End of life     |

## Reporting a Vulnerability

**Please do not create public GitHub issues for security vulnerabilities.**

Instead, report them through one of these channels:

1. **GitHub Security Advisories** (Preferred): [Open a Security Advisory](https://github.com/your-repo/pi-server-setup/security/advisories/new)
2. **Email**: security@your-domain.com
3. **Encrypted Email**: Use our PGP key from [KEYBASE](https://keybase.io/your-username)

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
│  • Non-root service users                                   │
│  • Read-only filesystems where possible                     │
│  • Secrets in 600-permission files                          │
│  • Input validation & rate limiting (Telegram bot)          │
│  • Audit logging                                            │
└─────────────────────────────────────────────────────────────┘
```

### Service Hardening

All systemd services use these hardening options:

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
- Service environment files: `/etc/pi-server-setup/*.conf` (chmod 640, root:service-user)
- Telegram bot tokens: Stored in config, loaded via EnvironmentFile
- No secrets in git history (enforced by .gitignore)

## Threat Model

### In Scope

- Local network attackers (compromised device on LAN)
- Remote attackers via exposed services (if misconfigured)
- Supply chain attacks (compromised dependencies)
- Insider threats (malicious admin)

### Out of Scope

- Physical access to device
- Compromised upstream repositories (Debian, GitHub, etc.)
- Zero-day exploits in kernel/firmware
- Social engineering of administrators

### Mitigations

| Threat | Mitigation |
|--------|------------|
| LAN attacker | Tailscale for all remote access; UFW default-deny |
| SSH brute force | Key-only auth, Fail2Ban, custom port |
| Service compromise | Non-root users, systemd hardening, minimal capabilities |
| Config leakage | 600 permissions, .gitignore, no secrets in logs |
| Bot abuse | Rate limiting, input validation, admin-only commands |

## Secure Deployment Checklist

- [ ] Change default SSH port (settings.conf: `SSH_PORT`)
- [ ] Disable SSH password auth (`SSH_PASSWORD_AUTH="no"`)
- [ ] Add your SSH public key (`PI_SSH_KEYS`)
- [ ] Set strong passwords (or let script generate them)
- [ ] Configure Telegram bot tokens
- [ ] Set Tailscale auth key for unattended setup
- [ ] Verify UFW is active after install (`ufw status`)
- [ ] Check Fail2Ban is running (`fail2ban-client status`)
- [ ] Review open ports (`ss -tlnp`)
- [ ] Test Telegram bot commands
- [ ] Configure Pi-hole local DNS for `.home` domains

## Known Security Considerations

### Pi-hole Web Interface
- Runs on port 8081 (moved from 80 for Nginx)
- Admin password required
- No HTTPS by default (local network only)

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
- Subscribe to [releases](https://github.com/your-repo/pi-server-setup/releases) for updates
- Run `sudo ./install.sh -y` periodically to apply updates

## Contact

For security questions or concerns:
- **Email**: security@your-domain.com
- **PGP**: Available on Keybase

---

*This policy is adapted from industry best practices and will be updated as the project evolves.*