#!/bin/bash
# Test script for Pi Server Setup v2
# Validates syntax and basic functionality

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $*"; }

main() {
    local failed=0
    
    log_info "Starting Pi Server Setup v2 validation..."
    
    # Test 1: Bash syntax check
    log_info "Checking bash syntax..."
    for script in install.sh scripts/*.sh; do
        if bash -n "$script"; then
            log_success "Syntax OK: $script"
        else
            log_error "Syntax error: $script"
            ((failed++))
        fi
    done
    
    # Test 2: Shellcheck (if available)
    if command -v shellcheck >/dev/null 2>&1; then
        log_info "Running shellcheck..."
        shellcheck -x install.sh scripts/*.sh || log_warn "shellcheck found issues"
    else
        log_warn "shellcheck not installed, skipping"
    fi
    
    # Test 3: YAML validation
    log_info "Validating YAML configs..."
    for yaml in config/*.yml config/*.yaml; do
        if [[ -f "$yaml" ]]; then
            if python3 -c "import yaml; yaml.safe_load(open('$yaml'))" 2>/dev/null; then
                log_success "YAML OK: $yaml"
            else
                log_error "YAML invalid: $yaml"
                ((failed++))
            fi
        fi
    done
    
    # Test 4: JSON validation
    log_info "Validating JSON configs..."
    for json in config/*.json; do
        if [[ -f "$json" ]]; then
            if python3 -m json.tool "$json" >/dev/null 2>&1; then
                log_success "JSON OK: $json"
            else
                log_error "JSON invalid: $json"
                ((failed++))
            fi
        fi
    done
    
    # Test 5: systemd unit validation
    log_info "Validating systemd units..."
    for unit in systemd/*.service; do
        if [[ -f "$unit" ]]; then
            if systemd-analyze verify "$unit" 2>/dev/null; then
                log_success "systemd OK: $unit"
            else
                log_error "systemd invalid: $unit"
                ((failed++))
            fi
        fi
    done
    
    # Test 6: Config file example exists
    log_info "Checking configuration template..."
    if [[ -f "config/settings.conf.example" ]]; then
        log_success "Configuration template exists"
    else
        log_error "Missing config/settings.conf.example"
        ((failed++))
    fi
    
    # Test 7: Required directories exist
    log_info "Checking project structure..."
    for dir in scripts config systemd docs .github/workflows; do
        if [[ -d "$dir" ]]; then
            log_success "Directory exists: $dir"
        else
            log_error "Missing directory: $dir"
            ((failed++))
        fi
    done
    
    # Test 8: Check for hardcoded secrets
    log_info "Scanning for potential hardcoded secrets..."
    local secret_patterns=(
        "password\s*=\s*[\"'][^\"']*[\"']"
        "token\s*=\s*[\"'][^\"']*[\"']"
        "api[_-]?key\s*=\s*[\"'][^\"']*[\"']"
        "secret\s*=\s*[\"'][^\"']*[\"']"
    )
    
    local found_secrets=false
    for pattern in "${secret_patterns[@]}"; do
        if grep -riE "$pattern" scripts/ install.sh --include="*.sh" | grep -v "PASSWORD=" | grep -v "TOKEN=" | grep -v '\$\{' | grep -v "example" | grep -v "placeholder" | grep -v "your_" | grep -v "change_" >/dev/null; then
            log_warn "Potential hardcoded secret found (pattern: $pattern)"
            found_secrets=true
        fi
    done
    
    if [[ "$found_secrets" == "false" ]]; then
        log_success "No hardcoded secrets detected"
    fi
    
    # Test 9: Version consistency
    log_info "Checking version pinning..."
    if grep -q "PROMETHEUS_VERSION=" scripts/03-monitoring.sh; then
        log_success "Prometheus version pinned"
    else
        log_warn "Prometheus version not explicitly pinned"
    fi
    
    # Summary
    echo
    if [[ $failed -eq 0 ]]; then
        log_success "All validation checks passed!"
        return 0
    else
        log_error "$failed validation check(s) failed"
        return 1
    fi
}

main "$@"