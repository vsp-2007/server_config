#!/bin/bash
# Pi-hole Module - Pi Server Setup v2
# Network-wide DNS ad-blocking with custom blocklists

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

# Colors (fallback if common.sh not sourced)
if ! command -v log_info &>/dev/null; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly NC='\033[0m'

    log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
    log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
    log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
    log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
    log_debug()   { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${NC}[DEBUG]${NC} $*"; }
fi

# Configuration
PIHOLE_PASSWORD="${PIHOLE_PASSWORD:-}"
PIHOLE_BLOCKLISTS="${PIHOLE_BLOCKLISTS:-}"
PIHOLE_INTERFACE="${PIHOLE_INTERFACE:-}"
PIHOLE_UPSTREAM_DNS="${PIHOLE_UPSTREAM_DNS:-1.1.1.1,9.9.9.9,8.8.8.8}"

main() {
    log_info "Starting Pi-hole setup..."
    
    # 1. Install dependencies
    install_dependencies
    
    # 2. Install Pi-hole
    install_pihole
    
    # 3. Configure blocklists
    configure_blocklists
    
    # 4. Set password
    set_pihole_password
    
    # 5. Configure automated whitelisting
    configure_whitelisting
    
    # 6. Update gravity
    update_gravity
    
    log_success "Pi-hole setup completed!"
}

install_dependencies() {
    log_info "Installing dependencies..."
    
    apt-get install -y -qq sqlite3 curl jq
}

install_pihole() {
    if command -v pihole >/dev/null 2>&1; then
        log_info "Pi-hole is already installed"
        return 0
    fi
    
    log_info "Installing Pi-hole..."
    
    # Detect interface if not set
    if [[ -z "${PIHOLE_INTERFACE}" ]]; then
        PIHOLE_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    fi
    
    local ip_addr
    ip_addr=$(hostname -I | awk '{print $1}')
    
    # Create setup variables for unattended install
    cat > /etc/pihole/setupVars.conf <<EOF
PIHOLE_INTERFACE=${PIHOLE_INTERFACE}
IPV4_ADDRESS=${ip_addr}/24
IPV6_ADDRESS=
PIHOLE_DNS_1=${PIHOLE_UPSTREAM_DNS%%,*}
PIHOLE_DNS_2=${PIHOLE_UPSTREAM_DNS#*,}
PIHOLE_DNS_3=
PIHOLE_DNS_4=
QUERY_LOGGING=true
INSTALL_WEB_INTERFACE=true
INSTALL_WEB_SERVER=true
LIGHTTPD_ENABLED=true
CUSTOM_CNAME_RECORDS=
CUSTOM_DNS_RECORDS=
BLOCKING_ENABLED=true
ADMIN_PASSWORD=
EOF
    
    # Download and run installer
    curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended
    
    # Wait for FTL to start
    log_info "Waiting for Pi-hole FTL to start..."
    sleep 10
    
    log_success "Pi-hole installed"
}

configure_blocklists() {
    log_info "Configuring blocklists..."
    
    local gravity_db="/etc/pihole/gravity.db"
    
    # Wait for database to be ready
    local retries=30
    while [[ ! -f "${gravity_db}" && ${retries} -gt 0 ]]; do
        sleep 1
        ((retries--))
    done
    
    if [[ ! -f "${gravity_db}" ]]; then
        log_error "Gravity database not found after installation"
        return 1
    fi
    
    # Default blocklists (curated for balance of coverage and false positives)
    local default_blocklists=(
        "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/gambling-porn/hosts"
        "https://raw.githubusercontent.com/PolishFiltersTeam/KADhosts/master/KADhosts.txt"
        "https://v.firebog.net/hosts/AdguardDNS.txt"
        "https://adaway.org/hosts.txt"
        "https://v.firebog.net/hosts/Admiral.txt"
        "https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt"
        "https://v.firebog.net/hosts/Easylist.txt"
        "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext"
        "https://raw.githubusercontent.com/FadeMind/hosts.extras/master/UncheckyAds/hosts"
        "https://raw.githubusercontent.com/bigdargon/hostsVN/master/hosts"
        "https://v.firebog.net/hosts/Easyprivacy.txt"
        "https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.2o7Net/hosts"
        "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt"
        "https://hostfiles.frogeye.fr/firstparty-trackers-hosts.txt"
        "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareHosts.txt"
        "https://v.firebog.net/hosts/Prigent-Crypto.txt"
        "https://raw.githubusercontent.com/FadeMind/hosts.extras/master/add.Risk/hosts"
        "https://phishing.army/download/phishing_army_blocklist_extended.txt"
        "https://gitlab.com/quidsup/notrack-blocklists/raw/master/notrack-malware.txt"
        "https://raw.githubusercontent.com/Spam404/lists/master/main-blacklist.txt"
        "https://raw.githubusercontent.com/AssoEchap/stalkerware-indicators/master/generated/hosts"
        "https://urlhaus.abuse.ch/downloads/hostfile/"
        "https://lists.cyberhost.uk/malware.txt"
    )
    
    # Add custom blocklists from config
    local all_blocklists=("${default_blocklists[@]}")
    if [[ -n "${PIHOLE_BLOCKLISTS}" ]]; then
        IFS=',' read -ra custom_lists <<< "${PIHOLE_BLOCKLISTS}"
        for list in "${custom_lists[@]}"; do
            list=$(echo "${list}" | xargs) # trim
            [[ -n "${list}" ]] && all_blocklists+=("${list}")
        done
    fi
    
    log_info "Adding ${#all_blocklists[@]} blocklists to gravity database..."
    
    for url in "${all_blocklists[@]}"; do
        [[ -z "${url}" ]] && continue
        
        # Check if already exists
        if sqlite3 "${gravity_db}" "SELECT COUNT(*) FROM adlist WHERE address = '${url}';" | grep -q "^0$"; then
            sqlite3 "${gravity_db}" "INSERT INTO adlist (address, enabled, comment) VALUES ('${url}', 1, 'Added by InitOps');"
            log_debug "Added blocklist: ${url}"
        else
            log_debug "Blocklist already exists: ${url}"
        fi
    done
    
    log_success "Blocklists configured"
}

set_pihole_password() {
    if [[ -z "${PIHOLE_PASSWORD}" ]]; then
        log_info "No Pi-hole password set in config. You can set it later with: pihole -a -p"
        return 0
    fi
    
    log_info "Setting Pi-hole admin password..."
    
    # Wait for FTL
    sleep 5
    
    # Use pihole setpassword (interactive) but we can pipe
    echo "${PIHOLE_PASSWORD}" | pihole -a -p
    
    log_success "Pi-hole password set"
}

configure_whitelisting() {
    log_info "Configuring automated whitelisting (AnudeepND)..."
    
    # Download the Python script (modern replacement for shell script)
    curl -sS https://raw.githubusercontent.com/anudeepND/whitelist/master/scripts/whitelist.py -o /usr/local/bin/pihole-whitelist.py
    chmod +x /usr/local/bin/pihole-whitelist.py
    
    # Run it once
    python3 /usr/local/bin/pihole-whitelist.py || log_warn "Initial whitelist run had issues"
    
    # Add to cron for weekly updates (Sunday 3 AM)
    (crontab -l 2>/dev/null | grep -v "pihole-whitelist"; echo "0 3 * * 0 /usr/bin/python3 /usr/local/bin/pihole-whitelist.py >/dev/null 2>&1") | crontab -
    
    log_success "Automated whitelisting configured (weekly updates)"
}

update_gravity() {
    log_info "Updating gravity (downloading blocklists)..."
    
    pihole -g
    
    log_success "Gravity updated"
}

# Run main
main "$@"