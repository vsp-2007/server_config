#!/bin/bash
# Network Module - Pi Server Setup v2
# Tailscale, Static IP (optional), Firewall integration

set -euo pipefail

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

# Configuration variables
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
TAILSCALE_EXIT_NODE="${TAILSCALE_EXIT_NODE:-false}"
STATIC_IP="${STATIC_IP:-}"
STATIC_GATEWAY="${STATIC_GATEWAY:-}"
STATIC_DNS="${STATIC_DNS:-1.1.1.1}"

main() {
    log_info "Starting Network setup..."
    
    # 1. Install and configure Tailscale
    setup_tailscale
    
    # 2. Configure Static IP (optional, with warnings)
    configure_static_ip
    
    # 3. Configure MagicDNS / Global Nameservers (if Tailscale is active)
    configure_tailscale_dns
    
    log_success "Network setup completed!"
}

setup_tailscale() {
    log_info "Setting up Tailscale..."
    
    # Install Tailscale if not present
    if ! command -v tailscale >/dev/null 2>&1; then
        log_info "Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
    else
        log_info "Tailscale already installed"
    fi
    
    # Check if already connected
    if tailscale status >/dev/null 2>&1; then
        log_info "Tailscale is already connected"
        local ts_ip
        ts_ip=$(tailscale ip -4 2>/dev/null | head -1)
        log_info "Tailscale IP: ${ts_ip}"
        
        read -rp "Re-authenticate Tailscale? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            tailscale logout
        else
            return 0
        fi
    fi
    
    # Prepare tailscale up arguments
    local ts_args=()
    
    # Exit node
    if [[ "${TAILSCALE_EXIT_NODE}" == "true" ]]; then
        ts_args+=("--advertise-exit-node")
        log_info "Will advertise as exit node"
    fi
    
    # Advertise routes for local subnet
    local lan_subnet
    lan_subnet=$(ip route | grep -E '^192\.168|^10\.|^172\.(1[6-9]|2[0-9]|3[01])\.' | head -1 | awk '{print $1}')
    if [[ -n "${lan_subnet}" ]]; then
        ts_args+=("--advertise-routes=${lan_subnet}")
        log_info "Will advertise route: ${lan_subnet}"
    fi
    
    # Authenticate
    if [[ -n "${TAILSCALE_AUTH_KEY}" ]]; then
        log_info "Authenticating with provided auth key..."
        tailscale up "${ts_args[@]}" --authkey="${TAILSCALE_AUTH_KEY}"
    else
        log_info "No auth key provided. Starting interactive login..."
        echo "A browser window will open for authentication."
        tailscale up "${ts_args[@]}"
    fi
    
    # Verify connection
    sleep 3
    if tailscale status >/dev/null 2>&1; then
        local ts_ip
        ts_ip=$(tailscale ip -4 2>/dev/null | head -1)
        log_success "Tailscale connected! IP: ${ts_ip}"
        
        if [[ "${TAILSCALE_EXIT_NODE}" == "true" ]]; then
            log_warn "IMPORTANT: Enable exit node in Tailscale admin console:"
            log_warn "  https://login.tailscale.com/admin/machines"
            log_warn "  Find this device -> Edit Route Settings -> Enable 'Use as exit node'"
        fi
    else
        log_error "Tailscale connection failed"
        return 1
    fi
}

configure_tailscale_dns() {
    if ! tailscale status >/dev/null 2>&1; then
        return 0
    fi
    
    log_info "Configuring Tailscale DNS (MagicDNS + Global Nameservers)..."
    
    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null | head -1)
    
    if [[ -z "${ts_ip}" ]]; then
        log_warn "Could not determine Tailscale IP, skipping DNS config"
        return 0
    fi
    
    # Note: These settings must be configured in the Tailscale admin console
    # We can only provide guidance here
    cat <<EOF

${YELLOW}=== Tailscale DNS Configuration Required ===${NC}
For full remote ad-blocking and MagicDNS, configure in Tailscale Admin Console:
  https://login.tailscale.com/admin/dns

1. MagicDNS: Enable "MagicDNS" for automatic hostname resolution
2. Global Nameservers: Add nameserver -> ${ts_ip} (this Pi's Tailscale IP)
3. Enable "Override local DNS" to force all DNS through Pi-hole

This allows remote devices to use Pi-hole for ad-blocking over Tailscale.
EOF
}

configure_static_ip() {
    if [[ -z "${STATIC_IP}" ]]; then
        log_info "Static IP not configured in settings, skipping..."
        return 0
    fi
    
    log_warn "================================================================"
    log_warn "WARNING: Configuring static IP remotely can disconnect you!"
    log_warn "It is STRONGLY recommended to set a DHCP reservation in your"
    log_warn "router instead of configuring static IP on the device."
    log_warn "================================================================"
    
    read -rp "Are you sure you want to configure static IP on this device? [y/N] " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "Skipping static IP configuration"; return 0; }
    
    log_info "Configuring static IP: ${STATIC_IP}"
    
    # Determine interface
    local interface
    interface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -z "${interface}" ]]; then
        interface="eth0"
    fi
    
    # Parse CIDR
    local ip_addr="${STATIC_IP%%/*}"
    local cidr="${STATIC_IP#*/}"
    [[ "${cidr}" == "${STATIC_IP}" ]] && cidr="24"
    
    # Gateway
    local gateway="${STATIC_GATEWAY}"
    if [[ -z "${gateway}" ]]; then
        gateway=$(ip route | grep default | awk '{print $3}' | head -1)
    fi
    
    # DNS
    local dns="${STATIC_DNS}"
    
    log_info "Interface: ${interface}"
    log_info "IP: ${ip_addr}/${cidr}"
    log_info "Gateway: ${gateway}"
    log_info "DNS: ${dns}"
    
    read -rp "Confirm these settings? [y/N] " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "Cancelled"; return 0; }
    
    # Backup dhcpcd.conf
    cp /etc/dhcpcd.conf "/etc/dhcpcd.conf.bak.$(date +%Y%m%d_%H%M%S)"
    
    # Remove any existing static config for this interface
    sed -i "/^interface ${interface}$/,/^$/d" /etc/dhcpcd.conf
    
    # Append new configuration
    cat >> /etc/dhcpcd.conf <<EOF

# Static IP Configuration by pi-server-setup
interface ${interface}
static ip_address=${ip_addr}/${cidr}
static routers=${gateway}
static domain_name_servers=${dns}
EOF
    
    log_success "Static IP configured. Reboot required to take effect."
    log_warn "You may lose connection after reboot if settings are incorrect!"
}

# Run main
main "$@"