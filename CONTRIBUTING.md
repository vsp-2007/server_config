# Contributing to Pi Server Setup v2

Thank you for your interest in contributing! This project aims to provide a secure, modular, and well-documented way to set up any Debian 13+/Ubuntu 24.04+ system (Raspberry Pi, laptop, VM, server) as a home server.

## Ways to Contribute

- 🐛 **Bug Reports** - Found an issue? Let us know!
- 💡 **Feature Requests** - Have an idea for improvement?
- 📝 **Documentation** - Improve README, SECURITY.md, or code comments
- 🔧 **Code Contributions** - Fix bugs, add modules, improve scripts
- 🧪 **Testing** - Test on different hardware, architectures, OS versions

## Getting Started

### Prerequisites

- Test hardware: Raspberry Pi, x86_64 laptop, VM, or mini PC
- Bash 4.4+
- shellcheck (for linting)
- yamllint (for YAML validation)
- python3 (for JSON/YAML validation)

### Development Setup

```bash
# Fork and clone your fork
git clone https://github.com/your-username/InitOps.git
cd InitOps

# Install development tools
sudo apt-get install shellcheck yamllint python3-yaml

# Run validation
./tests/validate.sh
```

## Code Style & Standards

### Shell Scripts

- **Shebang**: `#!/bin/bash`
- **Strict mode**: `set -euo pipefail` at top of every script
- **Naming**: lowercase with hyphens (`00-system.sh`, not `00_System.sh`)
- **Functions**: Use `snake_case` names
- **Variables**: UPPER_SNAKE_CASE for config, lowercase for locals
- **Error handling**: Check return codes, use `die()` function for fatal errors
- **Logging**: Use `log_info`, `log_success`, `log_warn`, `log_error` functions
- **Comments**: Explain *why*, not *what*

### Configuration Files

- **YAML**: 2-space indentation, no tabs
- **JSON**: 2-space indentation
- **systemd**: Standard unit file format
- **Versions**: Pin all external versions (no `latest`)

### Security Requirements

- **No hardcoded secrets** - Use environment variables or config files
- **Least privilege** - Services run as dedicated non-root users
- **Systemd hardening** - Apply standard hardening directives
- **Input validation** - Sanitize all user inputs
- **Audit logging** - Log security-relevant actions

## Module Development Guide

### Adding a New Module

1. Create script in `scripts/NN-module-name.sh`
2. Follow the standard template:

```bash
#!/bin/bash
# Module Name - Pi Server Setup v2
# Description of what this module does

set -euo pipefail

# Colors & logging functions (source from common lib or duplicate)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# Configuration variables (with defaults from settings.conf)
VAR_NAME="${VAR_NAME:-default_value}"

main() {
    log_info "Starting Module Name setup..."
    
    # Implementation here
    
    log_success "Module Name setup completed!"
}

main "$@"
```

3. Add to `install.sh` MODULES array and MODULE_SCRIPTS mapping
4. Add dependencies in MODULE_DEPS if needed
5. Create systemd service file in `systemd/` if needed
6. Add config template in `config/` if needed
7. Update README.md with module documentation
8. Test thoroughly

### Module Best Practices

- **Idempotent**: Safe to run multiple times
- **Check existing**: Detect if already installed/configured
- **Backup configs**: Backup before modifying system files
- **Validate**: Test config before applying (e.g., `nginx -t`, `sshd -t`)
- **Rollback**: Restore backup on failure
- **Firewall**: Add UFW rules if service exposes ports
- **Logging**: Log to project log directory

## Testing

### Local Testing

```bash
# Syntax check
bash -n install.sh
bash -n scripts/*.sh

# Full validation
./tests/validate.sh

# Dry run (requires config)
sudo ./install.sh --dry-run

# Test specific module
sudo ./scripts/00-system.sh
```

### Platform Testing

Test on (at minimum one from each category):

| Category | Platforms |
|----------|-----------|
| **ARM SBC** | Raspberry Pi OS (arm64) - Pi 4/5, Armbian (arm64/armv7) |
| **x86_64 VM** | Debian 13 (Trixie), Ubuntu 24.04 LTS |
| **Laptop/Desktop** | Debian 13, Ubuntu 24.04 (auto-detects TLP/thermald) |
| **VM** | Proxmox/ESXi/VirtualBox with qemu-guest-agent |

### Integration Testing

1. Fresh OS install
2. Run full installer (`sudo ./install.sh -y`)
3. Verify all services start
4. Test Telegram bot commands
5. Verify Nginx reverse proxy
6. Check Grafana dashboards load
7. Test Samba shares
8. Verify Tailscale connectivity

## Pull Request Process

1. **Fork** the repository
2. **Create branch**: `git checkout -b feature/amazing-feature`
3. **Commit changes**: Use conventional commits
   - `feat: add new monitoring dashboard`
   - `fix: resolve SSH key permission issue`
   - `docs: update README with n8n config`
   - `security: harden telegram bot rate limiting`
4. **Run validation**: `./tests/validate.sh` must pass
5. **Push** to your fork
6. **Open PR** against `v2-development` branch

### PR Requirements

- [ ] All validation checks pass
- [ ] No shellcheck errors (warnings OK with justification)
- [ ] Documentation updated (README, SECURITY.md if security-related)
- [ ] Config example updated if new variables added
- [ ] CHANGELOG.md updated (if exists)
- [ ] Tested on at least one target platform

## Release Process

Maintainers only:

1. Update version in `install.sh` (`SCRIPT_VERSION`)
2. Update `CHANGELOG.md`
3. Create tag: `git tag -a v2.1.0 -m "Release v2.1.0"`
4. Push tag: `git push origin v2.1.0`
5. GitHub Actions creates release with archive

## Code of Conduct

- Be respectful and inclusive
- Focus on technical merits
- No harassment, discrimination, or offensive behavior
- Follow GitHub Community Guidelines

## Questions?

- Open a [Discussion](https://github.com/vsp-2007/InitOps/discussions)
- Check existing [Issues](https://github.com/vsp-2007/InitOps/issues)
- Review [Security Policy](SECURITY.md) for vulnerability reporting

---

*Thank you for contributing to Pi Server Setup v2!*