#!/bin/bash
# Pi Server Setup v2 - Master Installation Script
# Modern, secure, and modular Raspberry Pi server automation
# 
# Usage: sudo ./install.sh [OPTIONS]
# Options:
#   -y, --yes          Non-interactive mode (requires pre-configured settings.conf)
#   -m, --modules      Comma-separated list of modules to install (e.g., "system,network,pihole")
#   -c, --config       Path to configuration file (default: ./settings.conf)
#   -h, --help         Show this help message
#   -v, --version      Show version
#   --dry-run          Validate configuration without making changes
#   --repair           Attempt to repair broken installations
#   --uninstall        Uninstall specific modules or everything

set -euo pipefail

# ============================================================================
# CONSTANTS & GLOBALS
# ============================================================================
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_NAME="pi-server-setup"
readonly CONFIG_FILE_DEFAULT="${SCRIPT_DIR}/settings.conf"
readonly LOG_DIR="/var/log/${PROJECT_NAME}"
readonly LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
readonly STATE_DIR="/var/lib/${PROJECT_NAME}"
readonly BACKUP_DIR="${STATE_DIR}/backups"

# Colors (only if stdout is a terminal)
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly MAGENTA='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly DIM='\033[2m'
    readonly NC='\033[0m' # No Color
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly MAGENTA=''
    readonly CYAN=''
    readonly BOLD=''
    readonly DIM=''
    readonly NC=''
fi

# Module definitions (order matters for dependencies)
readonly MODULES=(
    "system:System Basics (Updates, User, SSH, Tools, Hardening)"
    "network:Network (Tailscale, Firewall, Fail2Ban)"
    "pihole:Pi-hole (DNS Ad-blocking)"
    "monitoring:Monitoring Stack (Prometheus, Grafana, Alertmanager, Node Exporter)"
    "samba:File Sharing (Samba, Webmin)"
    "utils:Utilities (Reports, Cron jobs, Maintenance)"
    "telegram:Telegram Bot (Dual bot: Admin + User)"
    "localsend:LocalSend (File sharing app)"
    "stirling:Stirling-PDF (PDF tools)"
    "nginx:Nginx Reverse Proxy (Local domains)"
    "cockpit:Cockpit (Web-based admin)"
    "n8n:n8n Automation Engine"
)

# Module dependencies
declare -A MODULE_DEPS=(
    ["network"]="system"
    ["pihole"]="system"
    ["monitoring"]="system,network"
    ["samba"]="system"
    ["utils"]="system"
    ["telegram"]="system,monitoring"
    ["localsend"]="system"
    ["stirling"]="system"
    ["nginx"]="system,pihole"
    ["cockpit"]="system"
    ["n8n"]="system,nginx"
)

# Module scripts mapping
declare -A MODULE_SCRIPTS=(
    ["system"]="00-system.sh"
    ["network"]="01-network.sh"
    ["pihole"]="02-pihole.sh"
    ["monitoring"]="03-monitoring.sh"
    ["samba"]="04-samba.sh"
    ["utils"]="05-utils.sh"
    ["telegram"]="06-telegram-bot.sh"
    ["localsend"]="07-localsend.sh"
    ["stirling"]="08-stirling-pdf.sh"
    ["nginx"]="09-reverse-proxy.sh"
    ["cockpit"]="10-cockpit.sh"
    ["n8n"]="11-n8n.sh"
)

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================
log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

log_info()    { log "INFO"    "${BLUE}${*}${NC}"; }
log_success() { log "SUCCESS" "${GREEN}${*}${NC}"; }
log_warn()    { log "WARN"    "${YELLOW}${*}${NC}"; }
log_error()   { log "ERROR"   "${RED}${*}${NC}"; }
log_debug()   { [[ "${DEBUG:-false}" == "true" ]] && log "DEBUG" "${DIM}${*}${NC}"; }

# Progress indicator
show_progress() {
    local current="$1"
    local total="$2"
    local module="$3"
    local pct=$((current * 100 / total))
    printf "\r${CYAN}[%d/%d]${NC} %-20s ${DIM}[%d%%]${NC}" "${current}" "${total}" "${module}" "${pct}"
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================
die() {
    log_error "$*"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)"
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot determine OS version"
    fi
    source /etc/os-release
    if [[ "${ID}" != "raspbian" && "${ID}" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
        log_warn "This script is designed for Raspberry Pi OS (Debian-based). Current: ${PRETTY_NAME}"
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
    log_info "OS: ${PRETTY_NAME}"
}

check_arch() {
    local arch
    arch=$(uname -m)
    case "${arch}" in
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armhf)  ARCH="armv7" ;;
        x86_64|amd64)  ARCH="amd64" ;;
        *) die "Unsupported architecture: ${arch}" ;;
    esac
    log_info "Architecture: ${ARCH}"
    export ARCH
}

setup_directories() {
    mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${BACKUP_DIR}"
    chmod 750 "${LOG_DIR}" "${STATE_DIR}" "${BACKUP_DIR}"
}

sanitize_config() {
    local config_file="$1"
    # Remove Windows line endings
    sed -i 's/\r$//' "${config_file}" 2>/dev/null || true
    # Remove any trailing whitespace
    sed -i 's/[[:space:]]*$//' "${config_file}" 2>/dev/null || true
}

load_config() {
    local config_file="$1"
    if [[ ! -f "${config_file}" ]]; then
        die "Configuration file not found: ${config_file}\nCopy settings.conf.example to settings.conf and configure it."
    fi
    
    # Validate config file permissions
    local perms
    perms=$(stat -c "%a" "${config_file}" 2>/dev/null || stat -f "%A" "${config_file}" 2>/dev/null)
    if [[ "${perms}" != "600" && "${perms}" != "400" ]]; then
        log_warn "Config file has loose permissions (${perms}). Fixing to 600..."
        chmod 600 "${config_file}"
    fi
    
    # shellcheck source=/dev/null
    source "${config_file}"
    log_info "Loaded configuration from ${config_file}"
}

validate_config() {
    local errors=0
    
    # Required variables check
    local required_vars=("PI_USER")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required variable ${var} is not set in config"
            ((errors++))
        fi
    done
    
    # Validate PI_USER format
    if [[ -n "${PI_USER:-}" ]] && ! [[ "${PI_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        log_error "PI_USER must be lowercase alphanumeric with underscores/hyphens only"
        ((errors++))
    fi
    
    # Validate passwords if set (minimum length)
    local pass_vars=("PI_PASSWORD" "GRAFANA_ADMIN_PASSWORD" "PIHOLE_PASSWORD" "SMB_PASSWORD")
    for var in "${pass_vars[@]}"; do
        if [[ -n "${!var:-}" && ${#!var} -lt 8 ]]; then
            log_warn "${var} should be at least 8 characters long"
        fi
    done
    
    # Validate Telegram tokens format
    local token_vars=("TELEGRAM_ADMIN_TOKEN" "TELEGRAM_USER_TOKEN")
    for var in "${token_vars[@]}"; do
        if [[ -n "${!var:-}" ]] && ! [[ "${!var}" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
            log_warn "${var} doesn't look like a valid Telegram bot token (format: 123456:ABC-DEF)"
        fi
    done
    
    # Validate chat IDs
    local chat_vars=("TELEGRAM_ADMIN_CHAT_ID" "TELEGRAM_USER_CHAT_ID")
    for var in "${chat_vars[@]}"; do
        if [[ -n "${!var:-}" ]] && ! [[ "${!var}" =~ ^-?[0-9]+$ ]]; then
            log_warn "${var} should be a numeric chat ID"
        fi
    done
    
    # Validate IP addresses
    local ip_vars=("STATIC_IP" "STATIC_GATEWAY" "STATIC_DNS")
    for var in "${ip_vars[@]}"; do
        if [[ -n "${!var:-}" ]] && ! [[ "${!var}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
            log_warn "${var} doesn't look like a valid IP address/CIDR"
        fi
    done
    
    [[ ${errors} -gt 0 ]] && die "Configuration validation failed with ${errors} error(s)"
    log_success "Configuration validation passed"
}

prompt_missing_config() {
    local config_file="$1"
    local interactive="${2:-true}"
    
    if [[ "${interactive}" != "true" ]]; then
        return 0
    fi
    
    # PI_USER
    if [[ -z "${PI_USER:-}" ]]; then
        read -rp "Enter system username [piadmin]: " PI_USER
        PI_USER="${PI_USER:-piadmin}"
        save_config_var "PI_USER" "${PI_USER}" "${config_file}"
    fi
    
    # PI_PASSWORD
    if [[ -z "${PI_PASSWORD:-}" ]]; then
        read -rsp "Enter password for ${PI_USER} (min 8 chars, empty for random): " PI_PASSWORD
        echo
        if [[ -z "${PI_PASSWORD}" ]]; then
            PI_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
            log_info "Generated random password for ${PI_USER}"
        fi
        save_config_var "PI_PASSWORD" "${PI_PASSWORD}" "${config_file}"
    fi
    
    # GRAFANA_ADMIN_PASSWORD
    if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
        read -rsp "Enter Grafana admin password (min 8 chars, empty for random): " GRAFANA_ADMIN_PASSWORD
        echo
        if [[ -z "${GRAFANA_ADMIN_PASSWORD}" ]]; then
            GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
            log_info "Generated random Grafana password"
        fi
        save_config_var "GRAFANA_ADMIN_PASSWORD" "${GRAFANA_ADMIN_PASSWORD}" "${config_file}"
    fi
    
    # PIHOLE_PASSWORD
    if [[ -z "${PIHOLE_PASSWORD:-}" ]]; then
        read -rsp "Enter Pi-hole admin password (min 8 chars, empty for random): " PIHOLE_PASSWORD
        echo
        if [[ -z "${PIHOLE_PASSWORD}" ]]; then
            PIHOLE_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
            log_info "Generated random Pi-hole password"
        fi
        save_config_var "PIHOLE_PASSWORD" "${PIHOLE_PASSWORD}" "${config_file}"
    fi
    
    # SMB_PASSWORD
    if [[ -z "${SMB_PASSWORD:-}" ]]; then
        read -rsp "Enter Samba password for ${SMB_USER:-smbuser} (min 8 chars, empty for random): " SMB_PASSWORD
        echo
        if [[ -z "${SMB_PASSWORD}" ]]; then
            SMB_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
            log_info "Generated random Samba password"
        fi
        save_config_var "SMB_PASSWORD" "${SMB_PASSWORD}" "${config_file}"
    fi
    
    # TELEGRAM_ADMIN_TOKEN
    if [[ -z "${TELEGRAM_ADMIN_TOKEN:-}" ]]; then
        read -rp "Enter Telegram Admin Bot Token (from @BotFather, or press Enter to skip): " TELEGRAM_ADMIN_TOKEN
        [[ -n "${TELEGRAM_ADMIN_TOKEN}" ]] && save_config_var "TELEGRAM_ADMIN_TOKEN" "${TELEGRAM_ADMIN_TOKEN}" "${config_file}"
    fi
    
    # TELEGRAM_ADMIN_CHAT_ID
    if [[ -n "${TELEGRAM_ADMIN_TOKEN:-}" && -z "${TELEGRAM_ADMIN_CHAT_ID:-}" ]]; then
        read -rp "Enter Telegram Admin Chat ID (your user ID from @userinfobot): " TELEGRAM_ADMIN_CHAT_ID
        [[ -n "${TELEGRAM_ADMIN_CHAT_ID}" ]] && save_config_var "TELEGRAM_ADMIN_CHAT_ID" "${TELEGRAM_ADMIN_CHAT_ID}" "${config_file}"
    fi
    
    # TELEGRAM_USER_TOKEN
    if [[ -z "${TELEGRAM_USER_TOKEN:-}" ]]; then
        read -rp "Enter Telegram User Bot Token (for group status, or press Enter to skip): " TELEGRAM_USER_TOKEN
        [[ -n "${TELEGRAM_USER_TOKEN}" ]] && save_config_var "TELEGRAM_USER_TOKEN" "${TELEGRAM_USER_TOKEN}" "${config_file}"
    fi
    
    # TELEGRAM_USER_CHAT_ID
    if [[ -n "${TELEGRAM_USER_TOKEN:-}" && -z "${TELEGRAM_USER_CHAT_ID:-}" ]]; then
        read -rp "Enter Telegram User Bot Chat ID (group ID, negative number): " TELEGRAM_USER_CHAT_ID
        [[ -n "${TELEGRAM_USER_CHAT_ID}" ]] && save_config_var "TELEGRAM_USER_CHAT_ID" "${TELEGRAM_USER_CHAT_ID}" "${config_file}"
    fi
    
    # TAILSCALE_AUTH_KEY
    if [[ -z "${TAILSCALE_AUTH_KEY:-}" ]]; then
        read -rp "Enter Tailscale Auth Key (or press Enter for interactive login): " TAILSCALE_AUTH_KEY
        [[ -n "${TAILSCALE_AUTH_KEY}" ]] && save_config_var "TAILSCALE_AUTH_KEY" "${TAILSCALE_AUTH_KEY}" "${config_file}"
    fi
    
    # Reload config to pick up new values
    # shellcheck source=/dev/null
    source "${config_file}"
}

save_config_var() {
    local var_name="$1"
    local var_value="$2"
    local config_file="$3"
    
    # Escape value for sed
    local escaped_value
    escaped_value=$(printf '%s\n' "${var_value}" | sed 's/[[\.*^$()+?{|\\]/\\&/g')
    
    if grep -q "^${var_name}=" "${config_file}"; then
        sed -i "s|^${var_name}=.*|${var_name}=\"${escaped_value}\"|" "${config_file}"
    else
        echo "${var_name}=\"${escaped_value}\"" >> "${config_file}"
    fi
    chmod 600 "${config_file}"
}

select_modules() {
    local selected_modules="$1"
    local interactive="${2:-true}"
    
    if [[ -n "${selected_modules}" ]]; then
        # Parse comma-separated list
        IFS=',' read -ra MODULES_TO_INSTALL <<< "${selected_modules}"
        return 0
    fi
    
    if [[ "${interactive}" != "true" ]]; then
        # Default to all modules in non-interactive mode
        MODULES_TO_INSTALL=($(printf '%s\n' "${MODULES[@]}" | cut -d':' -f1))
        return 0
    fi
    
    echo
    echo -e "${BOLD}Select modules to install:${NC}"
    echo "Enter comma-separated numbers (e.g., 1,3,5) or 'all' for everything."
    echo
    
    local i=1
    for module_entry in "${MODULES[@]}"; do
        local module_name="${module_entry%%:*}"
        local module_desc="${module_entry#*:}"
        printf "  ${CYAN}%2d)${NC} %-12s - %s\n" "${i}" "${module_name}" "${module_desc}"
        ((i++))
    done
    
    echo
    read -rp "Selection [all]: " selection
    selection="${selection:-all}"
    
    if [[ "${selection,,}" == "all" || "${selection,,}" == "a" ]]; then
        MODULES_TO_INSTALL=($(printf '%s\n' "${MODULES[@]}" | cut -d':' -f1))
    else
        MODULES_TO_INSTALL=()
        IFS=',' read -ra indices <<< "${selection}"
        for idx in "${indices[@]}"; do
            idx=$(echo "${idx}" | xargs) # trim
            if [[ "${idx}" =~ ^[0-9]+$ ]] && [[ ${idx} -ge 1 && ${idx} -le ${#MODULES[@]} ]]; then
                local module_name
                module_name=$(printf '%s\n' "${MODULES[idx-1]}" | cut -d':' -f1)
                MODULES_TO_INSTALL+=("${module_name}")
            else
                log_warn "Invalid selection: ${idx}"
            fi
        done
    fi
    
    if [[ ${#MODULES_TO_INSTALL[@]} -eq 0 ]]; then
        die "No valid modules selected"
    fi
    
    log_info "Selected modules: ${MODULES_TO_INSTALL[*]}"
}

resolve_dependencies() {
    local -n modules_ref=$1
    local resolved=()
    local processing=()
    
    # Add all requested modules to processing queue
    for module in "${modules_ref[@]}"; do
        processing+=("${module}")
    done
    
    while [[ ${#processing[@]} -gt 0 ]]; do
        local module="${processing[0]}"
        processing=("${processing[@]:1}")
        
        # Skip if already resolved
        [[ " ${resolved[*]} " =~ " ${module} " ]] && continue
        
        # Add dependencies first
        if [[ -n "${MODULE_DEPS[${module}]:-}" ]]; then
            IFS=',' read -ra deps <<< "${MODULE_DEPS[${module}]}"
            for dep in "${deps[@]}"; do
                if [[ ! " ${resolved[*]} " =~ " ${dep} " ]]; then
                    processing=("${dep}" "${processing[@]}")
                fi
            done
        fi
        
        # Check if all deps are resolved
        local all_deps_resolved=true
        if [[ -n "${MODULE_DEPS[${module}]:-}" ]]; then
            IFS=',' read -ra deps <<< "${MODULE_DEPS[${module}]}"
            for dep in "${deps[@]}"; do
                [[ ! " ${resolved[*]} " =~ " ${dep} " ]] && all_deps_resolved=false
            done
        fi
        
        if [[ "${all_deps_resolved}" == "true" ]]; then
            resolved+=("${module}")
        else
            # Put back at end of queue
            processing+=("${module}")
        fi
    done
    
    modules_ref=("${resolved[@]}")
    log_info "Resolved installation order: ${resolved[*]}"
}

check_module_installed() {
    local module="$1"
    case "${module}" in
        system)   command -v btop >/dev/null && systemctl is-active --quiet ssh ;;
        network)  command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1 ;;
        pihole)   command -v pihole >/dev/null ;;
        monitoring) systemctl is-active --quiet prometheus && systemctl is-active --quiet grafana-server ;;
        samba)    systemctl is-active --quiet smbd ;;
        utils)    [[ -f /usr/local/bin/send_report.sh ]] ;;
        telegram) systemctl is-active --quiet telegram-bot ;;
        localsend) [[ -f /opt/localsend/localsend_app ]] || [[ -f /usr/share/applications/localsend_app.desktop ]] ;;
        stirling) systemctl is-active --quiet stirling-pdf ;;
        nginx)    systemctl is-active --quiet nginx ;;
        cockpit)  systemctl is-active --quiet cockpit.socket ;;
        n8n)      systemctl is-active --quiet n8n ;;
        *) return 1 ;;
    esac
}

execute_module() {
    local module="$1"
    local script_name="${MODULE_SCRIPTS[${module}]}"
    local script_path="${SCRIPT_DIR}/scripts/${script_name}"
    
    if [[ ! -f "${script_path}" ]]; then
        log_error "Module script not found: ${script_path}"
        return 1
    fi
    
    log_info "Executing module: ${module} (${script_name})"
    
    # Make executable
    chmod +x "${script_path}"
    
    # Export all config variables for the subscript
    set -a
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
    set +a
    
    # Execute with error handling
    if "${script_path}"; then
        log_success "Module ${module} completed successfully"
        # Mark as installed
        touch "${STATE_DIR}/${module}.installed"
        return 0
    else
        local exit_code=$?
        log_error "Module ${module} failed with exit code ${exit_code}"
        return ${exit_code}
    fi
}

show_summary() {
    local ip
    ip=$(hostname -I | awk '{print $1}')
    
    echo
    echo -e "${BOLD}${CYAN}=========================================${NC}"
    echo -e "${BOLD}${CYAN}   INSTALLATION SUMMARY${NC}"
    echo -e "${BOLD}${CYAN}=========================================${NC}"
    echo -e "Device IP: ${GREEN}${ip}${NC}"
    echo
    
    for module in "${MODULES_TO_INSTALL[@]}"; do
        if [[ -f "${STATE_DIR}/${module}.installed" ]]; then
            echo -e "${GREEN}✓${NC} ${module}"
            case "${module}" in
                system)
                    echo "    SSH:     ssh ${PI_USER}@${ip}"
                    echo "    VNC:     ${ip}:5900"
                    ;;
                network)
                    echo "    Tailscale: Connected"
                    ;;
                pihole)
                    echo "    Web UI:  http://${ip}/admin"
                    echo "    Password: ${PIHOLE_PASSWORD}"
                    ;;
                monitoring)
                    echo "    Prometheus: http://${ip}:9090"
                    echo "    Grafana:    http://${ip}:3000 (admin / ${GRAFANA_ADMIN_PASSWORD})"
                    echo "    Alertmanager: http://${ip}:9093"
                    ;;
                samba)
                    echo "    Webmin: https://${ip}:10000"
                    echo "    Samba:  \\\\${ip}\\${SMB_SHARE_NAME:-pishare}"
                    ;;
                telegram)
                    echo "    Service: telegram-bot.service"
                    ;;
                localsend)
                    echo "    Port: 53317"
                    ;;
                stirling)
                    echo "    URL: http://${ip}:8080"
                    ;;
                nginx)
                    echo "    Domains: dashboard.home, pi.home, n8n.home, etc."
                    echo "    Configure DNS in Pi-hole: http://${ip}:8081/admin/dns_records.php"
                    ;;
                cockpit)
                    echo "    URL: https://${ip}:9091"
                    ;;
                n8n)
                    echo "    URL: http://${ip}:5678 (or http://n8n.home)"
                    ;;
            esac
            echo
        else
            echo -e "${RED}✗${NC} ${module} (failed or skipped)"
        fi
    done
    
    echo -e "${BOLD}${CYAN}=========================================${NC}"
    echo -e "${BOLD}${GREEN}Installation Complete!${NC}"
    echo -e "Log file: ${LOG_FILE}"
    echo -e "${BOLD}${CYAN}=========================================${NC}"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    local config_file="${CONFIG_FILE_DEFAULT}"
    local modules_arg=""
    local non_interactive=false
    local dry_run=false
    local repair_mode=false
    local uninstall_mode=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -y|--yes) non_interactive=true ;;
            -m|--modules) modules_arg="$2"; shift ;;
            -c|--config) config_file="$2"; shift ;;
            -h|--help) 
                cat <<EOF
Usage: sudo ./install.sh [OPTIONS]

Options:
  -y, --yes          Non-interactive mode (requires pre-configured settings.conf)
  -m, --modules      Comma-separated modules to install (e.g., "system,network,pihole")
  -c, --config       Path to configuration file (default: ./settings.conf)
  -h, --help         Show this help message
  -v, --version      Show version
  --dry-run          Validate configuration without making changes
  --repair           Attempt to repair broken installations
  --uninstall        Uninstall specific modules or everything

Available modules: $(printf '%s, ' "${MODULES[@]}" | sed 's/:.*//g' | sed 's/, $//')

Examples:
  sudo ./install.sh                          # Interactive full install
  sudo ./install.sh -y                       # Non-interactive full install
  sudo ./install.sh -m "system,network,pihole"  # Install specific modules
  sudo ./install.sh --dry-run                # Validate config only
EOF
                exit 0
                ;;
            -v|--version) echo "${SCRIPT_VERSION}"; exit 0 ;;
            --dry-run) dry_run=true ;;
            --repair) repair_mode=true ;;
            --uninstall) uninstall_mode=true ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
    
    # Setup
    check_root
    check_os
    check_arch
    setup_directories
    
    log_info "Starting ${PROJECT_NAME} v${SCRIPT_VERSION}"
    log_info "Log file: ${LOG_FILE}"
    
    # Load configuration
    if [[ ! -f "${config_file}" ]]; then
        if [[ -f "${CONFIG_FILE_DEFAULT}" ]]; then
            config_file="${CONFIG_FILE_DEFAULT}"
        else
            die "Configuration file not found. Copy config/settings.conf.example to settings.conf"
        fi
    fi
    
    sanitize_config "${config_file}"
    load_config "${config_file}"
    validate_config
    
    if [[ "${dry_run}" == "true" ]]; then
        log_success "Dry run completed successfully - configuration is valid"
        exit 0
    fi
    
    # Prompt for missing config in interactive mode
    prompt_missing_config "${config_file}" "${non_interactive}"
    
    # Select modules
    select_modules "${modules_arg}" "${non_interactive}"
    
    # Resolve dependencies
    resolve_dependencies MODULES_TO_INSTALL
    
    # Check for already installed modules
    local to_install=()
    for module in "${MODULES_TO_INSTALL[@]}"; do
        if check_module_installed "${module}"; then
            log_warn "Module ${module} appears to be already installed"
            if [[ "${non_interactive}" != "true" ]]; then
                read -rp "Reinstall ${module}? [y/N] " -n 1 -r
                echo
                [[ $REPLY =~ ^[Yy]$ ]] && to_install+=("${module}")
            else
                log_info "Skipping ${module} (already installed)"
            fi
        else
            to_install+=("${module}")
        fi
    done
    
    MODULES_TO_INSTALL=("${to_install[@]}")
    
    if [[ ${#MODULES_TO_INSTALL[@]} -eq 0 ]]; then
        log_info "Nothing to install. Exiting."
        exit 0
    fi
    
    # Confirm before proceeding
    if [[ "${non_interactive}" != "true" ]]; then
        echo
        echo -e "${BOLD}Modules to install:${NC} ${MODULES_TO_INSTALL[*]}"
        read -rp "Proceed with installation? [Y/n] " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
    fi
    
    # Execute modules
    local total=${#MODULES_TO_INSTALL[@]}
    local current=0
    local failed=()
    
    for module in "${MODULES_TO_INSTALL[@]}"; do
        ((current++))
        show_progress "${current}" "${total}" "${module}"
        echo
        
        if execute_module "${module}"; then
            log_success "Module ${module} completed"
        else
            log_error "Module ${module} failed"
            failed+=("${module}")
            if [[ "${non_interactive}" == "true" ]]; then
                die "Module ${module} failed in non-interactive mode"
            fi
            read -rp "Continue with remaining modules? [Y/n] " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && break
        fi
    done
    
    # Summary
    show_summary
    
    if [[ ${#failed[@]} -gt 0 ]]; then
        log_warn "Some modules failed: ${failed[*]}"
        exit 1
    fi
}

# Run main
main "$@"