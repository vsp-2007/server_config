#!/bin/bash
# System Basics Module - Pi Server Setup v2 (Platform-agnostic)
# Updates, user creation, SSH hardening, essential tools, security hardening

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/../lib/platform.sh" 2>/dev/null || true

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
    
    # 9. Configure VNC (platform-specific)
    configure_vnc
    
    # 10. Configure Swap (platform-specific)
    configure_swap
    
    # 11. Apply System Optimizations (platform-specific)
    apply_platform_optimizations
    
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
    
    # Get platform-specific package list
    local base_packages=(
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
    
    local packages
    packages=$(get_packages_for_platform "${base_packages[@]}")
    
    apt-get install -y -qq ${packages} -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    
    # Install modern CLI tools via binary downloads (cross-platform)
    install_modern_tools
    
    log_success "Essential packages installed"
}

install_modern_tools() {
    # Install eza (modern ls), bat (modern cat), fd (modern find), ripgrep (modern grep)
    # These are installed via binary downloads for cross-platform compatibility
    log_info "Installing modern CLI tools..."
    
    # Starship prompt
    if ! command -v starship >/dev/null 2>&1; then
        log_info "Installing Starship prompt..."
        curl -sS https://starship.rs/install.sh | sh -s -- -y 2>/dev/null || log_warn "Starship install failed"
    fi
    
    # Zoxide (smart cd)
    if ! command -v zoxide >/dev/null 2>&1; then
        log_info "Installing zoxide..."
        curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash 2>/dev/null || log_warn "Zoxide install failed"
    fi
    
    # Eza (modern ls) - download binary if not in apt
    if ! command -v eza >/dev/null 2>&1; then
        log_info "Installing eza..."
        local eza_version="0.18.26"
        local arch_suffix=""
        case "${ARCH}" in
            amd64) arch_suffix="x86_64-unknown-linux-gnu" ;;
            arm64) arch_suffix="aarch64-unknown-linux-gnu" ;;
            armv7) arch_suffix="armv7-unknown-linux-gnueabihf" ;;
        esac
        if [[ -n "${arch_suffix}" ]]; then
            local eza_url="https://github.com/eza-community/eza/releases/download/v${eza_version}/eza_${arch_suffix}.tar.gz"
            curl -sSL "${eza_url}" | tar -xz -C /usr/local/bin eza 2>/dev/null || log_warn "Eza install failed"
        fi
    fi
    
    # Bat (modern cat)
    if ! command -v bat >/dev/null 2>&1 && ! command -v batcat >/dev/null 2>&1; then
        log_info "Installing bat..."
        local bat_version="0.24.0"
        local arch_suffix=""
        case "${ARCH}" in
            amd64) arch_suffix="x86_64-unknown-linux-gnu" ;;
            arm64) arch_suffix="aarch64-unknown-linux-gnu" ;;
            armv7) arch_suffix="armv7-unknown-linux-gnueabihf" ;;
        esac
        if [[ -n "${arch_suffix}" ]]; then
            local bat_url="https://github.com/sharkdp/bat/releases/download/v${bat_version}/bat-${arch_suffix}.tar.gz"
            curl -sSL "${bat_url}" | tar -xz -C /usr/local/bin --strip-components=1 "bat-${arch_suffix}/bat" 2>/dev/null || log_warn "Bat install failed"
        fi
    fi
}

setup_system_user() {
    log_info "Setting up system user: ${PI_USER}"
    
    # Check if user exists
    if id "${PI_USER}" &>/dev/null; then
        log_info "User ${PI_USER} already exists"
    else
        log_info "Creating user ${PI_USER}..."
        
        # Get platform-specific extra groups
        local extra_groups
        extra_groups=$(get_extra_user_groups sudo adm dialout cdrom video plugdev games users input netdev)
        
        useradd -m -s /bin/bash -G "${extra_groups}" "${PI_USER}"
        
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
    
    # Add user to docker group if docker exists
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

# Run main
main "$@"