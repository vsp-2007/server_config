#!/bin/bash
# Pi Server Setup v2 - Master Installation Script
# Modern, secure, and modular server automation for any Debian 13+/Ubuntu 24.04+ system
# EXPERIMENTAL - Use CLI for stability

set -euo pipefail

# ============================================================================
# CONSTANTS & GLOBALS
# ============================================================================
readonly SCRIPT_VERSION="2.0.0-experimental"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_NAME="pi-server-setup"
readonly CONFIG_FILE_DEFAULT="${SCRIPT_DIR}/settings.conf"
readonly LOG_DIR="/var/log/${PROJECT_NAME}"
readonly LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
readonly STATE_DIR="/var/lib/${PROJECT_NAME}"
readonly BACKUP_DIR="${STATE_DIR}/backups"

# Color detection - works with sudo and various terminals
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    readonly RED="$(tput setaf 1)"
    readonly GREEN="$(tput setaf 2)"
    readonly YELLOW="$(tput setaf 3)"
    readonly BLUE="$(tput setaf 4)"
    readonly MAGENTA="$(tput setaf 5)"
    readonly CYAN="$(tput setaf 6)"
    readonly BOLD="$(tput bold)"
    readonly DIM="$(tput dim)"
    readonly NC="$(tput sgr0)"
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
# LOGGING FUNCTIONS (safe - won't fail if log dir missing)
# ============================================================================
_log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local output="${timestamp} [${level}] ${msg}"
    
    # Always print to stdout
    echo -e "${output}"
    
    # Try to log to file if directory exists
    if [[ -d "${LOG_DIR}" ]]; then
        echo -e "${output}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}

log_info()    { _log "INFO"    "${BLUE}${*}${NC}"; }
log_success() { _log "SUCCESS" "${GREEN}${*}${NC}"; }
log_warn()    { _log "WARN"    "${YELLOW}${*}${NC}"; }
log_error()   { _log "ERROR"   "${RED}${*}${NC}"; }
log_debug()   { [[ "${DEBUG:-false}" == "true" ]] && _log "DEBUG" "${DIM}${*}${NC}"; }

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

# ============================================================================
# CRITICAL: Run this FIRST to ensure log directory exists
# ============================================================================
setup_directories() {
    mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${BACKUP_DIR}"
    chmod 750 "${LOG_DIR}" "${STATE_DIR}" "${BACKUP_DIR}" 2>/dev/null || true
}

sanitize_config() {
    local config_file="$1"
    sed -i 's/\r$//' "${config_file}" 2>/dev/null || true
    sed -i 's/[[:space:]]*$//' "${config_file}" 2>/dev/null || true
}

load_config() {
    local config_file="$1"
    [[ ! -f "${config_file}" ]] && die "Config file not found: ${config_file}\nCopy config/settings.conf.example to settings.conf"
    
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
# MODULE SELECTION (CLI)
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

generate_summary() {
    local ip; ip=$(hostname -I | awk '{print $1}')
    local summary="Installation Complete!\n\nDevice IP: ${ip}\n\n"
    for module in "${MODULES_TO_INSTALL[@]}"; do
        if [[ -f "${STATE_DIR}/${module}.installed" ]]; then
            summary+="✓ ${module}\n"
            case "${module}" in
                system) summary+="    SSH: ssh ${PI_USER}@${ip}\n    VNC: ${ip}:5900\n" ;;
                network) summary+="    Tailscale: Connected\n" ;;
                pihole) summary+="    Web UI: http://${ip}/admin\n    Password: ${PIHOLE_PASSWORD}\n" ;;
                monitoring) summary+="    Prometheus: http://${ip}:9090\n    Grafana: http://${ip}:3000 (admin / ${GRAFANA_ADMIN_PASSWORD})\n    Alertmanager: http://${ip}:9093\n" ;;
                samba) summary+="    Webmin: https://${ip}:10000\n    Samba: \\\\${ip}\\${SMB_SHARE_NAME:-pishare}\n" ;;
                telegram) summary+="    Service: telegram-bot.service\n" ;;
                localsend) summary+="    Port: 53317\n" ;;
                stirling) summary+="    URL: http://${ip}:8080\n" ;;
                nginx) summary+="    Domains: dashboard.home, pi.home, n8n.home, etc.\n    Configure DNS in Pi-hole: http://${ip}:8081/admin/dns_records.php\n" ;;
                cockpit) summary+="    URL: https://${ip}:9091\n" ;;
                n8n) summary+="    URL: http://${ip}:5678 (or http://n8n.home)\n" ;;
            esac
            summary+="\n"
        else
            summary+="✗ ${module} (failed or skipped)\n\n"
        fi
    done
    summary+="\nLog file: ${LOG_FILE}\n"
    echo -e "$summary"
}

show_summary() { generate_summary; }

# ============================================================================
# TUI FUNCTIONS (whiptail/dialog) - only loaded if --tui flag used
# ============================================================================
check_tui_tool() {
    if command -v dialog >/dev/null 2>&1; then TUI_TOOL="dialog"; return 0
    elif command -v whiptail >/dev/null 2>&1; then TUI_TOOL="whiptail"; return 0
    fi; return 1
}

install_tui_tool() {
    log_info "Installing TUI tool (dialog)..."
    apt-get update -qq && apt-get install -y -qq dialog
}

run_tui_mode() {
    if ! check_tui_tool; then
        log_info "TUI tool not found, installing dialog..."
        install_tui_tool
        check_tui_tool || die "Failed to install dialog/whiptail"
    fi
    
    local tool="$TUI_TOOL"
    
    # Welcome
    $tool --title "Pi Server Setup v2 - EXPERIMENTAL" --msgbox \
        "⚠️  WARNING: This is EXPERIMENTAL software.\n\nUse CLI mode for stability and production use.\nTUI mode may have issues and is for testing only.\n\nContinue at your own risk." 12 70
    
    # Module selection
    local selected_modules
    selected_modules=$($tool --title "Module Selection" --checklist \
        "Select modules to install (Space to toggle, Enter to confirm):\n\nRequired modules are pre-selected and cannot be deselected." \
        20 78 12 \
        "system" "System Basics (Required)" ON \
        "network" "Tailscale + Firewall + Fail2Ban" OFF \
        "pihole" "Pi-hole DNS Ad-blocking" OFF \
        "monitoring" "Prometheus + Grafana + Alertmanager" OFF \
        "samba" "Samba + Webmin" OFF \
        "utils" "Reports + Cron + Maintenance" OFF \
        "telegram" "Dual Telegram Bot (Admin + User)" OFF \
        "localsend" "LocalSend File Sharing" OFF \
        "stirling" "Stirling-PDF" OFF \
        "nginx" "Nginx Reverse Proxy (.home domains)" OFF \
        "cockpit" "Cockpit Web Admin" OFF \
        "n8n" "n8n Automation Engine" OFF \
        3>&1 1>&2 2>&3)
    [[ -z "$selected_modules" ]] && die "No modules selected"
    IFS=' ' read -ra MODULES_TO_INSTALL <<< "$selected_modules"
    
    # Config form
    local config_output
    config_output=$($tool --title "Configuration" --form \
        "Enter required configuration (Tab to navigate, Enter to confirm):\n\nRequired fields marked with *." \
        20 78 10 \
        "PI_USER*"      1 1 "piadmin"     1 20 20 0 \
        "SSH_PORT*"     2 1 "2222"        2 20 10 0 \
        "PI_PASSWORD"   3 1 ""            3 20 30 0 \
        "TELEGRAM_TOKEN" 4 1 ""          4 20 50 0 \
        "TAILSCALE_KEY" 5 1 ""           5 20 50 0 \
        "STATIC_IP"     6 1 ""            6 20 20 0 \
        3>&1 1>&2 2>&3)
    IFS=$'\n' read -r PI_USER SSH_PORT PI_PASSWORD TELEGRAM_TOKEN TAILSCALE_KEY STATIC_IP <<< "$config_output"
    
    save_config_var "PI_USER" "$PI_USER" "$CONFIG_FILE"
    save_config_var "SSH_PORT" "$SSH_PORT" "$CONFIG_FILE"
    [[ -n "$PI_PASSWORD" ]] && save_config_var "PI_PASSWORD" "$PI_PASSWORD" "$CONFIG_FILE"
    [[ -n "$TELEGRAM_TOKEN" ]] && save_config_var "TELEGRAM_ADMIN_TOKEN" "$TELEGRAM_TOKEN" "$CONFIG_FILE"
    [[ -n "$TAILSCALE_KEY" ]] && save_config_var "TAILSCALE_AUTH_KEY" "$TAILSCALE_KEY" "$CONFIG_FILE"
    [[ -n "$STATIC_IP" ]] && save_config_var "STATIC_IP" "$STATIC_IP" "$CONFIG_FILE"
    
    # Reload config
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    
    # Generate passwords for empty fields
    [[ -z "${PI_PASSWORD:-}" ]] && { PI_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16); log_info "Generated random password for ${PI_USER}"; save_config_var "PI_PASSWORD" "$PI_PASSWORD" "$CONFIG_FILE"; }
    [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]] && { GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16); log_info "Generated random Grafana password"; save_config_var "GRAFANA_ADMIN_PASSWORD" "$GRAFANA_ADMIN_PASSWORD" "$CONFIG_FILE"; }
    [[ -z "${PIHOLE_PASSWORD:-}" ]] && { PIHOLE_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16); log_info "Generated random Pi-hole password"; save_config_var "PIHOLE_PASSWORD" "$PIHOLE_PASSWORD" "$CONFIG_FILE"; }
    [[ -z "${SMB_PASSWORD:-}" ]] && { SMB_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16); log_info "Generated random Samba password"; save_config_var "SMB_PASSWORD" "$SMB_PASSWORD" "$CONFIG_FILE"; }
    
    # Confirm
    local module_list=$(printf '%s\n' "${MODULES_TO_INSTALL[@]}")
    $tool --title "Confirm Installation" --yesno "Ready to install the following modules:\n\n$module_list\n\nProceed with installation?" 15 70 || die "Installation cancelled"
    
    # Resolve dependencies
    resolve_dependencies MODULES_TO_INSTALL
    
    # Check already installed
    local to_install=()
    for module in "${MODULES_TO_INSTALL[@]}"; do
        if check_module_installed "$module"; then
            log_warn "Module $module appears already installed"
            $tool --yesno "Module $module appears already installed. Reinstall?" 8 60 && to_install+=("$module")
        else
            to_install+=("$module")
        fi
    done
    MODULES_TO_INSTALL=("${to_install[@]}")
    [[ ${#MODULES_TO_INSTALL[@]} -eq 0 ]] && { log_info "Nothing to install"; exit 0; }
    
    # Execute with progress gauge
    local total=${#MODULES_TO_INSTALL[@]} current=0 failed=()
    for module in "${MODULES_TO_INSTALL[@]}"; do
        ((current++))
        $tool --title "Installing $module" --gauge "Installing $module ($current of $total)..." 8 70 $((current * 100 / total)) &
        local gauge_pid=$!
        
        if execute_module "$module"; then
            log_success "Module $module completed"
        else
            log_error "Module $module failed"
            failed+=("$module")
        fi
        kill $gauge_pid 2>/dev/null || true
    done
    
    # Summary
    local summary
    summary=$(generate_summary)
    $tool --title "Installation Complete" --msgbox "$summary" 20 70
    
    [[ ${#failed[@]} -gt 0 ]] && exit 1 || exit 0
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    local config_file="${CONFIG_FILE_DEFAULT}" modules_arg="" non_interactive=false dry_run=false repair_mode=false uninstall_mode=false
    TUI_MODE=false
    
    # Parse arguments
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
  --tui              Terminal UI mode (Experimental)
  --gui              Web GUI mode (Not yet implemented)

Available modules: $(printf '%s, ' "${MODULES[@]}" | sed 's/:.*//g' | sed 's/, $//')

Examples:
  sudo ./install.sh                          # Interactive CLI (default)
  sudo ./install.sh --tui                    # Terminal UI (Experimental)
  sudo ./install.sh -y                       # Non-interactive CLI
  sudo ./install.sh -m "system,network,pihole"
  sudo ./install.sh --dry-run                # Validate config only
EOF
                exit 0 ;;
            -v|--version) echo "${SCRIPT_VERSION}"; exit 0 ;;
            --dry-run) dry_run=true ;;
            --repair) repair_mode=true ;;
            --uninstall) uninstall_mode=true ;;
            --tui) TUI_MODE=true ;;
            --gui) log_warn "Web GUI not yet implemented. Use --tui for TUI."; exit 1 ;;
            *) die "Unknown option: $1" ;;
        esac; shift
    done
    
    # Experimental warning
    echo -e "${BOLD}${YELLOW}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${YELLOW}║                    ⚠️  EXPERIMENTAL v${SCRIPT_VERSION}                      ║${NC}"
    echo -e "${BOLD}${YELLOW}║  This is experimental software. Use CLI for production.          ║${NC}"
    echo -e "${BOLD}${YELLOW}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    # Run TUI mode if requested
    if [[ "${TUI_MODE}" == "true" ]]; then
        log_info "Starting in TUI mode (Experimental)"
        run_tui_mode
        exit $?
    fi
    
    # CLI Mode Selection (default to CLI)
    if [[ "${non_interactive}" != "true" ]]; then
        echo -e "${BOLD}Select installation mode:${NC}"
        echo "  ${GREEN}1)${NC} CLI - Stable, production-ready (DEFAULT)"
        echo "  ${YELLOW}2)${NC} TUI - Terminal UI (Experimental, may have issues)"
        echo
        read -rp "Select mode [1]: " mode_choice
        mode_choice="${mode_choice:-1}"
        
        case "${mode_choice}" in
            2)
                log_warn "Starting TUI mode (Experimental)..."
                run_tui_mode
                exit $?
                ;;
            1|"")
                log_info "Starting CLI mode (Stable, production-ready)"
                ;;
            *)
                log_warn "Invalid choice, defaulting to CLI"
                ;;
        esac
    fi
    
    # CLI Mode (default)
    log_info "Starting ${PROJECT_NAME} v${SCRIPT_VERSION} (CLI Mode)"
    log_info "Log file: ${LOG_FILE}"
    
    check_root; check_os; check_arch; setup_directories
    
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