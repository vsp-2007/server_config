#!/bin/bash
# Samba & Webmin Module - Pi Server Setup v2
# Multi-arch compatible, secure Samba configuration

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# Config
SMB_USER="${SMB_USER:-smbuser}"
SMB_PASSWORD="${SMB_PASSWORD:-}"
SMB_SHARE_PATH="${SMB_SHARE_PATH:-/srv/samba/share}"
SMB_SHARE_NAME="${SMB_SHARE_NAME:-pishare}"
WEBMIN_ENABLED="${WEBMIN_ENABLED:-true}"
WEBMIN_PORT="${WEBMIN_PORT:-10000}"
PI_USER="${PI_USER:-piadmin}"

main() {
    log_info "Starting File Sharing setup..."
    
    install_samba
    configure_samba
    create_samba_user
    configure_shares
    
    if [[ "${WEBMIN_ENABLED}" == "true" ]]; then
        install_webmin
    fi
    
    configure_firewall
    create_webmin_guide
    
    log_success "File Sharing setup completed!"
}

install_samba() {
    log_info "Installing Samba..."
    
    if command -v smbd >/dev/null; then
        log_info "Samba already installed"
    else
        apt-get update -qq
        apt-get install -y -qq samba samba-common-bin
    fi
}

configure_samba() {
    log_info "Configuring Samba..."
    
    # Backup original config
    [[ -f /etc/samba/smb.conf && ! -f /etc/samba/smb.conf.bak ]] && cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
    
    # Create smbdata service account
    if ! id "smbdata" &>/dev/null; then
        useradd -M -s /usr/sbin/nologin -r smbdata
        log_info "Created smbdata service account"
    fi
    
    # Create share directory
    mkdir -p "${SMB_SHARE_PATH}"
    chown -R smbdata:smbdata "${SMB_SHARE_PATH}"
    chmod 2770 "${SMB_SHARE_PATH}"
    chmod 755 "$(dirname "${SMB_SHARE_PATH}")"
    
    # Generate smb.conf
    cat > /etc/samba/smb.conf <<EOF
[global]
    workgroup = WORKGROUP
    server string = Pi Server (%v)
    netbios name = $(hostname)
    
    # Security
    security = user
    map to guest = bad user
    passdb backend = tdbsam
    obey pam restrictions = yes
    pam password change = yes
    passwd program = /usr/bin/passwd %u
    passwd chat = *Enter\snew\s*\spassword:* %n\n *Retype\snew\s*\spassword:* %n\n *password\supdated\ssuccessfully* .
    unix password sync = yes
    
    # Logging
    log file = /var/log/samba/log.%m
    max log size = 50
    logging = file
    
    # Performance
    socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072
    read raw = yes
    write raw = yes
    max xmit = 65535
    deadtime = 15
    getwd cache = yes
    
    # Compatibility
    client min protocol = SMB2
    server min protocol = SMB2
    ntlm auth = no
    lanman auth = no
    
    # VFS
    vfs objects = catia fruit streams_xattr
    fruit:metadata = stream
    fruit:model = MacSamba
    fruit:veto_appledouble = no
    
    # Disable printing
    load printers = no
    printing = bsd
    printcap name = /dev/null
    disable spoolss = yes

[${SMB_SHARE_NAME}]
    comment = Pi Server Share
    path = ${SMB_SHARE_PATH}
    browseable = yes
    read only = no
    guest ok = no
    valid users = ${SMB_USER}
    create mask = 0660
    directory mask = 2770
    force user = smbdata
    force group = smbdata
    force create mode = 0660
    force directory mode = 2770
EOF
    
    # Test config
    testparm -s >/dev/null
    log_success "Samba configuration written"
}

create_samba_user() {
    log_info "Setting up Samba user: ${SMB_USER}"
    
    # Create system user if needed
    if ! id "${SMB_USER}" &>/dev/null; then
        log_info "Creating system user ${SMB_USER}"
        useradd -M -s /usr/sbin/nologin "${SMB_USER}"
    fi
    
    # Set Samba password
    if [[ -n "${SMB_PASSWORD}" ]]; then
        (echo "${SMB_PASSWORD}"; echo "${SMB_PASSWORD}") | smbpasswd -s -a "${SMB_USER}"
    else
        log_warn "No SMB_PASSWORD set. You'll need to run: smbpasswd -a ${SMB_USER}"
    fi
    
    log_success "Samba user configured"
}

configure_shares() {
    log_info "Restarting Samba services..."
    
    systemctl enable --now smbd nmbd
    systemctl restart smbd nmbd
    
    # Verify
    sleep 2
    if systemctl is-active --quiet smbd; then
        log_success "Samba running"
        smbstatus -p
    else
        log_error "Samba failed to start"
        systemctl status smbd --no-pager
        return 1
    fi
}

install_webmin() {
    log_info "Installing Webmin..."
    
    if command -v webmin >/dev/null || systemctl is-active --quiet webmin 2>/dev/null; then
        log_info "Webmin already installed"
        return 0
    fi
    
    # Clean old repos
    rm -f /etc/apt/sources.list.d/webmin*.list
    sed -i '/webmin/d' /etc/apt/sources.list
    
    # Install dependencies
    apt-get install -y -qq perl libnet-ssleay-perl openssl libauthen-pam-perl libpam-runtime libio-pty-perl apt-show-versions python3 python-is-python3 gnupg curl
    
    # Use official Webmin setup script
    cd /tmp
    curl -o webmin-setup-repo.sh https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh
    sh webmin-setup-repo.sh --force
    rm webmin-setup-repo.sh
    
    apt-get update -qq
    apt-get install -y -qq webmin
    
    # Configure Webmin
    systemctl enable webmin
    systemctl restart webmin
    
    # Change port if not default
    if [[ "${WEBMIN_PORT}" != "10000" ]]; then
        sed -i "s/^port=.*/port=${WEBMIN_PORT}/" /etc/webmin/miniserv.conf
        sed -i "s/^listen=.*/listen=${WEBMIN_PORT}/" /etc/webmin/miniserv.conf
        systemctl restart webmin
    fi
    
    log_success "Webmin installed on port ${WEBMIN_PORT}"
}

configure_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        log_info "Configuring UFW for Samba and Webmin..."
        ufw allow 137/udp comment "Samba NetBIOS" || true
        ufw allow 138/udp comment "Samba NetBIOS" || true
        ufw allow 139/tcp comment "Samba SMB" || true
        ufw allow 445/tcp comment "Samba SMB" || true
        ufw allow "${WEBMIN_PORT}/tcp" comment "Webmin" || true
        log_success "Firewall rules added"
    fi
}

create_webmin_guide() {
    log_info "Creating Webmin Samba Guide..."
    
    local guide_path="${SCRIPT_DIR}/../docs/webmin_samba_guide.html"
    mkdir -p "$(dirname "${guide_path}")"
    
    cat > "${guide_path}" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Webmin Samba Share Guide</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; line-height: 1.6; max-width: 900px; margin: 0 auto; padding: 20px; background: #f5f5f5; }
        h1 { color: #2c3e50; border-bottom: 3px solid #3498db; padding-bottom: 10px; }
        h2 { color: #34495e; margin-top: 30px; }
        .card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); margin: 20px 0; }
        .step { padding: 15px; border-left: 4px solid #3498db; background: #f8f9fa; margin: 15px 0; }
        .note { background: #fff3cd; border-left: 5px solid #ffeeba; padding: 10px; margin: 10px 0; }
        code { background: #e8f0fe; color: #1a73e8; padding: 2px 6px; border-radius: 3px; font-family: monospace; }
        .warning { background: #f8d7da; border-left: 5px solid #f5c6cb; padding: 10px; margin: 10px 0; }
    </style>
</head>
<body>
    <h1>🔧 Webmin Samba Share Management Guide</h1>
    <p>This guide explains how to manage Samba shares using Webmin's web interface.</p>
    
    <div class="note"><strong>💡 Key Strategy:</strong> We use <code>map to guest = bad user</code> globally. This lets you browse <code>\\IP</code> to see shares. Private shares use <code>Guest Access: No</code> to trigger password prompts.</div>
    
    <h2>🔒 Private Share (Password Required)</h2>
    <div class="card">
        <h3>Step 1: Create Share</h3>
        <div class="step"><strong>Share name:</strong> <code>private_vault</code></div>
        <div class="step"><strong>Directory to share:</strong> <code>/srv/samba/private_vault</code></div>
        <div class="step"><strong>Automatically create directory:</strong> <code>Yes</code></div>
        <div class="step"><strong>Create with owner:</strong> <code>smbdata</code></div>
        <div class="step"><strong>Create with permissions:</strong> <code>2770</code></div>
        <div class="step"><strong>Create with group:</strong> <code>smbdata</code></div>
    </div>
    
    <div class="card">
        <h3>Step 2: Security & Access Control</h3>
        <div class="step"><strong>Writable:</strong> <code>Yes</code></div>
        <div class="step"><strong>Guest Access:</strong> <code>None</code> (Critical!)</div>
        <div class="step"><strong>Valid users:</strong> <code>your_username</code></div>
    </div>
    
    <div class="card">
        <h3>Step 3: File Permission Options</h3>
        <div class="step"><strong>New Unix file mode:</strong> <code>0660</code></div>
        <div class="step"><strong>New Unix directory mode:</strong> <code>2770</code></div>
        <div class="step"><strong>Force Unix user:</strong> <code>smbdata</code></div>
        <div class="step"><strong>Force Unix group:</strong> <code>smbdata</code></div>
    </div>
    
    <h2>🌍 Public Share (No Password)</h2>
    <div class="card">
        <h3>Step 1: Create Share</h3>
        <div class="step"><strong>Share name:</strong> <code>public_drop</code></div>
        <div class="step"><strong>Directory to share:</strong> <code>/srv/samba/public_drop</code></div>
        <div class="step"><strong>Automatically create directory:</strong> <code>Yes</code></div>
        <div class="step"><strong>Create with owner:</strong> <code>smbdata</code></div>
        <div class="step"><strong>Create with permissions:</strong> <code>2777</code></div>
        <div class="step"><strong>Create with group:</strong> <code>smbdata</code></div>
    </div>
    
    <div class="card">
        <h3>Step 2: Security & Access Control</h3>
        <div class="step"><strong>Writable:</strong> <code>Yes</code></div>
        <div class="step"><strong>Guest Access:</strong> <code>Yes</code></div>
        <div class="step"><strong>Guest Unix user:</strong> <code>smbdata</code></div>
        <div class="step"><strong>Valid users:</strong> (Leave Empty)</div>
    </div>
    
    <div class="card">
        <h3>Step 3: File Permission Options</h3>
        <div class="step"><strong>New Unix file mode:</strong> <code>0666</code></div>
        <div class="step"><strong>New Unix directory mode:</strong> <code>2777</code></div>
        <div class="step"><strong>Force Unix user:</strong> <code>smbdata</code></div>
        <div class="step"><strong>Force Unix group:</strong> <code>smbdata</code></div>
    </div>
    
    <div class="warning"><strong>⚠️ Troubleshooting:</strong> If a folder doesn't ask for password when it should, run <code>net use * /delete /y</code> in Windows CMD to clear cached credentials.</div>
</body>
</html>
EOF
    
    # Set ownership
    if id "${PI_USER}" &>/dev/null; then
        chown "${PI_USER}:${PI_USER}" "${guide_path}"
    fi
    chmod 644 "${guide_path}"
    
    log_success "Webmin guide created at ${guide_path}"
}

# Run
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
main "$@"