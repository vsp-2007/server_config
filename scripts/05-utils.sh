#!/bin/bash
# Utilities Module - Pi Server Setup v2
# System reports, maintenance cron jobs, useful scripts

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
PI_USER="${PI_USER:-piadmin}"
TELEGRAM_ADMIN_TOKEN="${TELEGRAM_ADMIN_TOKEN:-}"
TELEGRAM_ADMIN_CHAT_ID="${TELEGRAM_ADMIN_CHAT_ID:-}"

main() {
    log_info "Starting Utilities setup..."
    
    install_report_scripts
    setup_cron_jobs
    create_maintenance_scripts
    configure_logrotate
    
    log_success "Utilities setup completed!"
}

install_report_scripts() {
    log_info "Installing system report scripts..."
    
    # Daily/boot report script
    cat > /usr/local/bin/send_report.sh <<'EOF'
#!/bin/bash
# Daily system report for Telegram

set -euo pipefail

TELEGRAM_TOKEN="${TELEGRAM_ADMIN_TOKEN:-}"
CHAT_ID="${TELEGRAM_ADMIN_CHAT_ID:-}"

if [[ -z "${TELEGRAM_TOKEN}" || -z "${CHAT_ID}" ]]; then
    echo "Telegram credentials not configured"
    exit 0
fi

# Gather system stats
HOSTNAME=$(hostname)
IP=$(hostname -I | awk '{print $1}')
UPTIME=$(uptime -p)
TEMP=$(vcgencmd measure_temp 2>/dev/null | sed 's/temp=//' || echo "N/A")

MEM_INFO=$(free -h | awk 'NR==2{printf "Used: %s / Total: %s", $3, $2}')
DISK_INFO=$(df -h / | awk 'NR==2{printf "Used: %s / Total: %s (%s)", $3, $2, $5}')

# Service status
SERVICES=("prometheus" "node_exporter" "alertmanager" "grafana-server" "pihole-FTL" "smbd" "n8n" "stirling-pdf" "nginx" "cockpit.socket" "webmin" "tailscale")
SERVICE_STATUS=""
for svc in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
        SERVICE_STATUS+="✅ ${svc}\n"
    elif systemctl list-unit-files | grep -q "^${svc}"; then
        SERVICE_STATUS+="❌ ${svc} (inactive)\n"
    fi
done

# Pi-hole stats
PIHOLE_STATS=""
if command -v pihole >/dev/null; then
    PIHOLE_JSON=$(pihole -c -j 2>/dev/null || echo "{}")
    QUERIES=$(echo "${PIHOLE_JSON}" | jq -r '.dns_queries_today // "N/A"')
    BLOCKED=$(echo "${PIHOLE_JSON}" | jq -r '.ads_blocked_today // "N/A"')
    PERCENT=$(echo "${PIHOLE_JSON}" | jq -r '.ads_percentage_today // "N/A"')
    DOMAINS=$(echo "${PIHOLE_JSON}" | jq -r '.domains_being_blocked // "N/A"')
    STATUS=$(echo "${PIHOLE_JSON}" | jq -r '.status // "unknown"')
    PIHOLE_STATS="\n🛡️ <b>Pi-hole Stats</b>\nQueries: ${QUERIES}\nBlocked: ${BLOCKED} (${PERCENT}%)\nDomains: ${DOMAINS}\nStatus: ${STATUS}"
fi

# Build message
MESSAGE="📊 <b>DAILY SYSTEM REPORT</b> 📊
<b>Host:</b> ${HOSTNAME}
<b>IP:</b> ${IP}
<b>Uptime:</b> ${UPTIME}
<b>Temp:</b> ${TEMP}
<b>RAM:</b> ${MEM_INFO}
<b>Disk:</b> ${DISK_INFO}
${PIHOLE_STATS}

<b>Services:</b>
${SERVICE_STATUS}"

# Send to Telegram
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" \
    -d parse_mode="HTML" \
    -d text="${MESSAGE}" >/dev/null

# Also log locally
echo "[$(date)] Report sent" >> /var/log/pi-server-report.log
EOF

    chmod 755 /usr/local/bin/send_report.sh
    
    # Alertmanager webhook receiver script
    cat > /usr/local/bin/send_report_to_alertmanager.sh <<'EOF'
#!/bin/bash
# Webhook receiver for Alertmanager -> Telegram

set -euo pipefail

TELEGRAM_TOKEN="${TELEGRAM_ADMIN_TOKEN:-}"
CHAT_ID="${TELEGRAM_ADMIN_CHAT_ID:-}"

if [[ -z "${TELEGRAM_TOKEN}" || -z "${CHAT_ID}" ]]; then
    exit 0
fi

# Read JSON from stdin
PAYLOAD=$(cat)

# Extract alert info
ALERT_NAME=$(echo "${PAYLOAD}" | jq -r '.alerts[0].labels.alertname // "Unknown"')
STATUS=$(echo "${PAYLOAD}" | jq -r '.status // "unknown"')
SEVERITY=$(echo "${PAYLOAD}" | jq -r '.alerts[0].labels.severity // "info"')
SUMMARY=$(echo "${PAYLOAD}" | jq -r '.alerts[0].annotations.summary // "No summary"')
DESCRIPTION=$(echo "${PAYLOAD}" | jq -r '.alerts[0].annotations.description // "No description"')
INSTANCE=$(echo "${PAYLOAD}" | jq -r '.alerts[0].labels.instance // "unknown"')

# Format message
if [[ "${STATUS}" == "firing" ]]; then
    ICON="🔥"
    TITLE="PROBLEM DETECTED"
else
    ICON="✅"
    TITLE="ISSUE RESOLVED"
fi

MESSAGE="${ICON} <b>${TITLE}</b> ${ICON}
<b>Alert:</b> ${ALERT_NAME}
<b>Severity:</b> ${SEVERITY}
<b>Instance:</b> ${INSTANCE}
<b>Summary:</b> ${SUMMARY}
<b>Description:</b> ${DESCRIPTION}"

# Send to Telegram
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" \
    -d parse_mode="HTML" \
    -d text="${MESSAGE}" >/dev/null
EOF

    chmod 755 /usr/local/bin/send_report_to_alertmanager.sh
    
    log_success "Report scripts installed"
}

setup_cron_jobs() {
    log_info "Setting up cron jobs..."
    
    # Daily report at 8:00 AM
    (crontab -l 2>/dev/null | grep -v "send_report.sh"; echo "0 8 * * * /usr/local/bin/send_report.sh") | crontab -
    
    # Boot report
    (crontab -l 2>/dev/null | grep -v "@reboot send_report.sh"; echo "@reboot /usr/local/bin/send_report.sh") | crontab -
    
    # Weekly package cleanup (Sunday 2 AM)
    (crontab -l 2>/dev/null | grep -v "apt-get autoremove"; echo "0 2 * * 0 apt-get autoremove -y && apt-get autoclean -y") | crontab -
    
    # Daily log rotation check
    (crontab -l 2>/dev/null | grep -v "logrotate"; echo "0 3 * * * /usr/sbin/logrotate /etc/logrotate.conf") | crontab -
    
    log_success "Cron jobs configured"
}

create_maintenance_scripts() {
    log_info "Creating maintenance scripts..."
    
    # System update script
    cat > /usr/local/bin/pi-update.sh <<'EOF'
#!/bin/bash
# Safe system update with logging

LOG_FILE="/var/log/pi-update.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=== $(date) Starting system update ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get autoremove -y
apt-get autoclean -y
echo "=== $(date) System update complete ==="
EOF
    chmod 755 /usr/local/bin/pi-update.sh
    
    # Disk space check
    cat > /usr/local/bin/pi-disk-check.sh <<'EOF'
#!/bin/bash
# Disk space alert

THRESHOLD=85
USAGE=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')

if [[ ${USAGE} -ge ${THRESHOLD} ]]; then
    MESSAGE="⚠️ <b>Disk Space Alert</b>\nUsage: ${USAGE}% (threshold: ${THRESHOLD}%)\n$(df -h /)"
    if [[ -n "${TELEGRAM_ADMIN_TOKEN:-}" && -n "${TELEGRAM_ADMIN_CHAT_ID:-}" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_ADMIN_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_ADMIN_CHAT_ID}" \
            -d parse_mode="HTML" \
            -d text="${MESSAGE}" >/dev/null
    fi
fi
EOF
    chmod 755 /usr/local/bin/pi-disk-check.sh
    
    # Add disk check to cron (every 6 hours)
    (crontab -l 2>/dev/null | grep -v "pi-disk-check"; echo "0 */6 * * * /usr/local/bin/pi-disk-check.sh") | crontab -
    
    log_success "Maintenance scripts created"
}

configure_logrotate() {
    log_info "Configuring logrotate for project logs..."
    
    cat > /etc/logrotate.d/InitOps <<EOF
/var/log/InitOps/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 640 root adm
    sharedscripts
    postrotate
        systemctl reload rsyslog >/dev/null 2>&1 || true
    endscript
}

/var/log/pi-server-report.log {
    weekly
    missingok
    rotate 8
    compress
    delaycompress
    notifempty
    create 640 root adm
}
EOF
    
    log_success "Logrotate configured"
}

# Run
main "$@"