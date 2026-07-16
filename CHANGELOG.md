# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2024-12-19

### Added
- Complete rewrite with modern architecture
- Modular module system with dependency resolution
- Multi-architecture support (arm64, armv7, amd64)
- Comprehensive security hardening (systemd, UFW, Fail2Ban, SSH)
- Dual Telegram bot architecture (Admin + User)
- Pi-hole with curated blocklists & automated whitelisting
- Prometheus/Grafana/Alertmanager monitoring stack
- Nginx reverse proxy with local `.home` domains
- Samba with service-account security model
- Webmin for web-based administration
- Stirling-PDF with Pi-optimized JVM settings
- n8n workflow automation engine
- LocalSend cross-platform file sharing
- Cockpit web-based system monitoring
- Configuration validation and dry-run mode
- Comprehensive documentation (README, SECURITY.md, CONTRIBUTING.md)
- CI/CD pipeline with GitHub Actions
- Dependabot configuration for dependency updates
- Test validation script

### Security
- All services run as dedicated non-root users
- Systemd hardening: NoNewPrivileges, PrivateTmp, ProtectSystem=strict
- SSH hardening: key-only auth, custom port, strong ciphers
- UFW default-deny incoming with minimal allow rules
- Fail2Ban for SSH, nginx, Pi-hole, Webmin
- Telegram bot: rate limiting, input validation, audit logging
- Config file permissions: 600 (root only)
- Secret management via environment files
- Unattended security upgrades

### Changed
- Version pinning for all external components
- Improved error handling and logging
- Interactive and non-interactive installation modes
- Dependency resolution between modules
- Backup before modifying system configs
- **Platform support expanded**: Now runs on any Debian 13+/Ubuntu 24.04+ system (Raspberry Pi, x86_64 laptop, VM, Mini PC, etc.)

### Fixed
- CRLF line ending issues (enforced LF)
- Permission issues on config files
- Pi-hole FTL port conflict with Nginx
- Grafana provisioning and password reset
- Telegram bot token handling
- Architecture detection for binary downloads

## [1.0.0] - 2024-01-15

### Added
- Initial release
- Basic system setup (updates, user, SSH)
- Tailscale installation
- Pi-hole installation
- Prometheus + Grafana + Alertmanager
- Samba + Webmin
- Telegram bot (single bot)
- Stirling-PDF
- LocalSend
- Nginx reverse proxy
- Cockpit
- n8n

---

## Version History

| Version | Date | Notes |
|---------|------|-------|
| 2.0.0 | 2024-12-19 | Major rewrite with security focus, multi-platform support |
| 1.0.0 | 2024-01-15 | Initial release (Pi-only) |