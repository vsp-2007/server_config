#!/bin/bash
# Monitoring Stack Module - Pi Server Setup v2
# Prometheus, Grafana, Alertmanager, Node Exporter with multi-arch support

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
log_debug()   { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${NC}[DEBUG]${NC} $*"; }

# Configuration with version pinning (updated to latest stable as of 2025)
PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-2.54.1}"
ALERTMANAGER_VERSION="${ALERTMANAGER_VERSION:-0.27.0}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.8.2}"
GRAFANA_VERSION="${GRAFANA_VERSION:-11.1.0}"
PROMETHEUS_RETENTION="${PROMETHEUS_RETENTION:-15d}"
PROMETHEUS_RETENTION_SIZE="${PROMETHEUS_RETENTION_SIZE:-2GB}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"

# Architecture detection
detect_arch() {
    local arch
    arch=$(uname -m)
    case "${arch}" in
        aarch64|arm64)
            PROM_ARCH="linux-arm64"
            NODE_ARCH="linux-arm64"
            ALERT_ARCH="linux-arm64"
            GRAFANA_ARCH="arm64"
            ;;
        armv7l|armhf)
            PROM_ARCH="linux-armv7"
            NODE_ARCH="linux-armv7"
            ALERT_ARCH="linux-armv7"
            GRAFANA_ARCH="armv7"
            ;;
        x86_64|amd64)
            PROM_ARCH="linux-amd64"
            NODE_ARCH="linux-amd64"
            ALERT_ARCH="linux-amd64"
            GRAFANA_ARCH="amd64"
            ;;
        *)
            log_error "Unsupported architecture: ${arch}"
            exit 1
            ;;
    esac
    log_info "Detected architecture: ${arch} -> Prometheus: ${PROM_ARCH}, Node Exporter: ${NODE_ARCH}, Alertmanager: ${ALERT_ARCH}, Grafana: ${GRAFANA_ARCH}"
    export PROM_ARCH NODE_ARCH ALERT_ARCH GRAFANA_ARCH
}

main() {
    log_info "Starting Monitoring Stack setup..."
    
    detect_arch
    
    # 1. Create service users
    create_service_users
    
    # 2. Install Node Exporter
    install_node_exporter
    
    # 3. Install Prometheus
    install_prometheus
    
    # 4. Install Alertmanager
    install_alertmanager
    
    # 5. Install Grafana
    install_grafana
    
    # 6. Configure provisioning
    configure_grafana_provisioning
    
    # 7. Configure firewall
    configure_firewall
    
    log_success "Monitoring Stack setup completed!"
}

create_service_users() {
    log_info "Creating service users..."
    
    local users=("prometheus" "node_exporter" "alertmanager")
    for user in "${users[@]}"; do
        if ! id "${user}" &>/dev/null; then
            useradd --no-create-home --shell /bin/false "${user}"
            log_info "Created user: ${user}"
        else
            log_info "User ${user} already exists"
        fi
    done
    
    # Create directories
    mkdir -p /etc/prometheus /var/lib/prometheus /etc/alertmanager /var/lib/alertmanager
    chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
    chown -R alertmanager:alertmanager /etc/alertmanager /var/lib/alertmanager
}

install_node_exporter() {
    log_info "Installing Node Exporter v${NODE_EXPORTER_VERSION}..."
    
    if [[ -f /usr/local/bin/node_exporter ]] && /usr/local/bin/node_exporter --version 2>&1 | grep -q "${NODE_EXPORTER_VERSION}"; then
        log_info "Node Exporter ${NODE_EXPORTER_VERSION} already installed"
    else
        cd /tmp
        local url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.${NODE_ARCH}.tar.gz"
        log_info "Downloading from: ${url}"
        
        curl -fsSL -o node_exporter.tar.gz "${url}"
        tar xzf node_exporter.tar.gz
        cp "node_exporter-${NODE_EXPORTER_VERSION}.${NODE_ARCH}/node_exporter" /usr/local/bin/
        rm -rf node_exporter*
    fi
    
    # Install systemd service
    install -m 644 "${SCRIPT_DIR}/../systemd/node_exporter.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now node_exporter
    
    # Verify
    sleep 2
    if systemctl is-active --quiet node_exporter; then
        log_success "Node Exporter running on port 9100"
    else
        log_error "Node Exporter failed to start"
        systemctl status node_exporter --no-pager
        return 1
    fi
}

install_prometheus() {
    log_info "Installing Prometheus v${PROMETHEUS_VERSION}..."
    
    if [[ -f /usr/local/bin/prometheus ]] && /usr/local/bin/prometheus --version 2>&1 | grep -q "${PROMETHEUS_VERSION}"; then
        log_info "Prometheus ${PROMETHEUS_VERSION} already installed"
    else
        cd /tmp
        local url="https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.${PROM_ARCH}.tar.gz"
        log_info "Downloading from: ${url}"
        
        curl -fsSL -o prometheus.tar.gz "${url}"
        tar xzf prometheus.tar.gz
        cp "prometheus-${PROMETHEUS_VERSION}.${PROM_ARCH}/prometheus" /usr/local/bin/
        cp "prometheus-${PROMETHEUS_VERSION}.${PROM_ARCH}/promtool" /usr/local/bin/
        rm -rf prometheus*
    fi
    
    # Copy config files
    install -m 644 "${SCRIPT_DIR}/../config/prometheus.yml" /etc/prometheus/
    install -m 644 "${SCRIPT_DIR}/../config/alert_rules.yml" /etc/prometheus/
    chown -R prometheus:prometheus /etc/prometheus
    
    # Install systemd service
    install -m 644 "${SCRIPT_DIR}/../systemd/prometheus.service" /etc/systemd/system/
    
    # Update service with version-specific args
    sed -i "s|__PROMETHEUS_RETENTION__|${PROMETHEUS_RETENTION}|g" /etc/systemd/system/prometheus.service
    sed -i "s|__PROMETHEUS_RETENTION_SIZE__|${PROMETHEUS_RETENTION_SIZE}|g" /etc/systemd/system/prometheus.service
    
    systemctl daemon-reload
    systemctl enable --now prometheus
    
    # Verify
    sleep 3
    if systemctl is-active --quiet prometheus; then
        log_success "Prometheus running on port 9090"
    else
        log_error "Prometheus failed to start"
        systemctl status prometheus --no-pager
        return 1
    fi
}

install_alertmanager() {
    log_info "Installing Alertmanager v${ALERTMANAGER_VERSION}..."
    
    if [[ -f /usr/local/bin/alertmanager ]] && /usr/local/bin/alertmanager --version 2>&1 | grep -q "${ALERTMANAGER_VERSION}"; then
        log_info "Alertmanager ${ALERTMANAGER_VERSION} already installed"
    else
        cd /tmp
        local url="https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.${ALERT_ARCH}.tar.gz"
        log_info "Downloading from: ${url}"
        
        curl -fsSL -o alertmanager.tar.gz "${url}"
        tar xzf alertmanager.tar.gz
        cp "alertmanager-${ALERTMANAGER_VERSION}.${ALERT_ARCH}/alertmanager" /usr/local/bin/
        cp "alertmanager-${ALERTMANAGER_VERSION}.${ALERT_ARCH}/amtool" /usr/local/bin/
        rm -rf alertmanager*
    fi
    
    # Configure Alertmanager
    configure_alertmanager
    
    # Install systemd service
    install -m 644 "${SCRIPT_DIR}/../systemd/alertmanager.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now alertmanager
    
    # Verify
    sleep 2
    if systemctl is-active --quiet alertmanager; then
        log_success "Alertmanager running on port 9093"
    else
        log_error "Alertmanager failed to start"
        systemctl status alertmanager --no-pager
        return 1
    fi
}

configure_alertmanager() {
    log_info "Configuring Alertmanager..."
    
    local config_file="/etc/alertmanager/alertmanager.yml"
    
    # Check if we have Telegram credentials
    if [[ -n "${TELEGRAM_ADMIN_TOKEN:-}" && -n "${TELEGRAM_ADMIN_CHAT_ID:-}" ]]; then
        log_info "Configuring Alertmanager with Telegram notifications..."
        
        cat > "${config_file}" <<EOF
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'telegram_bot'
  routes:
  - match:
      alertname: DailyReport
    receiver: 'telegram_bot'
    continue: true

receivers:
- name: 'telegram_bot'
  telegram_configs:
  - bot_token: '${TELEGRAM_ADMIN_TOKEN}'
    chat_id: ${TELEGRAM_ADMIN_CHAT_ID}
    parse_mode: 'HTML'
    message: '{{ range .Alerts }}{{ if eq .Labels.alertname "DailyReport" }}📊 <b>DAILY SYSTEM REPORT</b> 📊{{ else }}{{ if eq .Status "firing" }}🔥 <b>PROBLEM DETECTED</b> 🔥{{ else }}✅ <b>ISSUE RESOLVED</b>{{ end }}<b>{{ .Labels.alertname }}</b><pre>{{ .Annotations.summary }}</pre><i>{{ .Annotations.description }}</i>Severity: <b>{{ .Labels.severity }}</b>{{ end }}{{ end }}'

inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'dev', 'instance']
EOF
    else
        log_warn "No Telegram credentials provided. Using minimal Alertmanager config."
        cat > "${config_file}" <<EOF
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'webhook_fallback'

receivers:
- name: 'webhook_fallback'
  webhook_configs:
  - url: 'http://127.0.0.1:5001/'
EOF
    fi
    
    chown alertmanager:alertmanager "${config_file}"
    chmod 640 "${config_file}"
}

install_grafana() {
    log_info "Installing Grafana v${GRAFANA_VERSION}..."
    
    if command -v grafana-server >/dev/null 2>&1; then
        local installed_version
        installed_version=$(grafana-server -v 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        log_info "Grafana ${installed_version} already installed"
        
        # Still ensure it's configured properly
        configure_grafana
        return 0
    fi
    
    # Install dependencies
    apt-get install -y -qq apt-transport-https software-properties-common wget libfontconfig1 musl
    
    # Add Grafana repository
    mkdir -p /etc/apt/keyrings/
    rm -f /tmp/grafana.key
    wget -q -O /tmp/grafana.key https://apt.grafana.com/gpg.key
    cat /tmp/grafana.key | gpg --dearmor | tee /etc/apt/keyrings/grafana.gpg > /dev/null
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | tee /etc/apt/sources.list.d/grafana.list
    
    apt-get update -qq
    apt-get install -y -qq grafana="${GRAFANA_VERSION}"
    
    configure_grafana
}

configure_grafana() {
    log_info "Configuring Grafana..."
    
    # Ensure config directory
    mkdir -p /etc/grafana
    
    # Bind to all interfaces
    if [[ -f /etc/grafana/grafana.ini ]]; then
        sed -i 's/^;http_addr =.*/http_addr = 0.0.0.0/' /etc/grafana/grafana.ini
        sed -i 's/^http_addr =.*/http_addr = 0.0.0.0/' /etc/grafana/grafana.ini
    fi
    
    # Set admin user if not default
    if [[ "${GRAFANA_ADMIN_USER}" != "admin" ]]; then
        sed -i "s/^;admin_user =.*/admin_user = ${GRAFANA_ADMIN_USER}/" /etc/grafana/grafana.ini
        sed -i "s/^admin_user =.*/admin_user = ${GRAFANA_ADMIN_USER}/" /etc/grafana/grafana.ini
    fi
    
    # Stop service to safely reset password
    systemctl stop grafana-server 2>/dev/null || true
    
    # Reset admin password if provided
    if [[ -n "${GRAFANA_ADMIN_PASSWORD}" ]]; then
        log_info "Setting Grafana admin password..."
        grafana-cli admin reset-admin-password "${GRAFANA_ADMIN_PASSWORD}" --homepath "/usr/share/grafana" --config "/etc/grafana/grafana.ini" 2>/dev/null || {
            log_warn "grafana-cli password reset failed, will retry after start"
        }
    fi
    
    # Fix permissions
    chown -R grafana:grafana /var/lib/grafana
    chmod -R 750 /var/lib/grafana
    
    systemctl daemon-reload
    systemctl unmask grafana-server 2>/dev/null || true
    systemctl enable grafana-server
    systemctl restart grafana-server
    
    # Verify
    sleep 5
    if systemctl is-active --quiet grafana-server; then
        log_success "Grafana running on port 3000 (user: ${GRAFANA_ADMIN_USER})"
    else
        log_error "Grafana failed to start"
        systemctl status grafana-server --no-pager
        return 1
    fi
}

configure_grafana_provisioning() {
    log_info "Configuring Grafana provisioning (datasources & dashboards)..."
    
    mkdir -p /etc/grafana/provisioning/datasources
    mkdir -p /etc/grafana/provisioning/dashboards
    
    # Datasource provisioning
    cat > /etc/grafana/provisioning/datasources/prometheus.yaml <<EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: false
    uid: prometheus
EOF
    
    # Dashboard provisioning
    cat > /etc/grafana/provisioning/dashboards/default.yaml <<EOF
apiVersion: 1

providers:
  - name: 'Default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards
EOF
    
    # Copy Node Exporter dashboard if exists
    if [[ -f "${SCRIPT_DIR}/../config/node_exporter_dashboard.json" ]]; then
        install -m 644 "${SCRIPT_DIR}/../config/node_exporter_dashboard.json" /etc/grafana/provisioning/dashboards/
    elif [[ -f "${SCRIPT_DIR}/../config/node_exporter_dashboard.json" ]]; then
        install -m 644 "${SCRIPT_DIR}/../config/node_exporter_dashboard.json" /etc/grafana/provisioning/dashboards/
    fi
    
    chown -R root:grafana /etc/grafana/provisioning
    chmod -R 640 /etc/grafana/provisioning/dashboards/* 2>/dev/null || true
    chmod -R 640 /etc/grafana/provisioning/datasources/* 2>/dev/null || true
    
    # Restart Grafana to pick up provisioning
    systemctl restart grafana-server
    
    log_success "Grafana provisioning configured"
}

configure_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        log_info "Configuring UFW firewall for monitoring ports..."
        ufw allow 3000/tcp comment "Grafana" || true
        ufw allow 9090/tcp comment "Prometheus" || true
        ufw allow 9093/tcp comment "Alertmanager" || true
        ufw allow 9100/tcp comment "Node Exporter" || true
        log_success "Firewall rules added"
    fi
}

# Run main
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
main "$@"