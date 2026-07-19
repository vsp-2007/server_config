#!/bin/bash
# Stirling-PDF Module - Pi Server Setup v2
# Local PDF manipulation tool (multi-arch, secure, optimized for Pi)

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
STIRLING_PDF_VERSION="${STIRLING_PDF_VERSION:-2.4.5}"
STIRLING_PDF_PORT="${STIRLING_PDF_PORT:-8080}"
STIRLING_PDF_MEMORY_MIN="${STIRLING_PDF_MEMORY_MIN:-512m}"
STIRLING_PDF_MEMORY_MAX="${STIRLING_PDF_MEMORY_MAX:-1024m}"
PI_USER="${PI_USER:-piadmin}"

APP_DIR="/opt/Stirling-PDF"
USER_NAME="stirlingpdf"
JAR_NAME="Stirling-PDF.jar"

main() {
    log_info "Starting Stirling-PDF setup..."

    detect_arch
    install_dependencies
    configure_swap
    create_service_user
    setup_directories
    download_application
    configure_application
    install_systemd_service
    create_desktop_shortcut
    configure_firewall

    log_success "Stirling-PDF setup completed!"
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "${arch}" in
        aarch64|arm64)
            JAVA_ARCH="aarch64"
            ;;
        armv7l|armhf)
            JAVA_ARCH="arm"
            log_warn "armv7 detected - performance may be limited"
            ;;
        x86_64|amd64)
            JAVA_ARCH="x64"
            ;;
        *)
            log_error "Unsupported architecture: ${arch}"
            exit 1
            ;;
    esac
    log_info "Java architecture: ${JAVA_ARCH}"
}

install_dependencies() {
    log_info "Installing dependencies (Java 21, LibreOffice, Tesseract, Python)..."

    apt-get update -qq

    # Try Java 21 first, fallback to 17
    if ! apt-get install -y -qq openjdk-21-jdk 2>/dev/null; then
        log_warn "OpenJDK 21 not available, trying 17..."
        apt-get install -y -qq openjdk-17-jdk
    fi

    # Core dependencies
    apt-get install -y -qq \
        libreoffice-writer libreoffice-calc libreoffice-impress \
        tesseract-ocr tesseract-ocr-eng \
        python3 python3-pip python3-venv \
        ca-certificates curl gnupg wget \
        dphys-swapfile \
        fontconfig fonts-dejavu-core fonts-liberation2

    # Verify Java
    java -version 2>&1 | head -1

    log_success "Dependencies installed"
}

configure_swap() {
    log_info "Configuring swap for Java workloads..."

    if [[ -f /etc/dphys-swapfile ]]; then
        local current_swap
        current_swap=$(grep "^CONF_SWAPSIZE=" /etc/dphys-swapfile | cut -d= -f2)
        current_swap=${current_swap:-0}

        if [[ "${current_swap}" -lt 2048 ]]; then
            log_info "Increasing swap to 2GB (was ${current_swap}MB)..."
            sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
            systemctl restart dphys-swapfile
            log_success "Swap increased to 2GB"
        else
            log_info "Swap already at ${current_swap}MB"
        fi
    fi
}

create_service_user() {
    log_info "Creating service user: ${USER_NAME}"

    if ! id "${USER_NAME}" &>/dev/null; then
        useradd -r -s /bin/false -d "${APP_DIR}" -c "Stirling-PDF Service" "${USER_NAME}"
    fi
}

setup_directories() {
    log_info "Setting up application directories..."

    mkdir -p "${APP_DIR}"/{logs,configs,customFiles,tempFiles}
    chown -R "${USER_NAME}:${USER_NAME}" "${APP_DIR}"
    chmod 750 "${APP_DIR}"
}

download_application() {
    log_info "Downloading Stirling-PDF v${STIRLING_PDF_VERSION}..."

    cd /tmp
    local url="https://github.com/Stirling-Tools/Stirling-PDF/releases/download/v${STIRLING_PDF_VERSION}/Stirling-PDF.jar"

    # Stop service if running
    systemctl stop stirling-pdf 2>/dev/null || true

    # Download with validation
    if ! wget -q -O "${APP_DIR}/${JAR_NAME}.tmp" "${url}"; then
        log_error "Failed to download Stirling-PDF"
        return 1
    fi

    # Validate file size (should be > 50MB for v2.4.5)
    local file_size
    file_size=$(stat -c%s "${APP_DIR}/${JAR_NAME}.tmp")
    if [[ "${file_size}" -lt 50000000 ]]; then
        log_error "Downloaded file too small (${file_size} bytes) - likely corrupted"
        rm -f "${APP_DIR}/${JAR_NAME}.tmp"
        return 1
    fi

    mv "${APP_DIR}/${JAR_NAME}.tmp" "${APP_DIR}/${JAR_NAME}"
    chown "${USER_NAME}:${USER_NAME}" "${APP_DIR}/${JAR_NAME}"
    chmod 644 "${APP_DIR}/${JAR_NAME}"

    log_success "Stirling-PDF JAR downloaded and validated (${file_size} bytes)"
}

configure_application() {
    log_info "Configuring Stirling-PDF (no-login mode, optimized for Pi)..."

    # Create settings.yml with security and performance settings
    cat > "${APP_DIR}/settings.yml" <<EOF
security:
  enableLogin: false
  # Add password protection by setting enableLogin: true and configuring below
  # password: ""
  # requireLoginForRemoteAccess: true

system:
  # Disable heavy features for Pi optimization
  enableAlphaFunctionality: false
  enableBetaFunctionality: false

  # Locale
  defaultLocale: en-US

  # File handling
  maxFileSize: 100MB
  maxFiles: 10

  # Cleanup
  cleanupCron: "0 3 * * *"
  cleanupMaxAge: 24h

# OCR
ocr:
  language: eng
  dpi: 300

# PDF
pdf:
  # Reduce quality for performance
  imageDpi: 150
  jpegQuality: 0.8
EOF

    chown "${USER_NAME}:${USER_NAME}" "${APP_DIR}/settings.yml"
    chmod 640 "${APP_DIR}/settings.yml"

    log_success "Application configured"
}

install_systemd_service() {
    log_info "Installing systemd service..."

    cat > /etc/systemd/system/stirling-pdf.service <<EOF
[Unit]
Description=Stirling-PDF Service
Documentation=https://github.com/Stirling-Tools/Stirling-PDF
After=network.target
Wants=network.target

[Service]
Type=simple
User=${USER_NAME}
Group=${USER_NAME}
WorkingDirectory=${APP_DIR}

# Java optimized for Pi (low memory, serial GC)
ExecStart=/usr/bin/java \
    -Xms${STIRLING_PDF_MEMORY_MIN} \
    -Xmx${STIRLING_PDF_MEMORY_MAX} \
    -XX:+UseSerialGC \
    -XX:TieredStopAtLevel=1 \
    -Djava.security.egd=file:/dev/./urandom \
    -Dfile.encoding=UTF-8 \
    -Dserver.port=${STIRLING_PDF_PORT} \
    -Dsystem.defaultLocale=en-US \
    -DSECURITY_ENABLELOGIN=false \
    -DDOCKER_ENABLE_SECURITY=false \
    -DDISABLE_ADDITIONAL_FEATURES=true \
    -jar ${APP_DIR}/${JAR_NAME}

ExecStop=/bin/kill -15 \$MAINPID
Restart=always
RestartSec=10
TimeoutStartSec=300
TimeoutStopSec=30

# Security hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${APP_DIR} /tmp
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
# MemoryDenyWriteExecute=yes - DISABLED: breaks JVM JIT compilation
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

# Resource limits
LimitNOFILE=65536
LimitNPROC=512
MemoryMax=2G
CPUQuota=100%

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable stirling-pdf
    systemctl restart stirling-pdf

    # Wait and verify
    sleep 10
    if systemctl is-active --quiet stirling-pdf; then
        log_success "Stirling-PDF service running on port ${STIRLING_PDF_PORT}"
    else
        log_error "Stirling-PDF failed to start"
        systemctl status stirling-pdf --no-pager
        journalctl -u stirling-pdf --no-pager -n 50
        return 1
    fi
}

create_desktop_shortcut() {
    log_info "Creating desktop shortcut..."

    local desktop_dir="/home/${PI_USER}/Desktop"
    [[ -d "${desktop_dir}" ]] || desktop_dir="/home/${PI_USER}"

    if [[ -d "${desktop_dir}" ]]; then
        cat > "${desktop_dir}/Stirling-PDF.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Stirling PDF
Comment=Local PDF Tools
Exec=xdg-open http://localhost:${STIRLING_PDF_PORT}
Icon=utilities-terminal
Terminal=false
Categories=Office;Utility;
StartupNotify=false
EOF
        chmod +x "${desktop_dir}/Stirling-PDF.desktop"
        chown "${PI_USER}:${PI_USER}" "${desktop_dir}/Stirling-PDF.desktop"
        log_success "Desktop shortcut created"
    fi
}

configure_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        log_info "Configuring UFW for Stirling-PDF..."
        ufw allow "${STIRLING_PDF_PORT}/tcp" comment "Stirling-PDF" || true
        log_success "Firewall rule added"
    fi
}

# Run
main "$@"