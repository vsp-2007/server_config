#!/bin/bash
# Common library functions for pi-server-setup scripts
# Source this in your scripts: source "${SCRIPT_DIR}/../lib/common.sh"

set -euo pipefail

# ============================================================================
# COLORS (only if stdout is a terminal)
# ============================================================================
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

# ============================================================================
# LOGGING
# ============================================================================
_log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${msg}"
}

log_info()    { _log "INFO"    "${BLUE}${*}${NC}"; }
log_success() { _log "SUCCESS" "${GREEN}${*}${NC}"; }
log_warn()    { _log "WARN"    "${YELLOW}${*}${NC}"; }
log_error()   { _log "ERROR"   "${RED}${*}${NC}"; }
log_debug()   { [[ "${DEBUG:-false}" == "true" ]] && _log "DEBUG" "${DIM}${*}${NC}"; }

# ============================================================================
# UTILITIES
# ============================================================================

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        return 1
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Get primary IPv4 address
get_primary_ip() {
    hostname -I | awk '{print $1}'
}

# Get primary network interface
get_primary_interface() {
    ip route | grep default | awk '{print $5}' | head -1
}

# Generate random password
generate_password() {
    local length="${1:-16}"
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-"${length}"
}

# Escape string for sed replacement
sed_escape() {
    printf '%s\n' "$1" | sed 's/[[\.*^$()+?{|\\]/\\&/g'
}

# Save variable to config file
save_config_var() {
    local var_name="$1"
    local var_value="$2"
    local config_file="${3:-${CONFIG_FILE:-settings.conf}}"
    
    local escaped_value
    escaped_value=$(sed_escape "${var_value}")
    
    if grep -q "^${var_name}=" "${config_file}" 2>/dev/null; then
        sed -i "s|^${var_name}=.*|${var_name}=\"${escaped_value}\"|" "${config_file}"
    else
        echo "${var_name}=\"${escaped_value}\"" >> "${config_file}"
    fi
    chmod 600 "${config_file}" 2>/dev/null || true
}

# Load config file safely
load_config() {
    local config_file="${1:-${CONFIG_FILE:-settings.conf}}"
    
    if [[ ! -f "${config_file}" ]]; then
        log_error "Config file not found: ${config_file}"
        return 1
    fi
    
    # Check permissions
    local perms
    perms=$(stat -c "%a" "${config_file}" 2>/dev/null || stat -f "%A" "${config_file}" 2>/dev/null)
    if [[ "${perms}" != "600" && "${perms}" != "400" ]]; then
        log_warn "Config file has loose permissions (${perms}), fixing to 600"
        chmod 600 "${config_file}"
    fi
    
    # shellcheck source=/dev/null
    source "${config_file}"
}

# Validate required variables
validate_required_vars() {
    local vars=("$@")
    local errors=0
    
    for var in "${vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required variable ${var} is not set"
            ((errors++))
        fi
    done
    
    return "${errors}"
}

# Validate IP address/CIDR
validate_ip_cidr() {
    local ip="$1"
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || return 1
    
    # Validate octets
    local octets
    IFS='./' read -ra octets <<< "${ip}"
    for octet in "${octets[@]:0:4}"; do
        [[ "${octet}" -ge 0 && "${octet}" -le 255 ]] || return 1
    done
    return 0
}

# Validate Telegram bot token format
validate_telegram_token() {
    local token="$1"
    [[ "${token}" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]
}

# Validate chat ID (numeric, can be negative for groups)
validate_chat_id() {
    local chat_id="$1"
    [[ "${chat_id}" =~ ^-?[0-9]+$ ]]
}

# Run command with retry
retry_command() {
    local max_attempts="${1:-3}"
    local delay="${2:-5}"
    shift 2
    local cmd=("$@")
    
    local attempt=1
    while [[ ${attempt} -le ${max_attempts} ]]; do
        if "${cmd[@]}"; then
            return 0
        fi
        log_warn "Command failed (attempt ${attempt}/${max_attempts}), retrying in ${delay}s..."
        sleep "${delay}"
        ((attempt++))
    done
    
    log_error "Command failed after ${max_attempts} attempts: ${cmd[*]}"
    return 1
}

# Backup file with timestamp
backup_file() {
    local file="$1"
    local backup_dir="${BACKUP_DIR:-/var/lib/pi-server-setup/backups}"
    
    if [[ -f "${file}" ]]; then
        mkdir -p "${backup_dir}"
        local backup="${backup_dir}/$(basename "${file}").$(date +%Y%m%d_%H%M%S).bak"
        cp "${file}" "${backup}"
        log_debug "Backed up ${file} to ${backup}"
    fi
}

# Install package if not present
ensure_package() {
    local pkg="$1"
    if ! dpkg -l | grep -q "^ii  ${pkg} "; then
        log_info "Installing package: ${pkg}"
        apt-get update -qq && apt-get install -y -qq "${pkg}"
    fi
}

# Enable and start systemd service
enable_start_service() {
    local service="$1"
    systemctl daemon-reload
    systemctl enable "${service}"
    systemctl restart "${service}"
    sleep 2
    if systemctl is-active --quiet "${service}"; then
        log_success "Service ${service} is running"
        return 0
    else
        log_error "Service ${service} failed to start"
        systemctl status "${service}" --no-pager
        return 1
    fi
}

# Check if service is active
is_service_active() {
    systemctl is-active --quiet "$1"
}

# Get architecture for downloads
get_download_arch() {
    local arch
    arch=$(uname -m)
    case "${arch}" in
        aarch64|arm64) echo "arm64" ;;
        armv7l|armhf)  echo "armv7" ;;
        x86_64|amd64)  echo "amd64" ;;
        *)             echo "unknown" ;;
    esac
}

# Download and verify file
download_file() {
    local url="$1"
    local output="$2"
    local expected_min_size="${3:-0}"
    
    log_info "Downloading ${url}"
    if ! curl -fsSL -o "${output}" "${url}"; then
        log_error "Download failed: ${url}"
        return 1
    fi
    
    local size
    size=$(stat -c%s "${output}" 2>/dev/null || stat -f%z "${output}" 2>/dev/null)
    if [[ ${size} -lt ${expected_min_size} ]]; then
        log_error "Downloaded file too small (${size} bytes, expected >${expected_min_size}): ${output}"
        rm -f "${output}"
        return 1
    fi
    
    log_success "Downloaded ${size} bytes to ${output}"
    return 0
}

# Create system user if not exists
ensure_system_user() {
    local user="$1"
    local home="${2:-/nonexistent}"
    local shell="${3:-/bin/false}"
    local comment="${4:-System service user}"
    
    if ! id "${user}" &>/dev/null; then
        useradd -r -s "${shell}" -d "${home}" -c "${comment}" "${user}"
        log_info "Created system user: ${user}"
    fi
}

# Create directory with permissions
ensure_directory() {
    local dir="$1"
    local owner="${2:-root:root}"
    local mode="${3:-755}"
    
    mkdir -p "${dir}"
    chown "${owner}" "${dir}"
    chmod "${mode}" "${dir}"
}

# Configure logrotate
setup_logrotate() {
    local name="$1"
    local log_path="$2"
    local config="${3:-}"
    
    cat > "/etc/logrotate.d/${name}" <<EOF
${log_path} {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 640 root adm
    sharedscripts
    ${config}
}
EOF
}

# ============================================================================
# PROGRESS INDICATORS
# ============================================================================

show_spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p "${pid}" > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " [%c]  " "${spinstr}"
        local spinstr=${temp}${spinstr%"${temp}"}
        sleep ${delay}
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

run_with_spinner() {
    local msg="$1"
    shift
    echo -n "${msg} "
    ("$@") &
    local pid=$!
    show_spinner "${pid}"
    wait "${pid}"
    local result=$?
    if [[ ${result} -eq 0 ]]; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
    fi
    return ${result}
}

# ============================================================================
# EXPORTS
# ============================================================================
export -f log_info log_success log_warn log_error log_debug
export -f check_root command_exists get_primary_ip get_primary_interface
export -f generate_password sed_escape save_config_var load_config
export -f validate_required_vars validate_ip_cidr validate_telegram_token validate_chat_id
export -f retry_command backup_file ensure_package enable_start_service
export -f is_service_active get_download_arch download_file
export -f ensure_system_user ensure_directory setup_logrotate
export -f show_spinner run_with_spinner