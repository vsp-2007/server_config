#!/bin/bash
# Cockpit Module - Pi Server Setup v2
# Web-based system administration

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
COCKPIT_PORT="${COCKPIT_PORT:-9091}"

main() {
    log_info "Starting Cockpit setup..."
    
    install_cockpit
    configure_cockpit
    configure_firewall
    
    log_success "Cockpit setup completed!"
}

install_cockpit() {
    log_info "Installing Cockpit..."
    
    if command -v cockpit-bridge >/dev/null 2>&1 || systemctl is-active --quiet cockpit.socket 2>/dev/null; then
        log_info "Cockpit already installed"
    else
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cockpit cockpit-packagekit cockpit-storaged cockpit-networkmanager
    fi
    
    # Enable and start
    systemctl enable --now cockpit.socket
}

configure_cockpit() {
    log_info "Configuring Cockpit on port ${COCKPIT_PORT}..."
    
    # Override socket to use custom port
    mkdir -p /etc/systemd/system/cockpit.socket.d
    cat > /etc/systemd/system/cockpit.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=${COCKPIT_PORT}
EOF
    
    # Configure cockpit.conf for additional security
    mkdir -p /etc/cockpit
    cat > /etc/cockpit/cockpit.conf <<EOF
[WebService]
Origins = https://localhost:${COCKPIT_PORT} http://localhost:${COCKPIT_PORT}
AllowUnencrypted = true
MaxStartups = 10

[Session]
Timeout = 30
IdleTimeout = 15

[Auth]
Action = none
EOF
    
    systemctl daemon-reload
    systemctl restart cockpit.socket
    
    # Verify
    sleep 2
    if systemctl is-active --quiet cockpit.socket; then
        log_success "Cockpit running on port ${COCKPIT_PORT}"
    else
        log_error "Cockpit failed to start"
        systemctl status cockpit.socket --no-pager
        return 1
    fi
}

configure_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        log_info "Configuring UFW for Cockpit..."
        ufw allow "${COCKPIT_PORT}/tcp" comment "Cockpit" || true
        log_success "Firewall rule added"
    fi
}

# Run
main "$@"