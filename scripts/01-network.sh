#!/bin/bash
# Network Module - Pi Server Setup v3 (Multi-platform)
# Modular VPN support: Tailscale, Pangolin, or both
# Static IP (optional), Firewall integration - Idempotent design

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/../lib/platform.sh" 2>/dev/null || true

# Configuration (from settings.conf)
VPN_PROVIDER="${VPN_PROVIDER:-pangolin}"  # pangolin, tailscale, both, none

# Tailscale
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
TAILSCALE_EXIT_NODE="${TAILSCALE_EXIT_NODE:-false}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-}"
TAILSCALE_INSTALL_URL="https://tailscale.com/install.sh"

# Pangolin
PANGOLIN_AUTH_KEY="${PANGOLIN_AUTH_KEY:-}"
PANGOLIN_EXIT_NODE="${PANGOLIN_EXIT_NODE:-false}"
PANGOLIN_HOSTNAME="${PANGOLIN_HOSTNAME:-}"
PANGOLIN_INSTALL_URL="https://pangolin.net/install.sh"
PANGOLIN_GUIDE_URL="https://pangolin.net/docs"

# Network
STATIC_IP="${STATIC_IP:-}"
STATIC_GATEWAY="${STATIC_GATEWAY:-}"
STATIC_DNS="${STATIC_DNS:-1.1.1.1}"

# State tracking for idempotency
STATE_DIR="/var/lib/InitOps/state"
NETWORK_STATE_FILE="${STATE_DIR}/network.state"

mkdir -p "${STATE_DIR}"

# ============================================================================
# IDEMPOTENCY HELPERS
# ============================================================================

is_vpn_configured() {
    local provider="$1"
    local key="vpn_${provider}_configured"
    [[ -f "${NETWORK_STATE_FILE}" ]] && grep -q "^${key}=true$" "${NETWORK_STATE_FILE}" 2>/dev/null
}

mark_vpn_configured() {
    local provider="$1"
    local key="vpn_${provider}_configured"
    sed -i "/^${key}=/d" "${NETWORK_STATE_FILE}" 2>/dev/null || true
    echo "${key}=true" >> "${NETWORK_STATE_FILE}"
}

is_static_ip_configured() {
    [[ -f "${NETWORK_STATE_FILE}" ]] && grep -q "^static_ip_configured=true$" "${NETWORK_STATE_FILE}" 2>/dev/null
}

mark_static_ip_configured() {
    sed -i "/^static_ip_configured=/d" "${NETWORK_STATE_FILE}" 2>/dev/null || true
    echo "static_ip_configured=true" >> "${NETWORK_STATE_FILE}"
}

# ============================================================================
# VPN PROVIDER SELECTION
# ============================================================================

select_vpn_provider() {
    # If already configured and not forcing reconfig, use existing
    if [[ -f "${NETWORK_STATE_FILE}" ]] && [[ "${FORCE_VPN_RECONFIG:-false}" != "true" ]]; then
        local saved_provider
        saved_provider=$(grep "^vpn_provider=" "${NETWORK_STATE_FILE}" 2>/dev/null | cut -d= -f2)
        if [[ -n "${saved_provider}" ]]; then
            VPN_PROVIDER="${saved_provider}"
            log_info "Using previously configured VPN provider: ${VPN_PROVIDER}"
            return 0
        fi
    fi
    
    # Non-interactive mode: use config file value
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        log_info "Non-interactive mode: using VPN_PROVIDER=${VPN_PROVIDER} from config"
        return 0
    fi
    
    # Interactive selection
    echo
    echo -e "${BOLD}Select VPN Provider:${NC}"
    echo "  1) Pangolin (https://pangolin.net/) - Recommended: MagicDNS, exit nodes, Pi-hole integration"
    echo "  2) Tailscale (https://tailscale.com/) - Popular, mature, self-hostable (Headscale)"
    echo "  3) Both - Run both VPNs simultaneously (advanced)"
    echo "  4) None - Skip VPN setup (local network only)"
    echo
    
    local default_choice=1
    [[ "${VPN_PROVIDER}" == "tailscale" ]] && default_choice=2
    [[ "${VPN_PROVIDER}" == "both" ]] && default_choice=3
    [[ "${VPN_PROVIDER}" == "none" ]] && default_choice=4
    
    read -rp "Choice [${default_choice}]: " choice
    choice="${choice:-${default_choice}}"
    
    case "${choice}" in
        1) VPN_PROVIDER="pangolin" ;;
        2) VPN_PROVIDER="tailscale" ;;
        3) VPN_PROVIDER="both" ;;
        4) VPN_PROVIDER="none" ;;
        *) 
            log_warn "Invalid choice, defaulting to Pangolin"
            VPN_PROVIDER="pangolin"
            ;;
    esac
    
    # Save selection
    sed -i "/^vpn_provider=/d" "${NETWORK_STATE_FILE}" 2>/dev/null || true
    echo "vpn_provider=${VPN_PROVIDER}" >> "${NETWORK_STATE_FILE}"
    
    log_info "Selected VPN provider: ${VPN_PROVIDER}"
}

# ============================================================================
# TAILSCALE SETUP
# ============================================================================

setup_tailscale() {
    if is_vpn_configured "tailscale" && [[ "${FORCE_VPN_RECONFIG:-false}" != "true" ]]; then
        log_info "Tailscale already configured, skipping (use FORCE_VPN_RECONFIG=true to re-run)"
        return 0
    fi
    
    log_info "Setting up Tailscale VPN..."
    
    # Ensure required tools are available
    for tool in curl ip; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_warn "Required tool '$tool' not found, attempting to install..."
            apt-get update -qq && apt-get install -y -qq "$tool" 2>/dev/null || true
        fi
    done
    
    # Install if not present
    if ! command -v tailscale >/dev/null 2>&1; then
        log_info "Installing Tailscale..."
        curl -fsSL "${TAILSCALE_INSTALL_URL}" | sh
    else
        log_info "Tailscale already installed"
    fi
    
    # Check if already connected
    if tailscale status >/dev/null 2>&1; then
        local ts_ip
        ts_ip=$(tailscale ip -4 2>/dev/null | head -1)
        log_info "Tailscale already connected (IP: ${ts_ip})"
        
        if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
            read -rp "Re-authenticate Tailscale? [y/N] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                mark_vpn_configured "tailscale"
                return 0
            fi
        fi
        tailscale logout
    fi
    
    # Build args
    local ts_args=()
    
    if [[ "${TAILSCALE_EXIT_NODE}" == "true" ]]; then
        ts_args+=("--advertise-exit-node")
        log_info "Will advertise as exit node"
    fi
    
    if [[ -n "${TAILSCALE_HOSTNAME}" ]]; then
        ts_args+=("--hostname=${TAILSCALE_HOSTNAME}")
        log_info "Using custom hostname: ${TAILSCALE_HOSTNAME}"
    fi
    
    # Advertise LAN subnet
    local lan_subnet
    lan_subnet=$(ip route | grep -E '^192\.168|^10\.|^172\.(1[6-9]|2[0-9]|3[01])\.' | head -1 | awk '{print $1}')
    if [[ -n "${lan_subnet}" ]]; then
        ts_args+=("--advertise-routes=${lan_subnet}")
        log_info "Will advertise route: ${lan_subnet}"
    fi
    
    # Authenticate
    if [[ -n "${TAILSCALE_AUTH_KEY}" ]]; then
        log_info "Authenticating with auth key..."
        tailscale up "${ts_args[@]}" --authkey="${TAILSCALE_AUTH_KEY}"
    else
        log_info "Starting interactive authentication..."
        echo "A browser window will open for authentication."
        tailscale up "${ts_args[@]}"
    fi
    
    # Verify
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
        
        mark_vpn_configured "tailscale"
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

# ============================================================================
# PANGOLIN SETUP
# ============================================================================

setup_pangolin() {
    if is_vpn_configured "pangolin" && [[ "${FORCE_VPN_RECONFIG:-false}" != "true" ]]; then
        log_info "Pangolin already configured, skipping (use FORCE_VPN_RECONFIG=true to re-run)"
        return 0
    fi
    
    log_info "Setting up Pangolin VPN (https://pangolin.net/)..."
    
    # Ensure required tools are available
    for tool in curl ip; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_warn "Required tool '$tool' not found, attempting to install..."
            apt-get update -qq && apt-get install -y -qq "$tool" 2>/dev/null || true
        fi
    done
    
    # Install if not present
    if ! command -v pangolin >/dev/null 2>&1; then
        log_info "Installing Pangolin..."
        curl -fsSL "${PANGOLIN_INSTALL_URL}" | sh
    else
        log_info "Pangolin already installed"
    fi
    
    # Check if already connected
    if pangolin status >/dev/null 2>&1; then
        local pg_ip
        pg_ip=$(pangolin ip -4 2>/dev/null | head -1)
        log_info "Pangolin already connected (IP: ${pg_ip})"
        
        if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
            read -rp "Re-authenticate Pangolin? [y/N] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                mark_vpn_configured "pangolin"
                return 0
            fi
        fi
        pangolin logout
    fi
    
    # Build args
    local pg_args=()
    
    if [[ "${PANGOLIN_EXIT_NODE}" == "true" ]]; then
        pg_args+=("--advertise-exit-node")
        log_info "Will advertise as exit node"
    fi
    
    if [[ -n "${PANGOLIN_HOSTNAME}" ]]; then
        pg_args+=("--hostname=${PANGOLIN_HOSTNAME}")
        log_info "Using custom hostname: ${PANGOLIN_HOSTNAME}"
    fi
    
    # Advertise LAN subnet
    local lan_subnet
    lan_subnet=$(ip route | grep -E '^192\.168|^10\.|^172\.(1[6-9]|2[0-9]|3[01])\.' | head -1 | awk '{print $1}')
    if [[ -n "${lan_subnet}" ]]; then
        pg_args+=("--advertise-routes=${lan_subnet}")
        log_info "Will advertise route: ${lan_subnet}"
    fi
    
    # Authenticate
    if [[ -n "${PANGOLIN_AUTH_KEY}" ]]; then
        log_info "Authenticating with auth key..."
        pangolin up "${pg_args[@]}" --authkey="${PANGOLIN_AUTH_KEY}"
    else
        log_info "Starting interactive authentication..."
        echo "A browser window will open for authentication."
        pangolin up "${pg_args[@]}"
    fi
    
    # Verify
    sleep 3
    if pangolin status >/dev/null 2>&1; then
        local pg_ip
        pg_ip=$(pangolin ip -4 2>/dev/null | head -1)
        log_success "Pangolin connected! IP: ${pg_ip}"
        
        if [[ "${PANGOLIN_EXIT_NODE}" == "true" ]]; then
            log_warn "IMPORTANT: Enable exit node in Pangolin admin console:"
            log_warn "  ${PANGOLIN_GUIDE_URL}/admin/machines"
            log_warn "  Find this device -> Edit Route Settings -> Enable 'Use as exit node'"
        fi
        
        mark_vpn_configured "pangolin"
    else
        log_error "Pangolin connection failed"
        return 1
    fi
}

configure_pangolin_dns() {
    if ! pangolin status >/dev/null 2>&1; then
        return 0
    fi
    
    log_info "Configuring Pangolin DNS (MagicDNS + Global Nameservers)..."
    
    local pg_ip
    pg_ip=$(pangolin ip -4 2>/dev/null | head -1)
    
    if [[ -z "${pg_ip}" ]]; then
        log_warn "Could not determine Pangolin IP, skipping DNS config"
        return 0
    fi
    
    cat <<EOF

${YELLOW}=== Pangolin DNS Configuration Required ===${NC}
For full remote ad-blocking and MagicDNS, configure in Pangolin Admin Console:
  ${PANGOLIN_GUIDE_URL}/admin/dns

1. MagicDNS: Enable "MagicDNS" for automatic hostname resolution
2. Global Nameservers: Add nameserver -> ${pg_ip} (this Pi's Pangolin IP)
3. Enable "Override local DNS" to force all DNS through Pi-hole

This allows remote devices to use Pi-hole for ad-blocking over Pangolin.
See also: docs/PANGOLIN_GUIDE.md
EOF
}

# ============================================================================
# STATIC IP CONFIGURATION (with warnings)
# ============================================================================

configure_static_ip() {
    if [[ -z "${STATIC_IP}" ]]; then
        log_info "Static IP not configured in settings, skipping..."
        return 0
    fi
    
    if is_static_ip_configured && [[ "${FORCE_STATIC_IP:-false}" != "true" ]]; then
        log_info "Static IP already configured, skipping (use FORCE_STATIC_IP=true to re-run)"
        return 0
    fi
    
    log_warn "================================================================"
    log_warn "WARNING: Configuring static IP remotely can disconnect you!"
    log_warn "It is STRONGLY recommended to set a DHCP reservation in your"
    log_warn "router instead of configuring static IP on the device."
    log_warn "================================================================"
    
    if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
        read -rp "Are you sure you want to configure static IP on this device? [y/N] " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "Skipping static IP configuration"; return 0; }
    fi
    
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
    
    if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
        read -rp "Confirm these settings? [y/N] " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "Cancelled"; return 0; }
    fi
    
    # Backup dhcpcd.conf
    cp /etc/dhcpcd.conf "/etc/dhcpcd.conf.bak.$(date +%Y%m%d_%H%M%S)"
    
    # Remove any existing static config for this interface
    sed -i "/^interface ${interface}$/,/^$/d" /etc/dhcpcd.conf
    
    # Append new configuration
    cat >> /etc/dhcpcd.conf <<EOF

# Static IP Configuration by InitOps
interface ${interface}
static ip_address=${ip_addr}/${cidr}
static routers=${gateway}
static domain_name_servers=${dns}
EOF
    
    log_success "Static IP configured. Reboot required to take effect."
    log_warn "You may lose connection after reboot if settings are incorrect!"
    
    mark_static_ip_configured
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    log_info "Starting Network setup..."
    
    # Detect platform
    detect_platform
    
    # Select VPN provider
    select_vpn_provider
    
    # Setup selected VPN(s)
    case "${VPN_PROVIDER}" in
        tailscale)
            setup_tailscale
            configure_tailscale_dns
            ;;
        pangolin)
            setup_pangolin
            configure_pangolin_dns
            ;;
        both)
            setup_tailscale
            configure_tailscale_dns
            setup_pangolin
            configure_pangolin_dns
            ;;
        none)
            log_info "No VPN provider selected, skipping VPN setup"
            ;;
        *)
            log_error "Unknown VPN provider: ${VPN_PROVIDER}"
            return 1
            ;;
    esac
    
    # Configure Static IP (optional)
    configure_static_ip
    
    log_success "Network setup completed!"
}

main "$@"