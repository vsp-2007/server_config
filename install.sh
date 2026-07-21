#!/bin/bash
# Pi Server Setup v2 - Master Installation Script
# Modern, secure, and modular server automation for Debian 13+/Ubuntu 24.04+ systems
# Stable successor to main branch with state tracking for idempotency

set -euo pipefail

# ============================================================================
# CONSTANTS & GLOBALS
# ============================================================================
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_NAME="pi-server-setup"
readonly CONFIG_FILE_DEFAULT="${SCRIPT_DIR}/settings.conf"
readonly CONFIG_FILE_EXAMPLE="${SCRIPT_DIR}/config/settings.conf.example"
readonly LOG_DIR="/var/log/${PROJECT_NAME}"
readonly LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
readonly STATE_DIR="/var/lib/${PROJECT_NAME}"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly INSTALL_STATE_FILE="${STATE_DIR}/install.state"

# Raw ANSI colors (reliable under sudo, no tput dependency)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

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
# LOGGING FUNCTIONS (always print to stderr for visibility)
# ============================================================================
_log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local output="${timestamp} [${level}] ${msg}"
    
    # ALWAYS print to stderr so user sees it
    printf '%s\n' "${output}" >&2
    
    # Also write to log file if directory exists
    [[ -d "${LOG_DIR}" ]] && printf '%s\n' "${output}" >> "${LOG_FILE}" 2>/dev/null || true
}

log_info()    { _log "INFO"    "${BLUE}${*}${NC}"; }
log_success() { _log "SUCCESS" "${GREEN}${*}${NC}"; }
log_warn()    { _log "WARN"    "${YELLOW}${*}${NC}"; }
log_error()   { _log "ERROR"   "${RED}${*}${NC}"; }
log_debug()   { [[ "${DEBUG:-false}" == "true" ]] && _log "DEBUG" "${DIM}${*}${NC}" || true; }

# Fatal error with message
die() { log_error "$*"; exit 1; }

# Progress indicator
show_progress() {
    local current="$1" total="$2" module="$3"
    local pct=$((current * 100 / total))
    printf "\r${CYAN}[%d/%d]${NC} %-20s ${DIM}[%d%%]${NC}" "${current}" "${total}" "${module}" "${pct}" >&2
}

# ============================================================================
# STATE TRACKING (Idempotency)
# ============================================================================
mark_module_installed() {
    echo "${1}=installed" >> "${INSTALL_STATE_FILE}"
}

is_module_installed() {
    [[ -f "${INSTALL_STATE_FILE}" ]] && grep -q "^${1}=installed$" "${INSTALL_STATE_FILE}" 2>/dev/null
}

mark_module_failed() {
    echo "${1}=failed" >> "${INSTALL_STATE_FILE}"
}

get_module_state() {
    [[ -f "${INSTALL_STATE_FILE}" ]] && grep "^${1}=" "${INSTALL_STATE_FILE}" 2>/dev/null | cut -d= -f2
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================
check_root() { 
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)" 
    fi
    log_debug "Root check passed"
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot determine OS version - /etc/os-release missing"
    fi
    source /etc/os-release
    log_info "OS detected: ${PRETTY_NAME}"
    if [[ "${ID}" != "raspbian" && "${ID}" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
        log_warn "Designed for Debian-based OS. Current: ${PRETTY_NAME}"
        if [[ "${SKIP_OS_CHECK:-false}" != "true" ]]; then
            read -p "Continue anyway? [y/N] " -n 1 -r; echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
        fi
    fi
}

check_arch() {
    local arch; arch=$(uname -m)
    case "${arch}" in
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armhf)  ARCH="armv7" ;;
        x86_64|amd64)  ARCH="amd64" ;;
        *) die "Unsupported architecture: ${arch}" ;;
    esac
    log_info "Architecture: ${ARCH}"
    export ARCH
}

sanitize_config() {
    local config_file="$1"
    sed -i 's/\r$//' "${config_file}" 2>/dev/null || true
    sed -i 's/[[:space:]]*$//' "${config_file}" 2>/dev/null || true
}

load_config() {
    local config_file="$1"
    [[ ! -f "${config_file}" ]] && die "Config file not found: ${config_file}"
    
    local perms; perms=$(stat -c "%a" "${config_file}" 2>/dev/null || stat -f "%A" "${config_file}" 2>/dev/null)
    if [[ "${perms}" != "600" && "${perms}" != "400" ]]; then
        log_warn "Config permissions loose (${perms}), fixing to 600"
        chmod 600 "${config_file}"
    fi
    
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
    # Only validate PI_USER if set
    if [[ -n "${PI_USER:-}" ]] && ! validate_username "${PI_USER}"; then
        log_error "PI_USER must be lowercase alphanumeric with underscores/hyphens"
        ((errors++))
    fi
    
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
# INTERACTIVE CONFIGURATION PROMPTING (auto-copies from template)
# ============================================================================
prompt_missing_config() {
    local config_file="$1"
    local non_interactive="${2:-false}"
    [[ "${non_interactive}" == "true" ]] && return 0
    
    echo -e "\n${BOLD}${CYAN}=== Interactive Configuration ===${NC}" >&2
    echo "Missing required values will be prompted. Press Enter to use defaults or generate random values." >&2
    echo >&2
    
    # Helper: prompt with validation
    prompt_with_validation() {
        local var_name="$1" prompt_text="$2" validator="$3" default="$4" is_secret="$5"
        local value
        while true; do
            if [[ "${is_secret}" == "true" ]]; then
                read -rsp "${prompt_text}: " value; echo >&2
            else
                read -rp "${prompt_text} [${default}]: " value >&2
                value="${value:-${default}}"
            fi
            if [[ -z "${value}" && -n "${default}" ]]; then value="${default}"; break; fi
            if [[ -n "${value}" ]] && ${validator} "${value}"; then break; fi
            log_warn "Invalid input, please try again."
        done
        printf -v "${var_name}" '%s' "${value}"
        save_config_var "${var_name}" "${value}" "${config_file}"
    }
    
    # === OPTIONAL: System User (PI_USER) ===
    echo -e "\n${CYAN}=== System User (Optional) ===${NC}" >&2
    echo "Create an additional sudo user? Press Enter to skip (use existing root/sudo user)." >&2
    read -rp "Enter system username (or press Enter to skip): " PI_USER >&2
    PI_USER="${PI_USER:-}"  # Empty if user pressed Enter
    if [[ -n "${PI_USER}" ]]; then
        while ! validate_username "${PI_USER}"; do
            log_warn "Invalid username. Use lowercase alphanumeric with underscores/hyphens."
            read -rp "Enter system username: " PI_USER >&2
        done
        save_config_var "PI_USER" "${PI_USER}" "${config_file}"
        
        # Password (optional)
        read -rsp "Enter password for ${PI_USER} (min 8 chars, empty for key-only auth): " PI_PASSWORD; echo >&2
        if [[ -z "${PI_PASSWORD}" ]]; then
            log_info "No password set - key-only authentication"
            PI_PASSWORD=""
        else
            while ! validate_password "${PI_PASSWORD}"; do
                log_warn "Password must be at least 8 characters"
                read -rsp "Enter password for ${PI_USER}: " PI_PASSWORD; echo >&2
            done
        fi
        save_config_var "PI_PASSWORD" "${PI_PASSWORD}" "${config_file}"
        
        # SSH keys
        read -rp "Enter SSH public keys for ${PI_USER} (or press Enter to skip): " PI_SSH_KEYS >&2
        save_config_var "PI_SSH_KEYS" "${PI_SSH_KEYS}" "${config_file}"
    else
        PI_USER=""
        save_config_var "PI_USER" "" "${config_file}"
        log_info "Skipping additional user creation"
    fi
    
    # === SSH Settings ===
    read -rp "SSH port [22]: " SSH_PORT >&2; SSH_PORT="${SSH_PORT:-22}"
    save_config_var "SSH_PORT" "${SSH_PORT}" "${config_file}"
    
    read -rp "Allow SSH root login? [no]: " SSH_PERMIT_ROOT_LOGIN >&2; SSH_PERMIT_ROOT_LOGIN="${SSH_PERMIT_ROOT_LOGIN:-no}"
    save_config_var "SSH_PERMIT_ROOT_LOGIN" "${SSH_PERMIT_ROOT_LOGIN}" "${config_file}"
    
    read -rp "Allow SSH password authentication? [no]: " SSH_PASSWORD_AUTH >&2; SSH_PASSWORD_AUTH="${SSH_PASSWORD_AUTH:-no}"
    save_config_var "SSH_PASSWORD_AUTH" "${SSH_PASSWORD_AUTH}" "${config_file}"
    
    # === Optional Passwords (with defaults for services that have them) ===
    echo -e "\n${CYAN}=== Service Passwords (Optional - press Enter for defaults) ===${NC}" >&2
    
    # Grafana - default admin/admin
    read -rp "Grafana admin password (default: admin) [admin]: " GRAFANA_ADMIN_PASSWORD >&2
    GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
    save_config_var "GRAFANA_ADMIN_PASSWORD" "${GRAFANA_ADMIN_PASSWORD}" "${config_file}"
    
    # Pi-hole - required for web UI
    read -rp "Pi-hole admin password (min 8 chars, empty for random): " PIHOLE_PASSWORD >&2
    if [[ -z "${PIHOLE_PASSWORD}" ]]; then
        PIHOLE_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
        log_info "Generated random Pi-hole password"
    fi
    while ! validate_password "${PIHOLE_PASSWORD}"; do
        log_warn "Password must be at least 8 characters"
        read -rp "Pi-hole admin password: " PIHOLE_PASSWORD >&2
    done
    save_config_var "PIHOLE_PASSWORD" "${PIHOLE_PASSWORD}" "${config_file}"
    
    # Samba
    read -rp "Samba password for ${SMB_USER:-smbuser} (min 8 chars, empty for random): " SMB_PASSWORD >&2
    if [[ -z "${SMB_PASSWORD}" ]]; then
        SMB_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
        log_info "Generated random Samba password"
    fi
    while ! validate_password "${SMB_PASSWORD}"; do
        log_warn "Password must be at least 8 characters"
        read -rp "Samba password: " SMB_PASSWORD >&2
    done
    save_config_var "SMB_PASSWORD" "${SMB_PASSWORD}" "${config_file}"
    
    # === Telegram Bot Configuration (Optional) ===
    echo -e "\n${CYAN}--- Telegram Bot Configuration (Optional) ---${NC}" >&2
    read -rp "Telegram Admin Bot Token (from @BotFather, press Enter to skip): " TELEGRAM_ADMIN_TOKEN >&2
    [[ -n "${TELEGRAM_ADMIN_TOKEN}" ]] && save_config_var "TELEGRAM_ADMIN_TOKEN" "${TELEGRAM_ADMIN_TOKEN}" "${config_file}"
    if [[ -n "${TELEGRAM_ADMIN_TOKEN:-}" ]]; then
        read -rp "Telegram Admin Chat ID (your user ID from @userinfobot): " TELEGRAM_ADMIN_CHAT_ID >&2
        [[ -n "${TELEGRAM_ADMIN_CHAT_ID}" ]] && save_config_var "TELEGRAM_ADMIN_CHAT_ID" "${TELEGRAM_ADMIN_CHAT_ID}" "${config_file}"
    fi
    
    read -rp "Telegram User Bot Token (for group status, press Enter to skip): " TELEGRAM_USER_TOKEN >&2
    [[ -n "${TELEGRAM_USER_TOKEN}" ]] && save_config_var "TELEGRAM_USER_TOKEN" "${TELEGRAM_USER_TOKEN}" "${config_file}"
    if [[ -n "${TELEGRAM_USER_TOKEN:-}" ]]; then
        read -rp "Telegram User Bot Chat ID (group ID, negative number): " TELEGRAM_USER_CHAT_ID >&2
        [[ -n "${TELEGRAM_USER_CHAT_ID}" ]] && save_config_var "TELEGRAM_USER_CHAT_ID" "${TELEGRAM_USER_CHAT_ID}" "${config_file}"
    fi
    
    # === Tailscale ===
    read -rp "Tailscale Auth Key (press Enter for interactive login): " TAILSCALE_AUTH_KEY >&2
    [[ -n "${TAILSCALE_AUTH_KEY}" ]] && save_config_var "TAILSCALE_AUTH_KEY" "${TAILSCALE_AUTH_KEY}" "${config_file}"
    
    # === Static IP (Optional) ===
    read -rp "Static IP with CIDR (e.g., 192.168.1.100/24, press Enter for DHCP): " STATIC_IP >&2
    [[ -n "${STATIC_IP}" ]] && save_config_var "STATIC_IP" "${STATIC_IP}" "${config_file}"
    if [[ -n "${STATIC_IP:-}" && -z "${STATIC_GATEWAY:-}" ]]; then
        read -rp "Gateway IP (router IP): " STATIC_GATEWAY >&2
        [[ -n "${STATIC_GATEWAY}" ]] && save_config_var "STATIC_GATEWAY" "${STATIC_GATEWAY}" "${config_file}"
    fi
    
    # Reload config
    # shellcheck source=/dev/null
    source "${config_file}"
    echo >&2
}

save_config_var() {
    local var_name="$1" var_value="$2" config_file="$3"
    local escaped_value; escaped_value=$(printf '%s\n' "${var_value}" | sed 's/[[\\.*^$()+?{|\\]/\\&/g')
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
    local selected_modules="$1" non_interactive="${2:-false}"
    [[ -n "${selected_modules}" ]] && { IFS=',' read -ra MODULES_TO_INSTALL <<< "${selected_modules}"; return 0; }
    [[ "${non_interactive}" == "true" ]] && { MODULES_TO_INSTALL=($(printf '%s\n' "${MODULES[@]}" | cut -d':' -f1)); return 0; }
    
    echo -e "\n${BOLD}Select modules to install:${NC}" >&2
    echo "Enter comma-separated numbers (e.g., 1,3,5) or 'all' for everything." >&2
    echo >&2
    local i=1
    for module_entry in "${MODULES[@]}"; do
        local module_name="${module_entry%%:*}" module_desc="${module_entry#*:}"
        printf "  ${CYAN}%2d)${NC} %-12s - %s\n" "${i}" "${module_name}" "${module_desc}" >&2
        ((i++))
    done
    echo >&2
    read -rp "Selection [all]: " selection >&2; selection="${selection:-all}"
    
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
    if "${script_path}"; then 
        log_success "Module ${module} completed"
        mark_module_installed "${module}"
        return 0
    else 
        log_error "Module ${module} failed"
        return $?
    fi
}

generate_summary() {
    local ip; ip=$(hostname -I | awk '{print $1}')
    local summary="Installation Complete!\n\nDevice IP: ${ip}\n\n"
    for module in "${MODULES_TO_INSTALL[@]}"; do
        if [[ -f "${STATE_DIR}/${module}.installed" ]]; then
            summary+="✓ ${module}\n"
            case "${module}" in
                system) summary+="    SSH: ssh \${PI_USER:-\$USER}@\${ip}\n    VNC: \${ip}:5900\n" ;;
                network) summary+="    Tailscale: Connected\n" ;;
                pihole) summary+="    Web UI: http://\${ip}/admin\n    Password: \${PIHOLE_PASSWORD}\n" ;;
                monitoring) summary+="    Prometheus: http://\${ip}:9090\n    Grafana: http://\${ip}:3000 (admin / \${GRAFANA_ADMIN_PASSWORD})\n    Alertmanager: http://\${ip}:9093\n" ;;
                samba) summary+="    Webmin: https://\${ip}:10000\n    Samba: \\\\\\\${ip}\\\\\${SMB_SHARE_NAME:-pishare}\n" ;;
                telegram) summary+="    Service: telegram-bot.service\n" ;;
                localsend) summary+="    Port: 53317\n" ;;
                stirling) summary+="    URL: http://\${ip}:8080\n" ;;
                nginx) summary+="    Domains: dashboard.home, pi.home, n8n.home, etc.\n    Configure DNS in Pi-hole: http://\${ip}:8081/admin/dns_records.php\n" ;;
                cockpit) summary+="    URL: https://\${ip}:9091\n" ;;
                n8n) summary+="    URL: http://\${ip}:5678 (or http://n8n.home)\n" ;;
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
# SETUP DIRECTORIES - with explicit error handling
# ============================================================================
setup_directories() {
    log_info "Creating directories: ${LOG_DIR}, ${STATE_DIR}, ${BACKUP_DIR}"
    mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${BACKUP_DIR}" || die "Failed to create directories"
    # Allow owner + group read, so sudo users can read logs
    chmod 755 "${LOG_DIR}" "${STATE_DIR}" "${BACKUP_DIR}" 2>/dev/null || true
    log_debug "Directories created successfully"
}

# Make all module scripts executable
make_scripts_executable() {
    log_info "Making module scripts executable..."
    for script in "${SCRIPT_DIR}"/scripts/*.sh; do
        [[ -f "${script}" ]] && chmod +x "${script}"
    done
    log_debug "All scripts made executable"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    local config_file="${CONFIG_FILE_DEFAULT}" modules_arg="" non_interactive=false dry_run=false repair_mode=false uninstall_mode=false
    SKIP_OS_CHECK=false
    
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
  -y, --yes              Non-interactive mode (requires pre-configured settings.conf)
  -m, --modules          Comma-separated modules to install (e.g., "system,network,pihole")
  -c, --config           Config file path (default: ./settings.conf)
  -h, --help             Show this help
  -v, --version          Show version
  --dry-run              Validate config without making changes
  --repair               Attempt to repair broken installations
  --uninstall            Uninstall modules
  --skip-os-check        Skip OS/distribution check (for testing/dry-run on non-Debian)

Available modules: system, network, pihole, monitoring, samba, utils, telegram, localsend, stirling, nginx, cockpit, n8n

Examples:
  sudo ./install.sh                          # Interactive full install
  sudo ./install.sh -y                       # Non-interactive full install
  sudo ./install.sh -m "system,network,pihole"  # Install specific modules
  sudo ./install.sh --dry-run                # Validate config only
  sudo ./install.sh --skip-os-check --dry-run # Test on non-Debian
EOF
                exit 0 ;;
            -v|--version) echo "${SCRIPT_VERSION}"; exit 0 ;;
            --dry-run) dry_run=true ;;
            --repair) repair_mode=true ;;
            --uninstall) uninstall_mode=true ;;
            --skip-os-check) SKIP_OS_CHECK=true ;;
            *) die "Unknown option: $1" ;;
        esac; shift
    done
    
    # Experimental warning banner
    echo -e "${BOLD}${YELLOW}╔═══════════════════════════════════════════════════════════════════════╗${NC}" >&2
    echo -e "${BOLD}${YELLOW}║                    ⚠️  EXPERIMENTAL v${SCRIPT_VERSION}                    ║${NC}" >&2
    echo -e "${BOLD}${YELLOW}║  This is experimental software. Use CLI for production.             ║${NC}" >&2
    echo -e "${BOLD}${YELLOW}╚═══════════════════════════════════════════════════════════════════════╝${NC}" >&2
    echo >&2
    
    # Allow dry-run without root
    if [[ "${dry_run}" == "true" ]]; then
        log_info "Running in dry-run mode (no root required)"
    else
        check_root
    fi
    
    # NOW create directories (after root check, or skipped for dry-run)
    if [[ "${dry_run}" != "true" ]]; then
        setup_directories
        make_scripts_executable
    fi
    
    # Skip all system checks in dry-run mode
    if [[ "${dry_run}" != "true" ]]; then
        # Ensure basic tools are available
        local required_base_tools=(curl wget gpg systemctl)
        for tool in "${required_base_tools[@]}"; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                log_warn "Required tool '$tool' not found, attempting to install..."
                if command -v apt-get >/dev/null 2>&1; then
                    apt-get update -qq && apt-get install -y -qq "$tool" 2>/dev/null || true
                elif command -v pacman >/dev/null 2>&1; then
                    pacman -Sy --noconfirm "$tool" 2>/dev/null || true
                elif command -v dnf >/dev/null 2>&1; then
                    dnf install -y "$tool" 2>/dev/null || true
                fi
            fi
        done
        
        check_os
        check_arch
    else
        log_info "Dry-run: skipping OS/arch/tool checks"
    fi
    
    # AUTO-COPY CONFIG FROM TEMPLATE if not exists
    if [[ ! -f "${config_file}" ]]; then
        if [[ -f "${CONFIG_FILE_EXAMPLE}" ]]; then
            log_info "Config not found, copying from template..."
            cp "${CONFIG_FILE_EXAMPLE}" "${config_file}"
            chmod 600 "${config_file}"
            log_info "Created ${config_file} from template"
        else
            die "Config file not found and no template at ${CONFIG_FILE_EXAMPLE}"
        fi
    fi
    
    # Skip all system checks in dry-run mode
    if [[ "${dry_run}" != "true" ]]; then
        # Ensure basic tools are available
        local required_base_tools=(curl wget gpg systemctl)
        for tool in "${required_base_tools[@]}"; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                log_warn "Required tool '$tool' not found, attempting to install..."
                if command -v apt-get >/dev/null 2>&1; then
                    apt-get update -qq && apt-get install -y -qq "$tool" 2>/dev/null || true
                elif command -v pacman >/dev/null 2>&1; then
                    pacman -Sy --noconfirm "$tool" 2>/dev/null || true
                elif command -v dnf >/dev/null 2>&1; then
                    dnf install -y "$tool" 2>/dev/null || true
                fi
            fi
        done
        
        check_os
        check_arch
    else
        log_info "Dry-run: skipping OS/arch/tool checks"
    fi
    
    # Load configuration (now guaranteed to exist)
    sanitize_config "${config_file}"
    load_config "${config_file}"
    validate_config
    
    [[ "${dry_run}" == "true" ]] && { log_success "Dry run successful - configuration valid"; exit 0; }
    
    prompt_missing_config "${config_file}" "${non_interactive}"
    select_modules "${modules_arg}" "${non_interactive}"
    resolve_dependencies MODULES_TO_INSTALL
    
    local to_install=()
    for module in "${MODULES_TO_INSTALL[@]}"; do
        if is_module_installed "${module}"; then
            log_warn "Module ${module} already installed (state: $(get_module_state ${module}))"
            [[ "${non_interactive}" != "true" ]] && { read -rp "Reinstall ${module}? [y/N] " -n 1 -r; echo >&2; [[ $REPLY =~ ^[Yy]$ ]] && to_install+=("${module}"); } || log_info "Skipping ${module}"
        else
            to_install+=("${module}")
        fi
    done
    MODULES_TO_INSTALL=("${to_install[@]}")
    [[ ${#MODULES_TO_INSTALL[@]} -eq 0 ]] && { log_info "Nothing to install"; exit 0; }
    
    [[ "${non_interactive}" != "true" ]] && { echo -e "\n${BOLD}Modules to install:${NC} ${MODULES_TO_INSTALL[*]}" >&2; read -rp "Proceed? [Y/n] " -n 1 -r; echo >&2; [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0; }
    
    local total=${#MODULES_TO_INSTALL[@]} current=0 failed=()
    for module in "${MODULES_TO_INSTALL[@]}"; do
        ((current++)); show_progress "${current}" "${total}" "${module}"; echo >&2
        if execute_module "${module}"; then 
            log_success "Module ${module} completed"
        else 
            log_error "Module ${module} failed"
            failed+=("${module}")
            [[ "${non_interactive}" == "true" ]] && die "Module ${module} failed in non-interactive mode"
            read -rp "Continue? [Y/n] " -n 1 -r; echo >&2
            [[ ! $REPLY =~ ^[Yy]$ ]] && break
        fi
    done
    show_summary
    [[ ${#failed[@]} -gt 0 ]] && { log_warn "Failed modules: ${failed[*]}"; exit 1; }
}

main "$@"