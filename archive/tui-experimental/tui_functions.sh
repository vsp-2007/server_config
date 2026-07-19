#!/bin/bash
# TUI Functions for Pi Server Setup v2 - ARCHIVED
# This code was removed from main install.sh to simplify and stabilize
# Kept here for reference only

# ============================================================================
# TUI FUNCTIONS (whiptail/dialog) - ARCHIVED
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
    # CRITICAL: Setup directories FIRST for logging
    setup_directories
    
    log_info "Starting TUI mode..."
    
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
    log_info "Opening module selection dialog..."
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
    local ret=$?
    log_info "Module selection dialog returned: ${ret}"
    [[ $ret -ne 0 ]] && die "Module selection cancelled"
    [[ -z "$selected_modules" ]] && die "No modules selected"
    IFS=' ' read -ra MODULES_TO_INSTALL <<< "$selected_modules"
    log_info "Selected modules: ${MODULES_TO_INSTALL[*]}"
    
    # Config form
    log_info "Opening configuration form..."
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
    local ret=$?
    log_info "Config form returned: ${ret}"
    [[ $ret -ne 0 ]] && die "Configuration cancelled"
    IFS=$'\n' read -r PI_USER SSH_PORT PI_PASSWORD TELEGRAM_TOKEN TAILSCALE_KEY STATIC_IP <<< "$config_output"
    log_info "Config values: PI_USER=${PI_USER}, SSH_PORT=${SSH_PORT}, STATIC_IP=${STATIC_IP}"
    
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
    log_info "Showing confirmation dialog..."
    $tool --title "Confirm Installation" --yesno "Ready to install the following modules:\n\n$module_list\n\nProceed with installation?" 15 70 || die "Installation cancelled"
    
    # Resolve dependencies
    log_info "Resolving dependencies..."
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
        log_info "Installing module: ${module} (${current}/${#MODULES_TO_INSTALL[@]})"
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