#!/bin/bash
# Pi Server Setup v2 - Master Installation Script
# Modern, secure, and modular server automation for any Debian 13+/Ubuntu 24.04+ system

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
    readonly NC='\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' BOLD='' DIM='' NC=''
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
    local level="$1"; shift; local msg="$*"
    local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

log_info()    { log "INFO"    "${BLUE}${*}${NC}"; }
log_success() { log "SUCCESS" "${GREEN}${*}${NC}"; }
log_warn()    { log "WARN"    "${YELLOW}${*}${NC}"; }
log_error()   { log "ERROR"   "${RED}${*}${NC}"; }
log_debug()   { [[ "${DEBUG:-false}" == "true" ]] && log "DEBUG" "${DIM}${*}${NC}"; }

# Progress indicator
show_progress() {
    local current="$1" total="$2" module="$3"
    local pct=$((current * 100 / total))
    printf "\r${CYAN}[%d/%d]${NC} %-20s ${DIM}[%d%%]${NC}" "${current}" "${total}" "${module}" "${pct}"
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================
die() { log_error "$*"; exit 1; }

check_root() { [[ $EUID -ne 0 ]] && die "This script must be run as root (use sudo)"; }

check_os() {
    [[ ! -f /etc/os-release ]] && die "Cannot determine OS version"
    source /etc/os-release
    if [[ "${ID}" != "raspbian" && "${ID}" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
        log_warn "Designed for Debian-based OS. Current: ${PRETTY_NAME}"
        read -p "Continue anyway? [y/N] " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
    log_info "OS: ${PRETTY_NAME}"
}

check_arch() {
    local arch; arch=$(uname -m)
    case "${arch}" in
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armhf)  ARCH="armv7" ;;
        x86_64|amd64)  ARCH="amd64" ;;
        *) die "Unsupported architecture: ${arch}" ;;
    esac
    log_info "Architecture: ${ARCH}"; export ARCH
}

setup_directories() {
    mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${BACKUP_DIR}"
    chmod 750 "${LOG_DIR}" "${STATE_DIR}" "${BACKUP_DIR}"
}

sanitize_config() {
    local config_file="$1"
    sed -i 's/\r$//' "${config_file}" 2>/dev/null || true
    sed -i 's/[[:space:]]*$//' "${config_file}" 2>/dev/null || true
}

load_config() {
    local config_file="$1"
    [[ ! -f "${config_file}" ]] && die "Config file not found: ${config_file}\nCopy settings.conf.example to settings.conf"
    
    local perms; perms=$(stat -c "%a" "${config_file}" 2>/dev/null || stat -f "%A" "${config_file}" 2>/dev/null)
    [[ "${perms}" != "600" && "${perms}" != "400" ]] && { log_warn "Config permissions loose (${perms}), fixing to 600"; chmod 600 "${config_file}"; }
    
    # shellcheck source=/dev/null
    source "${config_file}"
    log_info "Loaded configuration from ${config_file}"
}

# Input validation helpers
validate_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]; }
validate_password() { [[ ${#1} -ge 8 ]]; }
validate_token() { [[ "$1" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; }
validate_chat_id() { [[ "$1" =~ ^-?[0-9]+$ ]]; }
validate_ip_cidr() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; }

validate_config() {
    local errors=0
    [[ -z "${PI_USER:-}" ]] && { log_error "Required variable PI_USER is not set"; ((errors++)); }
    [[ -n "${PI_USER:-}" ]] && ! validate_username "${PI_USER}" && { log_error "PI_USER must be lowercase alphanumeric with underscores/hyphens"; ((errors++)); }
    
    local pass_vars=("PI_PASSWORD" "GRAFANA_ADMIN_PASSWORD" "PIHOLE_PASSWORD" "SMB_PASSWORD")
    for var in "${pass_vars[@]}"; do [[ -n "${!var:-}" ]] && ! validate_password "${!var}" && log_warn "${var} should be at least 8 characters"; done
    
    local token_vars=("TELEGRAM_ADMIN_TOKEN" "TELEGRAM_USER_TOKEN")
    for var in "${token_vars[@]}"; do [[ -n "${!var:-}" ]] && ! validate_token "${!var}" && log_warn "${var} doesn't look like valid Telegram bot token"; done
    
    local chat_vars=("TELEGRAM_ADMIN_CHAT_ID" "TELEGRAM_USER_CHAT_ID")
    for var in "${chat_vars[@]}"; do [[ -n "${!var:-}" ]] && ! validate_chat_id "${!var}" && log_warn "${var} should be numeric chat ID"; done
    
    local ip_vars=("STATIC_IP" "STATIC_GATEWAY" "STATIC_DNS")
    for var in "${ip_vars[@]}"; do [[ -n "${!var:-}" ]] && ! validate_ip_cidr "${!var}" && log_warn "${var} doesn't look like valid IP/CIDR"; done
    
    [[ ${errors} -gt 0 ]] && die "Configuration validation failed with ${errors} error(s)"
    log_success "Configuration validation passed"
}

# ============================================================================
# INTERACTIVE CONFIGURATION PROMPTING
# ============================================================================
prompt_missing_config() {
    local config_file="$1"
    local interactive="${2:-true}"
    [[ "${interactive}" != "true" ]] && return 0
    
    echo -e "\n${BOLD}${CYAN}=== Interactive Configuration ===${NC}"
    echo "Missing required values will be prompted. Press Enter to use defaults or generate random values."
    echo
    
    # Helper: prompt with validation
    prompt_with_validation() {
        local var_name="$1" prompt_text="$2" validator="$3" default="$4" is_secret="$5"
        local value
        while true; do
            if [[ "${is_secret}" == "true" ]]; then
                read -rsp "${prompt_text}: " value; echo
            else
                read -rp "${prompt_text} [${default}]: " value
                value="${value:-${default}}"
            fi
            if [[ -z "${value}" && -n "${default}" ]]; then value="${default}"; break; fi
            if [[ -n "${value}" ]] && ${validator} "${value}"; then break; fi
            log_warn "Invalid input, please try again."
        done
        printf -v "${var_name}" '%s' "${value}"
        save_config_var "${var_name}" "${value}" "${config_file}"
    }
    
    # PI_USER
    [[ -z "${PI_USER:-}" ]] && prompt_with_validation PI_USER "Enter system username" validate_username "piadmin" false
    
    # PI_PASSWORD
    [[ -z "${PI_PASSWORD:-}" ]] && prompt_with_validation PI_PASSWORD "Enter password for ${PI_USER} (min 8 chars, empty for random)" validate_password "" true
    [[ -z "${PI_PASSWORD}" ]] && { PI_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16); log_info "Generated random password for ${PI_USER}"; save_config_var "PI_PASSWORD" "${PI_PASSWORD}" "${config_file}"; }
    
    # GRAFANA_ADMIN_PASSWORD
    [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]] && prompt_with_validation GRAFANA_ADMIN_PASSWORD "Enter Grafana admin password (min 8 chars, empty for random)" validate_password "" true
    [[ -z "${GRAFANA_ADMIN_PASSWORD}" ]] && { GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16); log_info "Generated random Grafana password"; save_config_var "GRAFANA_ADMIN_PASSWORD" "${GRAFANA_ADMIN_PASSWORD}" "${config_file}"; }
    
    # PIHOLE_PASSWORD
    [[ -z "${PIHOLE_PASSWORD:-}" ]] && prompt_with_validation PIHOLE_PASSWORD "Enter Pi-hole admin password (min 8 chars, empty for random)" validate_password "" true
    [[ -z "${PIHOLE_PASSWORD}" ]] && { PIHOLE_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16); log_info "Generated random Pi-hole password"; save_config_var "PIHOLE_PASSWORD" "${PIHOLE_PASSWORD}" "${config_file}"; }
    
    # SMB_PASSWORD
    [[ -z "${SMB_PASSWORD:-}" ]] && prompt_with_validation SMB_PASSWORD "Enter Samba password for ${SMB_USER:-smbuser} (min 8 chars, empty for random)" validate_password "" true
    [[ -z "${SMB_PASSWORD}" ]] && { SMB_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16); log_info "Generated random Samba password"; save_config_var "SMB_PASSWORD" "${SMB_PASSWORD}" "${config_file}"; }
    
    # Optional: Telegram Admin Bot
    echo -e "\n${CYAN}--- Telegram Bot Configuration (Optional) ---${NC}"
    if [[ -z "${TELEGRAM_ADMIN_TOKEN:-}" ]]; then
        read -rp "Enter Telegram Admin Bot Token (from @BotFather, or press Enter to skip): " TELEGRAM_ADMIN_TOKEN
        [[ -n "${TELEGRAM_ADMIN_TOKEN}" ]] && save_config_var "TELEGRAM_ADMIN_TOKEN" "${TELEGRAM_ADMIN_TOKEN}" "${config_file}"
    fi
    if [[ -n "${TELEGRAM_ADMIN_TOKEN:-}" && -z "${TELEGRAM_ADMIN_CHAT_ID:-}" ]]; then
        read -rp "Enter Telegram Admin Chat ID (your user ID from @userinfobot): " TELEGRAM_ADMIN_CHAT_ID
        [[ -n "${TELEGRAM_ADMIN_CHAT_ID}" ]] && save_config_var "TELEGRAM_ADMIN_CHAT_ID" "${TELEGRAM_ADMIN_CHAT_ID}" "${config_file}"
    fi
    
    # Optional: Telegram User Bot
    if [[ -z "${TELEGRAM_USER_TOKEN:-}" ]]; then
        read -rp "Enter Telegram User Bot Token (for group status, or press Enter to skip): " TELEGRAM_USER_TOKEN
        [[ -n "${TELEGRAM_USER_TOKEN}" ]] && save_config_var "TELEGRAM_USER_TOKEN" "${TELEGRAM_USER_TOKEN}" "${config_file}"
    fi
    if [[ -n "${TELEGRAM_USER_TOKEN:-}" && -z "${TELEGRAM_USER_CHAT_ID:-}" ]]; then
        read -rp "Enter Telegram User Bot Chat ID (group ID, negative number): " TELEGRAM_USER_CHAT_ID
        [[ -n "${TELEGRAM_USER_CHAT_ID}" ]] && save_config_var "TELEGRAM_USER_CHAT_ID" "${TELEGRAM_USER_CHAT_ID}" "${config_file}"
    fi
    
    # Optional: Tailscale
    if [[ -z "${TAILSCALE_AUTH_KEY:-}" ]]; then
        read -rp "Enter Tailscale Auth Key (or press Enter for interactive login): " TAILSCALE_AUTH_KEY
        [[ -n "${TAILSCALE_AUTH_KEY}" ]] && save_config_var "TAILSCALE_AUTH_KEY" "${TAILSCALE_AUTH_KEY}" "${config_file}"
    fi
    
    # Optional: Static IP
    if [[ -z "${STATIC_IP:-}" ]]; then
        read -rp "Enter Static IP with CIDR (e.g., 192.168.1.100/24, or press Enter for DHCP): " STATIC_IP
        [[ -n "${STATIC_IP}" ]] && save_config_var "STATIC_IP" "${STATIC_IP}" "${config_file}"
    fi
    if [[ -n "${STATIC_IP:-}" && -z "${STATIC_GATEWAY:-}" ]]; then
        read -rp "Enter Gateway IP (router IP): " STATIC_GATEWAY
        [[ -n "${STATIC_GATEWAY}" ]] && save_config_var "STATIC_GATEWAY" "${STATIC_GATEWAY}" "${config_file}"
    fi
    
    # Reload config
    # shellcheck source=/dev/null
    source "${config_file}"
    echo
}

save_config_var() {
    local var_name="$1" var_value="$2" config_file="$3"
    local escaped_value; escaped_value=$(printf '%s\n' "${var_value}" | sed 's/[[\.*^$()+?{|\\]/\\&/g')
    if grep -q "^${var_name}=" "${config_file}"; then
        sed -i "s|^${var_name}=.*|${var_name}=\"${escaped_value}\"|" "${config_file}"
    else
        echo "${var_name}=\"${escaped_value}\"" >> "${config_file}"
    fi
    chmod 600 "${config_file}"
}

# ============================================================================
# MODULE SELECTION
# ============================================================================
select_modules() {
    local selected_modules="$1" interactive="${2:-true}"
    [[ -n "${selected_modules}" ]] && { IFS=',' read -ra MODULES_TO_INSTALL <<< "${selected_modules}"; return 0; }
    [[ "${interactive}" != "true" ]] && { MODULES_TO_INSTALL=($(printf '%s\n' "${MODULES[@]}" | cut -d':' -f1)); return 0; }
    
    echo -e "\n${BOLD}Select modules to install:${NC}"
    echo "Enter comma-separated numbers (e.g., 1,3,5) or 'all' for everything."
    echo
    local i=1
    for module_entry in "${MODULES[@]}"; do
        local module_name="${module_entry%%:*}" module_desc="${module_entry#*:}"
        printf "  ${CYAN}%2d)${NC} %-12s - %s\n" "${i}" "${module_name}" "${module_desc}"
        ((i++))
    done
    echo
    read -rp "Selection [all]: " selection; selection="${selection:-all}"
    
    if [[ "${selection,,}" == "all" || "${selection,,}" == "a" ]]; then
        MODULES_TO_INSTALL=($(printf '%s\n' "${MODULES[@]}" | cut -d':' -f1))
    else
        MODULES_TO_INSTALL=()
        IFS=',' read -ra indices <<< "${selection}"
        for idx in "${indices[@]}"; do
            idx=$(echo "${idx}" | xargs)
            [[ "${idx}" =~ ^[0-9]+$ ]] && [[ ${idx} -ge 1 && ${idx} -le ${#MODULES[@]} ]] && \
                MODULES_TO_INSTALL+=("$(printf '%s\n' "${MODULES[idx-1]}" | cut -d':' -f1)") || log_warn "Invalid selection: ${idx}"
        done
    fi
    [[ ${#MODULES_TO_INSTALL[@]} -eq 0 ]] && die "No valid modules selected"
    log_info "Selected modules: ${MODULES_TO_INSTALL[*]}"
}

resolve_dependencies() {
    local -n modules_ref=$1; local resolved=() processing=()
    for module in "${modules_ref[@]}"; do processing+=("${module}"); done
    while [[ ${#processing[@]} -gt 0 ]]; do
        local module="${processing[0]}"; processing=("${processing[@]:1}")
        [[ " ${resolved[*]} " =~ " ${module} " ]] && continue
        if [[ -n "${MODULE_DEPS[${module}]:-}" ]]; then
            IFS=',' read -ra deps <<< "${MODULE_DEPS[${module}]}"
            for dep in "${deps[@]}"; do [[ ! " ${resolved[*]} " =~ " ${dep} " ]] && processing=("${dep}" "${processing[@]}"); done
        fi
        local all_deps_resolved=true
        if [[ -n "${MODULE_DEPS[${module}]:-}" ]]; then
            IFS=',' read -ra deps <<< "${MODULE_DEPS[${module}]}"
            for dep in "${deps[@]}"; do [[ ! " ${resolved[*]} " =~ " ${dep} " ]] && all_deps_resolved=false; done
        fi
        [[ "${all_deps_resolved}" == "true" ]] && resolved+=("${module}") || processing+=("${module}")
    done
    modules_ref=("${resolved[@]}"); log_info "Resolved installation order: ${resolved[*]}"
}

check_module_installed() {
    case "$1" in
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
    local module="$1" script_name="${MODULE_SCRIPTS[${module}]}" script_path="${SCRIPT_DIR}/scripts/${script_name}"
    [[ ! -f "${script_path}" ]] && { log_error "Module script not found: ${script_path}"; return 1; }
    log_info "Executing module: ${module} (${script_name})"
    chmod +x "${script_path}"
    set -a; source "${CONFIG_FILE}"; set +a
    if "${script_path}"; then log_success "Module ${module} completed"; touch "${STATE_DIR}/${module}.installed"; return 0; else log_error "Module ${module} failed"; return $?; fi
}

show_summary() {
    local ip; ip=$(hostname -I | awk '{print $1}')
    echo -e "\n${BOLD}${CYAN}=========================================${NC}\n${BOLD}${CYAN}   INSTALLATION SUMMARY${NC}\n${BOLD}${CYAN}=========================================${NC}\nDevice IP: ${GREEN}${ip}${NC}"
    for module in "${MODULES_TO_INSTALL[@]}"; do
        if [[ -f "${STATE_DIR}/${module}.installed" ]]; then
            echo -e "${GREEN}✓${NC} ${module}"
            case "${module}" in
                system) echo "    SSH:     ssh ${PI_USER}@${ip}"; echo "    VNC:     ${ip}:5900" ;;
                network) echo "    Tailscale: Connected" ;;
                pihole) echo "    Web UI:  http://${ip}/admin"; echo "    Password: ${PIHOLE_PASSWORD}" ;;
                monitoring) echo "    Prometheus: http://${ip}:9090"; echo "    Grafana:    http://${ip}:3000 (admin / ${GRAFANA_ADMIN_PASSWORD})"; echo "    Alertmanager: http://${ip}:9093" ;;
                samba) echo "    Webmin: https://${ip}:10000"; echo "    Samba:  \\\\${ip}\\${SMB_SHARE_NAME:-pishare}" ;;
                telegram) echo "    Service: telegram-bot.service" ;;
                localsend) echo "    Port: 53317" ;;
                stirling) echo "    URL: http://${ip}:8080" ;;
                nginx) echo "    Domains: dashboard.home, pi.home, n8n.home, etc."; echo "    Configure DNS in Pi-hole: http://${ip}:8081/admin/dns_records.php" ;;
                cockpit) echo "    URL: https://${ip}:9091" ;;
                n8n) echo "    URL: http://${ip}:5678 (or http://n8n.home)" ;;
            esac; echo
        else echo -e "${RED}✗${NC} ${module} (failed or skipped)"; fi
    done
    echo -e "${BOLD}${CYAN}=========================================${NC}\n${BOLD}${GREEN}Installation Complete!${NC}\nLog file: ${LOG_FILE}\n${BOLD}${CYAN}=========================================${NC}"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    local config_file="${CONFIG_FILE_DEFAULT}" modules_arg="" non_interactive=false dry_run=false repair_mode=false uninstall_mode=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -y|--yes) non_interactive=true ;;
            -m|--modules) modules_arg="$2"; shift ;;
            -c|--config) config_file="$2"; shift ;;
            -h|--help) cat <<EOF
Usage: sudo ./install.sh [OPTIONS]

Options:
  -y, --yes          Non-interactive mode (requires pre-configured settings.conf)
  -m, --modules      Comma-separated modules (e.g., "system,network,pihole")
  -c, --config       Config file path (default: ./settings.conf)
  -h, --help         Show this help
  -v, --version      Show version
  --dry-run          Validate config without making changes
  --repair           Attempt to repair broken installations
  --uninstall        Uninstall modules

Available modules: $(printf '%s, ' "${MODULES[@]}" | sed 's/:.*//g' | sed 's/, $//')

Examples:
  sudo ./install.sh                          # Interactive full install
  sudo ./install.sh -y                       # Non-interactive full install
  sudo ./install.sh -m "system,network,pihole"
  sudo ./install.sh --dry-run                # Validate config only
EOF
                exit 0 ;;
            -v|--version) echo "${SCRIPT_VERSION}"; exit 0 ;;
            --dry-run) dry_run=true ;;
            --repair) repair_mode=true ;;
            --uninstall) uninstall_mode=true ;;
            *) die "Unknown option: $1" ;;
        esac; shift
    done
    
    check_root; check_os; check_arch; setup_directories
    log_info "Starting ${PROJECT_NAME} v${SCRIPT_VERSION}"; log_info "Log file: ${LOG_FILE}"
    
    [[ ! -f "${config_file}" ]] && [[ -f "${CONFIG_FILE_DEFAULT}" ]] && config_file="${CONFIG_FILE_DEFAULT}"
    [[ ! -f "${config_file}" ]] && die "Config file not found. Copy config/settings.conf.example to settings.conf"
    
    sanitize_config "${config_file}"; load_config "${config_file}"; validate_config
    [[ "${dry_run}" == "true" ]] && { log_success "Dry run successful - configuration valid"; exit 0; }
    
    prompt_missing_config "${config_file}" "${non_interactive}"
    select_modules "${modules_arg}" "${non_interactive}"
    resolve_dependencies MODULES_TO_INSTALL
    
    local to_install=()
    for module in "${MODULES_TO_INSTALL[@]}"; do
        if check_module_installed "${module}"; then
            log_warn "Module ${module} appears already installed"
            [[ "${non_interactive}" != "true" ]] && { read -rp "Reinstall ${module}? [y/N] " -n 1 -r; echo; [[ $REPLY =~ ^[Yy]$ ]] && to_install+=("${module}"); } || log_info "Skipping ${module}"
        else to_install+=("${module}"); fi
    done
    MODULES_TO_INSTALL=("${to_install[@]}")
    [[ ${#MODULES_TO_INSTALL[@]} -eq 0 ]] && { log_info "Nothing to install"; exit 0; }
    
    [[ "${non_interactive}" != "true" ]] && { echo -e "\n${BOLD}Modules to install:${NC} ${MODULES_TO_INSTALL[*]}"; read -rp "Proceed? [Y/n] " -n 1 -r; echo; [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0; }
    
    local total=${#MODULES_TO_INSTALL[@]} current=0 failed=()
    for module in "${MODULES_TO_INSTALL[@]}"; do
        ((current++)); show_progress "${current}" "${total}" "${module}"; echo
        if execute_module "${module}"; then log_success "Module ${module} completed"; else log_error "Module ${module} failed"; failed+=("${module}"); [[ "${non_interactive}" == "true" ]] && die "Module ${module} failed in non-interactive mode"; read -rp "Continue? [Y/n] " -n 1 -r; echo; [[ ! $REPLY =~ ^[Yy]$ ]] && break; fi
    done
    show_summary
    [[ ${#failed[@]} -gt 0 ]] && { log_warn "Failed modules: ${failed[*]}"; exit 1; }
}

main "$@"