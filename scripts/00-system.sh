#!/bin/bash
# System Basics Module - Pi Server Setup v2
# Updates, user creation, SSH hardening, essential tools, security hardening

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# Configuration variables (with defaults)
PI_USER="${PI_USER:-piadmin}"
PI_PASSWORD="${PI_PASSWORD:-}"
PI_SSH_KEYS="${PI_SSH_KEYS:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_PERMIT_ROOT_LOGIN="${SSH_PERMIT_ROOT_LOGIN:-no}"
SSH_PASSWORD_AUTH="${SSH_PASSWORD_AUTH:-no}"
SSH_PUBKEY_AUTH="${SSH_PUBKEY_AUTH:-yes}"
SSH_MAX_AUTH_TRIES="${SSH_MAX_AUTH_TRIES:-3}"
UFW_ENABLED="${UFW_ENABLED:-true}"
UFW_DEFAULT_DENY_INCOMING="${UFW_DEFAULT_DENY_INCOMING:-yes}"
UFW_DEFAULT_ALLOW_OUTGOING="${UFW_DEFAULT_ALLOW_OUTGOING:-yes}"
FAIL2BAN_ENABLED="${FAIL2BAN_ENABLED:-true}"
FAIL2BAN_BANTIME="${FAIL2BAN_BANTIME:-1h}"
FAIL2BAN_FINDTIME="${FAIL2BAN_FINDTIME:-10m}"
FAIL2BAN_MAXRETRY="${FAIL2BAN_MAXRETRY:-3}"
UNATTENDED_UPGRADES="${UNATTENDED_UPGRADES:-true}"
UNATTENDED_UPGRADES_EMAIL="${UNATTENDED_UPGRADES_EMAIL:-}"

main() {
    log_info "Starting System Basics setup..."
    
    # 1. System Updates
    run_system_updates
    
    # 2. Install Essential Packages
    install_essential_packages
    
    # 3. Create/Configure System User
    setup_system_user
    
    # 4. Configure SSH Hardening
    configure_ssh
    
    # 5. Configure Firewall (UFW)
    configure_firewall
    
    # 6. Configure Fail2Ban
    configure_fail2ban
    
    # 7. Configure Unattended Upgrades
    configure_unattended_upgrades
    
    # 8. Configure Log Retention (journald)
    configure_log_retention
    
    # 9. Enable RealVNC (if on Raspberry Pi)
    configure_vnc
    
    # 10. System Optimizations
    apply_system_optimizations
    
    log_success "System Basics setup completed!"
}

run_system_updates() {
    log_info "Updating package repositories and upgrading system..."
    
    # Clean any conflicting repos (Webmin, etc.)
    rm -f /etc/apt/sources.list.d/webmin*.list 2>/dev/null || true
    
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    
    log_success "System updates completed"
}

install_essential_packages() {
    log_info "Installing essential packages..."
    
    local packages=(
        # System utilities
        curl wget git vim htop btop jq
        # Network tools
        net-tools iproute2 dnsutils iputils-ping
        # Security
        ufw fail2ban unattended-upgrades apt-listchanges
        # System monitoring
        lm-sensors smartmontools
        # Development
        build-essential python3 python3-venv python3-pip python3-full
        # Archive/Compression
        unzip zip tar gzip bzip2 xz-utils
        # Process management
        psmisc procps
        # File system
        tree ncdu
        # Terminal multiplexer
        tmux screen
        # Crypto
        gnupg2 openssl ca-certificates
    )
    
    apt-get install -y -qq "${packages[@]}" -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    
    # Install modern CLI tools via cargo if available, or download binaries
    install_modern_tools
    
    log_success "Essential packages installed"
}

install_modern_tools() {
    # Install eza (modern ls), bat (modern cat), fd (modern find), ripgrep (modern grep)
    # These are installed via cargo or downloaded as binaries
    log_info "Installing modern CLI tools..."
    
    # Try to install via apt first (newer Debian versions)
    local modern_packages=(eza bat fd-find ripgrep)
    apt-get install -y -qq "${modern_packages[@]}" 2>/dev/null || {
        log_warn "Some modern tools not available in apt, skipping..."
    }
    
    # Install starship prompt
    if ! command -v starship >/dev/null 2>&1; then
        log_info "Installing Starship prompt..."
        curl -sS https://starship.rs/install.sh | sh -s -- -y 2>/dev/null || log_warn "Starship install failed"
    fi
    
    # Install zoxide (smart cd)
    if ! command -v zoxide >/dev/null 2>&1; then
        log_info "Installing zoxide..."
        curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash 2>/dev/null || log_warn "Zoxide install failed"
    fi
}

setup_system_user() {
    log_info "Setting up system user: ${PI_USER}"
    
    # Check if user exists
    if id "${PI_USER}" &>/dev/null; then
        log_info "User ${PI_USER} already exists"
    else
        log_info "Creating user ${PI_USER}..."
        useradd -m -s /bin/bash -G sudo,adm,dialout,cdrom,video,plugdev,games,users,input,netdev,gpio,i2c,spi "${PI_USER}"
        
        # Set password
        if [[ -n "${PI_PASSWORD}" ]]; then
            echo "${PI_USER}:${PI_PASSWORD}" | chpasswd
            log_success "Password set for ${PI_USER}"
        else
            log_warn "No password set for ${PI_USER}. Set one with: passwd ${PI_USER}"
        fi
    fi
    
    # Configure sudo without password for this user (for automation)
    echo "${PI_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/99-${PI_USER}"
    chmod 440 "/etc/sudoers.d/99-${PI_USER}"
    
    # Setup SSH keys if provided
    if [[ -n "${PI_SSH_KEYS}" ]]; then
        setup_ssh_keys
    fi
    
    # Add user to additional groups for hardware access
    usermod -aG docker "${PI_USER}" 2>/dev/null || true
    
    log_success "System user configured"
}

setup_ssh_keys() {
    log_info "Setting up SSH keys for ${PI_USER}..."
    
    local ssh_dir="/home/${PI_USER}/.ssh"
    mkdir -p "${ssh_dir}"
    chmod 700 "${ssh_dir}"
    
    # Decode keys (support both raw and base64)
    local keys="${PI_SSH_KEYS}"
    if [[ "${keys}" =~ ^[A-Za-z0-9+/=]+$ ]] && [[ ${#keys} -gt 100 ]]; then
        # Looks like base64
        keys=$(echo "${keys}" | base64 -d 2>/dev/null || echo "${keys}")
    fi
    
    echo "${keys}" > "${ssh_dir}/authorized_keys"
    chmod 600 "${ssh_dir}/authorized_keys"
    chown -R "${PI_USER}:${PI_USER}" "${ssh_dir}"
    
    log_success "SSH keys configured"
}

configure_ssh() {
    log_info "Configuring SSH hardening..."
    
    local sshd_config="/etc/ssh/sshd_config"
    local backup_file="${BACKUP_DIR:-/var/lib/pi-server-setup/backups}/sshd_config.$(date +%Y%m%d_%H%M%S).bak"
    
    mkdir -p "$(dirname "${backup_file}")"
    cp "${sshd_config}" "${backup_file}"
    
    # Apply hardening settings
    local settings=(
        "Port ${SSH_PORT}"
        "PermitRootLogin ${SSH_PERMIT_ROOT_LOGIN}"
        "PasswordAuthentication ${SSH_PASSWORD_AUTH}"
        "PubkeyAuthentication ${SSH_PUBKEY_AUTH}"
        "MaxAuthTries ${SSH_MAX_AUTH_TRIES}"
        "MaxSessions 3"
        "LoginGraceTime 30"
        "PermitEmptyPasswords no"
        "PermitUserEnvironment no"
        "AllowAgentForwarding no"
        "AllowTcpForwarding no"
        "X11Forwarding no"
        "PrintMotd no"
        "PrintLastLog yes"
        "TCPKeepAlive yes"
        "ClientAliveInterval 300"
        "ClientAliveCountMax 2"
        "UsePAM yes"
        "AuthenticationMethods publickey"
        "KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512"
        "Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
        "MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com"
    )
    
    for setting in "${settings[@]}"; do
        local key="${setting%% *}"
        local value="${setting#* }"
        if grep -q "^#\?${key}" "${sshd_config}"; then
            sed -i "s/^#\?${key}.*/${key} ${value}/" "${sshd_config}"
        else
            echo "${key} ${value}" >> "${sshd_config}"
        fi
    done
    
    # Validate SSH config
    if sshd -t; then
        systemctl reload ssh
        log_success "SSH hardened and reloaded (Port: ${SSH_PORT})"
    else
        log_error "SSH config validation failed, restoring backup"
        cp "${backup_file}" "${sshd_config}"
        systemctl reload ssh
        return 1
    fi
}

configure_firewall() {
    if [[ "${UFW_ENABLED}" != "true" ]]; then
        log_info "UFW disabled in config, skipping..."
        return 0
    fi
    
    log_info "Configuring UFW firewall..."
    
    # Reset to defaults
    ufw --force reset
    
    # Default policies
    if [[ "${UFW_DEFAULT_DENY_INCOMING}" == "yes" ]]; then
        ufw default deny incoming
    else
        ufw default allow incoming
    fi
    
    if [[ "${UFW_DEFAULT_ALLOW_OUTGOING}" == "yes" ]]; then
        ufw default allow outgoing
    else
        ufw default deny outgoing
    fi
    
    # Allow SSH (custom port)
    ufw allow "${SSH_PORT}/tcp" comment "SSH"
    
    # Allow local network (adjust as needed)
    ufw allow from 192.168.0.0/16 comment "Local LAN"
    ufw allow from 10.0.0.0/8 comment "Private networks"
    ufw allow from 172.16.0.0/12 comment "Private networks"
    
    # Allow Tailscale
    ufw allow in on tailscale0 comment "Tailscale"
    ufw allow out on tailscale0 comment "Tailscale"
    
    # Enable UFW
    ufw --force enable
    
    log_success "UFW firewall configured and enabled"
}

configure_fail2ban() {
    if [[ "${FAIL2BAN_ENABLED}" != "true" ]]; then
        log_info "Fail2Ban disabled in config, skipping..."
        return 0
    fi
    
    log_info "Configuring Fail2Ban..."
    
    # Create custom jail.local
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = ${FAIL2BAN_BANTIME}
findtime = ${FAIL2BAN_FINDTIME}
maxretry = ${FAIL2BAN_MAXRETRY}
backend = systemd
usedns = warn
logencoding = auto
enabled = true

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 3
bantime = 1h

[sshd-ddos]
enabled = true
port = ${SSH_PORT}
filter = sshd-ddos
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 3
bantime = 1h

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 3

[nginx-limit-req]
enabled = true
filter = nginx-limit-req
logpath = /var/log/nginx/error.log
maxretry = 5

[pihole-auth]
enabled = true
filter = pihole-auth
logpath = /var/log/pihole/pihole.log
maxretry = 5
bantime = 30m

[webmin-auth]
enabled = true
filter = webmin-auth
logpath = /var/log/webmin/miniserv.log
maxretry = 3
bantime = 1h
EOF
    
    # Create Pi-hole filter
    cat > /etc/fail2ban/filter.d/pihole-auth.conf <<'EOF'
[Definition]
failregex = .*Client\s+<HOST>\s+blocked.* 
            ^.*permission denied.*from <HOST>.*$
ignoreregex =
EOF
    
    systemctl enable fail2ban
    systemctl restart fail2ban
    
    log_success "Fail2Ban configured and started"
}

configure_unattended_upgrades() {
    if [[ "${UNATTENDED_UPGRADES}" != "true" ]]; then
        log_info "Unattended upgrades disabled in config, skipping..."
        return 0
    fi
    
    log_info "Configuring unattended upgrades..."
    
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};

Unattended-Upgrade::Package-Blacklist {
};

Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";
EOF
    
    if [[ -n "${UNATTENDED_UPGRADES_EMAIL}" ]]; then
        echo "Unattended-Upgrade::Mail \"${UNATTENDED_UPGRADES_EMAIL}\";" >> /etc/apt/apt.conf.d/50unattended-upgrades
        echo "Unattended-Upgrade::MailReport \"on-change\";" >> /etc/apt/apt.conf.d/50unattended-upgrades
    fi
    
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
    
    systemctl enable unattended-upgrades
    systemctl restart unattended-upgrades
    
    log_success "Unattended upgrades configured"
}

configure_log_retention() {
    log_info "Configuring log retention (journald)..."
    
    local journald_conf="/etc/systemd/journald.conf"
    
    # Backup
    cp "${journald_conf}" "${journald_conf}.bak.$(date +%Y%m%d)"
    
    # Configure retention
    sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=500M/' "${journald_conf}"
    sed -i 's/^#\?SystemKeepFree=.*/SystemKeepFree=1G/' "${journald_conf}"
    sed -i 's/^#\?SystemMaxFileSize=.*/SystemMaxFileSize=100M/' "${journald_conf}"
    sed -i 's/^#\?SystemMaxFiles=.*/SystemMaxFiles=10/' "${journald_conf}"
    sed -i 's/^#\?RuntimeMaxUse=.*/RuntimeMaxUse=200M/' "${journald_conf}"
    sed -i 's/^#\?MaxRetentionSec=.*/MaxRetentionSec=30day/' "${journald_conf}"
    sed -i 's/^#\?Compress=.*/Compress=yes/' "${journald_conf}"
    sed -i 's/^#\?ForwardToSyslog=.*/ForwardToSyslog=no/' "${journald_conf}"
    
    systemctl restart systemd-journald
    
    log_success "Log retention configured (500MB max, 30 days)"
}

configure_vnc() {
    if command -v raspi-config >/dev/null; then
        log_info "Configuring RealVNC..."
        
        local vnc_state
        vnc_state=$(raspi-config nonint get_vnc 2>/dev/null || echo "1")
        
        if [[ "${vnc_state}" -eq 0 ]]; then
            log_info "RealVNC is already enabled"
        else
            raspi-config nonint do_vnc 0
            log_success "RealVNC enabled"
        fi
    else
        log_info "raspi-config not found, skipping VNC setup"
    fi
}

apply_system_optimizations() {
    log_info "Applying system optimizations..."
    
    # Swap optimization for Pi
    if [[ -f /etc/dphys-swapfile ]]; then
        local current_swap
        current_swap=$(grep "^CONF_SWAPSIZE=" /etc/dphys-swapfile | cut -d= -f2)
        if [[ -z "${current_swap}" ]] || [[ "${current_swap}" -lt 1024 ]]; then
            log_info "Increasing swap to 1GB..."
            sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=1024/' /etc/dphys-swapfile
            systemctl restart dphys-swapfile
        fi
    fi
    
    # Disable unnecessary services
    local services_to_disable=(
        bluetooth
        hciuart
        triggerhappy
    )
    
    for svc in "${services_to_disable[@]}"; do
        systemctl disable "${svc}" 2>/dev/null || true
        systemctl stop "${svc}" 2>/dev/null || true
    done
    
    # Enable useful services
    systemctl enable systemd-timesyncd
    systemctl start systemd-timesyncd
    
    # Configure timezone if not set
    if [[ "$(cat /etc/timezone 2>/dev/null)" == "Etc/UTC" ]]; then
        log_warn "Timezone is UTC. Consider setting your local timezone with: raspi-config"
    fi
    
    log_success "System optimizations applied"
}

# Run main
main "$@"