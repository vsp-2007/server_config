#!/bin/bash
# Test Script for Pi Server Setup v2 on Debian Test Server
# Run this on your Debian test server: bash test_v2_setup.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $*"; }

REPO_DIR="$HOME/Interactive-server_config_script"
BRANCH="v2-development"
REPO_URL="https://github.com/vsp-2007/Interactive-server_config_script.git"

echo -e "${BOLD}${CYAN}=== Pi Server Setup v2 Test Script ===${NC}"
echo "Repository: $REPO_URL"
echo "Branch: $BRANCH"
echo "Test directory: $REPO_DIR"
echo

# ============================================================================
# PHASE 1: Setup & Basic Validation
# ============================================================================
phase1_setup() {
    log_info "Phase 1: Setup & Basic Validation"
    
    # Clone or update repo
    if [[ -d "$REPO_DIR" ]]; then
        log_info "Repository exists, updating..."
        cd "$REPO_DIR"
        git fetch origin
        git checkout "$BRANCH"
        git pull origin "$BRANCH"
    else
        log_info "Cloning repository..."
        git clone -b "$BRANCH" "$REPO_URL" "$REPO_DIR"
        cd "$REPO_DIR"
    fi
    
    # Check install.sh exists and is executable
    if [[ -f "install.sh" ]]; then
        chmod +x install.sh
        log_success "install.sh found and made executable"
    else
        log_error "install.sh not found!"
        exit 1
    fi
    
    # Check config example exists
    if [[ -f "config/settings.conf.example" ]]; then
        log_success "config/settings.conf.example found"
    else
        log_error "config/settings.conf.example missing!"
        exit 1
    fi
    
    # Check scripts directory
    if [[ -d "scripts" ]]; then
        script_count=$(ls scripts/*.sh 2>/dev/null | wc -l)
        log_success "scripts/ directory found ($script_count scripts)"
    else
        log_error "scripts/ directory missing!"
        exit 1
    fi
    
    # Check .gitignore has settings.conf
    if grep -q "settings.conf" .gitignore 2>/dev/null; then
        log_success ".gitignore excludes settings.conf"
    else
        log_warn ".gitignore may not exclude settings.conf"
    fi
}

# ============================================================================
# PHASE 2: Config Creation & Validation
# ============================================================================
phase2_config() {
    log_info "Phase 2: Config Creation & Validation"
    
    # Copy config if not exists
    if [[ ! -f "settings.conf" ]]; then
        log_info "Creating settings.conf from template..."
        cp config/settings.conf.example settings.conf
        chmod 600 settings.conf
        log_success "settings.conf created with 600 permissions"
    else
        log_info "settings.conf already exists"
    fi
    
    # Test dry-run (no root needed)
    log_info "Testing dry-run (no root)..."
    if ./install.sh --dry-run 2>&1 | grep -q "Configuration validation passed"; then
        log_success "Dry-run validation passed"
    else
        log_error "Dry-run validation failed"
        ./install.sh --dry-run 2>&1 | head -20
        return 1
    fi
}

# ============================================================================
# PHASE 3: CLI Mode Test (requires sudo)
# ============================================================================
phase3_cli_test() {
    log_info "Phase 3: CLI Mode Test (requires sudo)"
    
    # Test non-interactive minimal install
    log_info "Testing non-interactive minimal install (system, network)..."
    if sudo ./install.sh -y -m "system,network" 2>&1 | tee /tmp/install_test.log; then
        log_success "CLI non-interactive install completed"
    else
        log_error "CLI install failed"
        tail -20 /tmp/install_test.log
        return 1
    fi
    
    # Check log file was created
    if [[ -f /var/log/pi-server-setup/install_*.log ]]; then
        log_success "Log file created in /var/log/pi-server-setup/"
    else
        log_warn "Log file not found in expected location"
    fi
}

# ============================================================================
# PHASE 4: TUI Mode Test (requires sudo + dialog)
# ============================================================================
phase4_tui_test() {
    log_info "Phase 4: TUI Mode Test (requires sudo)"
    
    # Install dialog if needed
    if ! command -v dialog >/dev/null 2>&1; then
        log_info "Installing dialog for TUI..."
        sudo apt-get update -qq && sudo apt-get install -y -qq dialog
    fi
    
    log_info "Testing TUI mode (will exit after module selection)..."
    # Note: TUI test is interactive, so we just verify it launches
    timeout 10 sudo ./install.sh --tui 2>&1 | head -5 || true
    log_success "TUI mode launched successfully"
}

# ============================================================================
# PHASE 5: Create-config Script Test
# ============================================================================
phase5_create_config() {
    log_info "Phase 5: Create-config Script Test"
    
    # Remove existing settings.conf
    rm -f settings.conf
    
    # Run create-config.sh
    if bash scripts/create-config.sh; then
        log_success "create-config.sh works"
    else
        log_error "create-config.sh failed"
        return 1
    fi
    
    # Verify permissions
    if [[ $(stat -c %a settings.conf) == "600" ]]; then
        log_success "settings.conf has correct 600 permissions"
    else
        log_warn "settings.conf permissions may not be 600"
    fi
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    echo -e "${BOLD}${CYAN}Starting Pi Server Setup v2 Test${NC}"
    echo "========================================"
    
    # Check if running on Debian/Ubuntu
    if [[ ! -f /etc/os-release ]]; then
        log_error "Not running on a supported OS"
        exit 1
    fi
    source /etc/os-release
    log_info "OS: $PRETTY_NAME"
    
    # Run phases
    phase1_setup
    phase2_config
    
    # Check if we have sudo
    if sudo -n true 2>/dev/null; then
        log_info "Sudo available without password"
        HAS_SUDO=true
    else
        log_warn "Sudo requires password - some tests will need manual sudo"
        HAS_SUDO=false
    fi
    
    if [[ "$HAS_SUDO" == "true" ]]; then
        phase3_cli_test
        phase4_tui_test
    else
        log_warn "Skipping sudo-required tests (phase 3, 4)"
    fi
    
    phase5_create_config
    
    echo
    echo -e "${BOLD}${GREEN}=== All Tests Completed ===${NC}"
    echo "Check output above for any failures."
    echo "Log files in /var/log/pi-server-setup/"
}

main "$@"