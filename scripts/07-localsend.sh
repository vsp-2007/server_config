#!/bin/bash
# LocalSend Module - Pi Server Setup v2
# Cross-platform file sharing (multi-arch support)

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
LOCALSEND_VERSION="${LOCALSEND_VERSION:-1.17.0}"
LOCALSEND_PORT="${LOCALSEND_PORT:-53317}"
PI_USER="${PI_USER:-piadmin}"

main() {
    log_info "Starting LocalSend setup..."
    
    detect_arch
    install_localsend
    create_desktop_shortcut
    configure_firewall
    
    log_success "LocalSend setup completed!"
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "${arch}" in
        aarch64|arm64)
            LOCAL_ARCH="arm64"
            DEB_ARCH="arm-64"
            ;;
        armv7l|armhf)
            LOCAL_ARCH="armv7"
            DEB_ARCH="arm-64"  # LocalSend doesn't have armv7, try arm64
            log_warn "LocalSend may not work on armv7, trying arm64 binary"
            ;;
        x86_64|amd64)
            LOCAL_ARCH="amd64"
            DEB_ARCH="x86-64"
            ;;
        *)
            log_error "Unsupported architecture for LocalSend: ${arch}"
            exit 1
            ;;
    esac
    log_info "LocalSend architecture: ${LOCAL_ARCH} (DEB: ${DEB_ARCH})"
    export LOCAL_ARCH DEB_ARCH
}

install_localsend() {
    log_info "Installing LocalSend v${LOCALSEND_VERSION}..."
    
    # Check if already installed
    if [[ -f /opt/localsend/localsend_app ]] || [[ -f /usr/share/applications/localsend_app.desktop ]]; then
        log_info "LocalSend already installed"
        return 0
    fi
    
    cd /tmp
    local url="https://github.com/localsend/localsend/releases/download/v${LOCALSEND_VERSION}/LocalSend-${LOCALSEND_VERSION}-linux-${DEB_ARCH}.deb"
    local deb_file="/tmp/localsend.deb"
    
    log_info "Downloading from: ${url}"
    
    if ! curl -fsSL -o "${deb_file}" "${url}"; then
        log_error "Failed to download LocalSend"
        return 1
    fi
    
    # Install
    apt-get install -y -qq "${deb_file}"
    rm -f "${deb_file}"
    
    # Verify
    if [[ -f /opt/localsend/localsend_app ]] || [[ -f /usr/bin/localsend ]]; then
        log_success "LocalSend installed"
    else
        log_error "LocalSend installation verification failed"
        return 1
    fi
}

create_desktop_shortcut() {
    log_info "Creating desktop shortcut..."
    
    local desktop_dir="/home/${PI_USER}/Desktop"
    [[ -d "${desktop_dir}" ]] || desktop_dir="/home/${PI_USER}"
    
    if [[ -d "${desktop_dir}" ]]; then
        # Find the .desktop file
        local desktop_src=""
        for path in \
            "/usr/share/applications/localsend_app.desktop" \
            "/opt/localsend/share/applications/localsend_app.desktop" \
            "/opt/localsend/localsend_app.desktop"; do
            if [[ -f "${path}" ]]; then
                desktop_src="${path}"
                break
            fi
        done
        
        if [[ -n "${desktop_src}" ]]; then
            cp "${desktop_src}" "${desktop_dir}/LocalSend.desktop"
        else
            # Create manually
            cat > "${desktop_dir}/LocalSend.desktop" <<EOF
[Desktop Entry]
Name=LocalSend
Comment=Share files to nearby devices
Exec=/opt/localsend/localsend_app
Icon=/opt/localsend/data/flutter_assets/assets/img/logo-512.png
Terminal=false
Type=Application
Categories=Network;FileTransfer;
StartupNotify=true
EOF
        fi
        
        chmod +x "${desktop_dir}/LocalSend.desktop"
        chown "${PI_USER}:${PI_USER}" "${desktop_dir}/LocalSend.desktop"
        log_success "Desktop shortcut created"
    else
        log_warn "Desktop directory not found, skipping shortcut"
    fi
}

configure_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        log_info "Configuring UFW for LocalSend..."
        ufw allow "${LOCALSEND_PORT}/tcp" comment "LocalSend" || true
        ufw allow "${LOCALSEND_PORT}/udp" comment "LocalSend" || true
        log_success "Firewall rules added"
    fi
}

# Run
main "$@"