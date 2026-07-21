#!/bin/bash
# Ollama Local LLM Module - Pi Server Setup v3
# Smart hardware detection, auto-model selection, idempotent installation

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true

# Configuration (from settings.conf)
OLLAMA_ENABLED="${OLLAMA_ENABLED:-true}"
OLLAMA_MODELS="${OLLAMA_MODELS:-llama3.2:3b,phi3:mini}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_HOST="${OLLAMA_HOST:-0.0.0.0}"
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-5m}"
OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"
OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}"

# Hardware detection results (global)
HAS_GPU=false
GPU_TYPE=""           # nvidia, amd, intel, apple, none
GPU_VRAM_MB=0
SYSTEM_RAM_GB=0
CPU_CORES=0
ARCH=""
RECOMMENDED_MODELS=()
OLLAMA_ARCH=""

main() {
    log_info "Starting Ollama setup..."
    
    # Check if disabled
    if [[ "${OLLAMA_ENABLED}" != "true" ]]; then
        log_info "Ollama is disabled in config (OLLAMA_ENABLED=${OLLAMA_ENABLED})"
        return 0
    fi
    
    # 1. Detect hardware capabilities
    detect_hardware
    
    # 2. Determine if we should install
    if ! should_install_ollama; then
        log_warn "Hardware not suitable for Ollama, skipping installation"
        log_info "Minimum recommended: 4GB RAM, 2+ CPU cores"
        return 0
    fi
    
    # 3. Auto-select models based on hardware
    select_models_for_hardware
    
    # 4. Install/Update Ollama (idempotent)
    install_ollama
    
    # 5. Configure Ollama
    configure_ollama
    
    # 6. Install systemd service
    install_systemd_service
    
    # 7. Pull recommended models
    pull_models
    
    # 8. Configure firewall
    configure_firewall
    
    # 9. Create Nginx reverse proxy config (if nginx module installed)
    create_nginx_config
    
    # 10. Print summary
    print_summary
    
    log_success "Ollama setup completed!"
}

# ============================================================================
# HARDWARE DETECTION
# ============================================================================

detect_hardware() {
    log_info "Detecting hardware capabilities..."
    
    # Architecture
    ARCH=$(uname -m)
    case "${ARCH}" in
        aarch64|arm64) OLLAMA_ARCH="arm64" ;;
        armv7l|armhf)  OLLAMA_ARCH="armv7" ;;
        x86_64|amd64)  OLLAMA_ARCH="amd64" ;;
        *)             OLLAMA_ARCH="unknown" ;;
    esac
    log_debug "Architecture: ${ARCH} -> ${OLLAMA_ARCH}"
    
    # CPU cores
    CPU_CORES=$(nproc)
    log_debug "CPU cores: ${CPU_CORES}"
    
    # System RAM
    SYSTEM_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    log_debug "System RAM: ${SYSTEM_RAM_GB}GB"
    
    # GPU Detection
    detect_gpu
    
    log_info "Hardware summary: ${CPU_CORES} cores, ${SYSTEM_RAM_GB}GB RAM, GPU: ${GPU_TYPE:-none} (${GPU_VRAM_MB}MB VRAM)"
}

detect_gpu() {
    GPU_TYPE="none"
    GPU_VRAM_MB=0
    HAS_GPU=false
    
    # NVIDIA GPU
    if command -v nvidia-smi >/dev/null 2>&1; then
        GPU_TYPE="nvidia"
        GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
        HAS_GPU=true
        log_debug "NVIDIA GPU detected: ${GPU_VRAM_MB}MB VRAM"
        return
    fi
    
    # AMD GPU (ROCm)
    if [[ -d /dev/dri ]] && ls /dev/dri/renderD* >/dev/null 2>&1; then
        if command -v rocm-smi >/dev/null 2>&1; then
            GPU_TYPE="amd"
            GPU_VRAM_MB=$(rocm-smi --showmeminfo vram 2>/dev/null | grep -oP '(?<=VRAM: )\d+' | head -1 || echo 0)
            HAS_GPU=true
            log_debug "AMD GPU detected: ${GPU_VRAM_MB}MB VRAM"
            return
        fi
        # Generic AMD/Intel via mesa
        GPU_TYPE="mesa"
        GPU_VRAM_MB=0  # Shared memory
        HAS_GPU=true
        log_debug "Mesa/OpenCL GPU detected (shared memory)"
        return
    fi
    
    # Intel GPU (integrated)
    if lspci 2>/dev/null | grep -i "vga.*intel\|display.*intel" >/dev/null; then
        GPU_TYPE="intel"
        GPU_VRAM_MB=0  # Shared memory
        HAS_GPU=true
        log_debug "Intel integrated GPU detected (shared memory)"
        return
    fi
    
    # Apple Silicon
    if [[ "$(uname -s)" == "Darwin" ]] && [[ "${ARCH}" == "arm64" ]]; then
        GPU_TYPE="apple"
        # Unified memory - use system RAM as proxy
        GPU_VRAM_MB=$((SYSTEM_RAM_GB * 1024 / 2))  # Rough estimate
        HAS_GPU=true
        log_debug "Apple Silicon detected (unified memory)"
        return
    fi
    
    # Raspberry Pi GPU (VideoCore)
    if [[ -f /proc/device-tree/model ]] && grep -qi "raspberry pi" /proc/device-tree/model 2>/dev/null; then
        GPU_TYPE="videocore"
        GPU_VRAM_MB=0  # Shared memory
        HAS_GPU=true
        log_debug "Raspberry Pi VideoCore GPU detected (shared memory)"
        return
    fi
    
    log_debug "No dedicated GPU detected"
}

# ============================================================================
# INSTALL DECISION
# ============================================================================

should_install_ollama() {
    # Minimum requirements
    local min_ram_gb=4
    local min_cores=2
    
    # Check if already installed and running
    if systemctl is-active --quiet ollama 2>/dev/null; then
        log_info "Ollama service already running"
        return 0
    fi
    
    if command -v ollama >/dev/null 2>&1; then
        log_info "Ollama binary already installed"
        return 0
    fi
    
    # Check RAM
    if [[ ${SYSTEM_RAM_GB} -lt ${min_ram_gb} ]]; then
        log_warn "Insufficient RAM: ${SYSTEM_RAM_GB}GB < ${min_ram_GB}GB minimum"
        if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
            read -rp "Install anyway? (not recommended) [y/N] " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && return 1
        else
            return 1
        fi
    fi
    
    # Check CPU cores
    if [[ ${CPU_CORES} -lt ${min_cores} ]]; then
        log_warn "Low CPU cores: ${CPU_CORES} < ${min_cores}"
    fi
    
    # Check disk space (need ~5GB minimum)
    local available_gb
    available_gb=$(df -BG /var/lib | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ ${available_gb} -lt 5 ]]; then
        log_warn "Low disk space: ${available_gb}GB available (need 5GB+)"
    fi
    
    log_info "Hardware meets minimum requirements for Ollama"
    return 0
}

# ============================================================================
# MODEL SELECTION BASED ON HARDWARE
# ============================================================================

select_models_for_hardware() {
    log_info "Selecting optimal models for your hardware..."
    
    RECOMMENDED_MODELS=()
    
    # Parse user-configured models
    IFS=',' read -ra USER_MODELS <<< "${OLLAMA_MODELS}"
    USER_MODELS=("${USER_MODELS[@]// /}")  # trim spaces
    
    # If user explicitly set models, use those (but validate)
    if [[ ${#USER_MODELS[@]} -gt 0 && -n "${USER_MODELS[0]}" ]]; then
        log_info "Using user-configured models: ${USER_MODELS[*]}"
        RECOMMENDED_MODELS=("${USER_MODELS[@]}")
        return
    fi
    
    # Auto-select based on hardware
    log_info "Auto-selecting models based on hardware..."
    
    # High-end: GPU with 8GB+ VRAM or 16GB+ RAM
    if [[ "${HAS_GPU}" == "true" && ${GPU_VRAM_MB} -ge 8192 ]] || [[ ${SYSTEM_RAM_GB} -ge 16 ]]; then
        RECOMMENDED_MODELS=("llama3.1:8b" "phi3:medium" "mistral:7b")
        log_info "High-end hardware detected -> 7-8B parameter models"
    
    # Mid-range: GPU with 4-8GB VRAM or 8-16GB RAM
    elif [[ "${HAS_GPU}" == "true" && ${GPU_VRAM_MB} -ge 4096 ]] || [[ ${SYSTEM_RAM_GB} -ge 8 ]]; then
        RECOMMENDED_MODELS=("llama3.2:3b" "phi3:mini" "gemma2:2b" "qwen2.5:3b")
        log_info "Mid-range hardware detected -> 2-3B parameter models"
    
    # Low-end: 4-8GB RAM, no GPU or small GPU
    elif [[ ${SYSTEM_RAM_GB} -ge 4 ]]; then
        RECOMMENDED_MODELS=("phi3:mini" "gemma2:2b" "qwen2.5:1.5b" "tinyllama")
        log_info "Low-end hardware detected -> 1-2B parameter models"
    
    # Very low: < 4GB RAM (Raspberry Pi 4B 2GB, etc.)
    else
        RECOMMENDED_MODELS=("tinyllama" "qwen2.5:0.5b")
        log_warn "Very limited RAM (${SYSTEM_RAM_GB}GB) -> tiny models only"
    fi
    
    # Adjust for architecture
    case "${OLLAMA_ARCH}" in
        armv7)
            # 32-bit ARM - very limited model support
            RECOMMENDED_MODELS=("tinyllama" "qwen2.5:0.5b")
            log_warn "32-bit ARM: only tiny models supported"
            ;;
        arm64)
            # 64-bit ARM - good support for small models
            if [[ ${SYSTEM_RAM_GB} -lt 8 ]]; then
                RECOMMENDED_MODELS=("phi3:mini" "gemma2:2b" "qwen2.5:1.5b" "tinyllama")
            fi
            ;;
    esac
    
    log_success "Recommended models: ${RECOMMENDED_MODELS[*]}"
    
    # Allow user to override in interactive mode
    if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
        echo
        echo -e "${CYAN}Recommended models for your hardware:${NC} ${RECOMMENDED_MODELS[*]}"
        read -rp "Enter custom models (comma-separated) or press Enter to use recommended: " custom_models
        if [[ -n "${custom_models}" ]]; then
            IFS=',' read -ra RECOMMENDED_MODELS <<< "${custom_models}"
            RECOMMENDED_MODELS=("${RECOMMENDED_MODELS[@]// /}")
            log_info "Using custom models: ${RECOMMENDED_MODELS[*]}"
        fi
    fi
}

# ============================================================================
# OLLAMA INSTALLATION (IDEMPOTENT)
# ============================================================================

install_ollama() {
    log_info "Installing/updating Ollama..."
    
    # Ensure required tools are available
    for tool in curl systemctl; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_warn "Required tool '$tool' not found, attempting to install..."
            apt-get update -qq && apt-get install -y -qq "$tool" 2>/dev/null || true
        fi
    done
    
    # Check current version
    local current_version=""
    if command -v ollama >/dev/null 2>&1; then
        current_version=$(ollama --version 2>/dev/null | head -1 || echo "unknown")
        log_info "Current Ollama version: ${current_version}"
    fi
    
    # Install via official script (idempotent - safe to re-run)
    log_info "Running Ollama installer..."
    if curl -fsSL https://ollama.com/install.sh | sh; then
        log_success "Ollama installed/updated"
    else
        log_error "Ollama installation failed"
        return 1
    fi
    
    # Verify
    local new_version
    new_version=$(ollama --version 2>/dev/null | head -1 || echo "unknown")
    log_info "Ollama version: ${new_version}"
}

# ============================================================================
# CONFIGURATION
# ============================================================================

configure_ollama() {
    log_info "Configuring Ollama..."
    
    # Create config directory
    mkdir -p /etc/ollama
    
    # Environment file for systemd
    cat > /etc/ollama/env <<EOF
# Ollama Configuration
# Generated by InitOps v3

# Server binding
OLLAMA_HOST=${OLLAMA_HOST}:${OLLAMA_PORT}

# Model management
OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}
OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}
OLLAMA_MAX_LOADED_MODELS=${OLLAMA_MAX_LOADED_MODELS}

# Models directory
OLLAMA_MODELS=/var/lib/ollama/models

# GPU acceleration (auto-detect)
# OLLAMA_GPU_LAYERS=999     # Uncomment to force GPU layers
# OLLAMA_FLASH_ATTENTION=1  # Enable flash attention (if supported)

# Performance tuning
OLLAMA_NUMA=1               # Enable NUMA awareness
EOF
    
    # GPU-specific settings
    if [[ "${HAS_GPU}" == "true" ]]; then
        case "${GPU_TYPE}" in
            nvidia)
                echo "# NVIDIA GPU detected - enabling CUDA" >> /etc/ollama/env
                echo "OLLAMA_GPU_LAYERS=999" >> /etc/ollama/env
                ;;
            amd)
                echo "# AMD GPU detected - enabling ROCm" >> /etc/ollama/env
                echo "HIP_VISIBLE_DEVICES=0" >> /etc/ollama/env
                echo "OLLAMA_GPU_LAYERS=999" >> /etc/ollama/env
                ;;
            intel|mesa)
                echo "# Intel/Integrated GPU - using OpenCL" >> /etc/ollama/env
                echo "OLLAMA_GPU_LAYERS=999" >> /etc/ollama/env
                ;;
            apple)
                echo "# Apple Silicon - using Metal" >> /etc/ollama/env
                echo "OLLAMA_GPU_LAYERS=999" >> /etc/ollama/env
                ;;
            videocore)
                echo "# Raspberry Pi VideoCore - CPU only (no GPU acceleration in Ollama yet)" >> /etc/ollama/env
                ;;
        esac
    fi
    
    chmod 644 /etc/ollama/env
    chown -R ollama:ollama /etc/ollama 2>/dev/null || true
    
    log_success "Ollama configuration written to /etc/ollama/env"
}

# ============================================================================
# SYSTEMD SERVICE
# ============================================================================

install_systemd_service() {
    log_info "Installing Ollama systemd service..."
    
    # Create service user if not exists
    if ! id ollama >/dev/null 2>&1; then
        useradd -r -s /bin/false -m -d /var/lib/ollama -c "Ollama LLM Server" ollama
        log_info "Created ollama user"
    fi
    
    # Ensure directories exist
    mkdir -p /var/lib/ollama/models
    chown -R ollama:ollama /var/lib/ollama
    
    # Service file
    cat > /etc/systemd/system/ollama.service <<EOF
[Unit]
Description=Ollama Local LLM Server
Documentation=https://github.com/ollama/ollama
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=ollama
Group=ollama
EnvironmentFile=-/etc/ollama/env
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
ExecStart=/usr/local/bin/ollama serve

# Restart policy
Restart=always
RestartSec=10
TimeoutStartSec=300

# Security hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/ollama /etc/ollama /usr/share/ollama
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
# MemoryDenyWriteExecute=yes - disabled for JIT compilation
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

# Resource limits (adjust based on hardware)
LimitNOFILE=65536
LimitNPROC=512
MemoryMax=4G
CPUQuota=200%

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ollama

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable ollama
    systemctl restart ollama
    
    # Wait for service to be ready
    local max_wait=30
    local waited=0
    while [[ ${waited} -lt ${max_wait} ]]; do
        if systemctl is-active --quiet ollama; then
            # Also check API
            if curl -fsS "http://localhost:${OLLAMA_PORT}/api/version" >/dev/null 2>&1; then
                log_success "Ollama service is running and API is ready"
                return 0
            fi
        fi
        sleep 2
        ((waited += 2))
    done
    
    log_error "Ollama service failed to start properly"
    systemctl status ollama --no-pager
    return 1
}

# ============================================================================
# MODEL MANAGEMENT
# ============================================================================

pull_models() {
    log_info "Pulling recommended models..."
    
    # Wait for API to be ready
    local max_wait=60
    local waited=0
    while [[ ${waited} -lt ${max_wait} ]]; do
        if curl -fsS "http://localhost:${OLLAMA_PORT}/api/version" >/dev/null 2>&1; then
            break
        fi
        sleep 2
        ((waited += 2))
    done
    
    if [[ ${waited} -ge ${max_wait} ]]; then
        log_warn "Ollama API not ready after ${max_wait}s, skipping model pull"
        return 0
    fi
    
    # Pull each model
    for model in "${RECOMMENDED_MODELS[@]}"; do
        model=$(echo "${model}" | xargs)  # trim
        [[ -z "${model}" ]] && continue
        
        log_info "Pulling model: ${model}..."
        
        # Check if already exists
        if sudo -u ollama ollama list 2>/dev/null | grep -q "^${model} "; then
            log_info "Model ${model} already present, skipping"
            continue
        fi
        
        # Pull with timeout
        if timeout 300 sudo -u ollama ollama pull "${model}"; then
            log_success "Pulled model: ${model}"
        else
            log_warn "Failed to pull model: ${model} (timeout or network error)"
        fi
    done
    
    # List available models
    log_info "Available models:"
    sudo -u ollama ollama list
}

# ============================================================================
# FIREWALL
# ============================================================================

configure_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        log_info "Configuring UFW firewall for Ollama..."
        ufw allow "${OLLAMA_PORT}/tcp" comment "Ollama LLM API" || true
        log_success "Firewall rule added for port ${OLLAMA_PORT}"
    fi
}

# ============================================================================
# NGINX REVERSE PROXY
# ============================================================================

create_nginx_config() {
    if [[ ! -d /etc/nginx/sites-available ]]; then
        log_debug "Nginx not installed or not configured, skipping reverse proxy config"
        return 0
    fi
    
    log_info "Creating Nginx reverse proxy config for Ollama..."
    
    cat > /etc/nginx/sites-available/ollama <<EOF
# Ollama Reverse Proxy Config
# Generated by InitOps v3
# Access via: http://ollama.home (with nginx module)

# API endpoint
location /ollama/ {
    proxy_pass http://localhost:${OLLAMA_PORT}/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
    
    # Increase buffer sizes for LLM streaming
    proxy_buffering off;
    proxy_cache off;
}

# WebSocket support for streaming
location /ollama/api/chat {
    proxy_pass http://localhost:${OLLAMA_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
    proxy_buffering off;
}

location /ollama/api/generate {
    proxy_pass http://localhost:${OLLAMA_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
    proxy_buffering off;
}

# Model management endpoints
location /ollama/api/ {
    proxy_pass http://localhost:${OLLAMA_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
}
EOF
    
    # Enable site
    ln -sf /etc/nginx/sites-available/ollama /etc/nginx/sites-enabled/ollama 2>/dev/null || true
    
    # Test and reload nginx
    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || true
        log_success "Nginx config for Ollama applied"
    else
        log_warn "Nginx config test failed, skipping reload"
    fi
}

# ============================================================================
# SUMMARY
# ============================================================================

print_summary() {
    echo
    echo -e "${BOLD}${CYAN}=== Ollama Setup Summary ===${NC}"
    echo -e "  Service:       ${GREEN}ollama${NC} (systemd)"
    echo -e "  API Endpoint:  ${CYAN}http://localhost:${OLLAMA_PORT}${NC}"
    echo -e "  Models Dir:    ${CYAN}/var/lib/ollama/models${NC}"
    echo -e "  Config:        ${CYAN}/etc/ollama/env${NC}"
    echo -e "  User:          ${CYAN}ollama${NC}"
    echo
    echo -e "${BOLD}Installed Models:${NC}"
    sudo -u ollama ollama list 2>/dev/null | tail -n +2 | while read -r line; do
        echo "  - ${line}"
    done
    echo
    echo -e "${BOLD}Usage Examples:${NC}"
    echo -e "  ${CYAN}ollama run llama3.2:3b${NC}                    # Run a model interactively"
    echo -e "  ${CYAN}curl http://localhost:${OLLAMA_PORT}/api/generate -d '{\"model\":\"llama3.2:3b\",\"prompt\":\"Hello\"}'${NC}"
    echo -e "  ${CYAN}ollama pull mistral:7b${NC}                     # Pull additional models"
    echo -e "  ${CYAN}ollama rm llama3.2:3b${NC}                      # Remove a model"
    echo
    if [[ -f /etc/nginx/sites-enabled/ollama ]]; then
        echo -e "${BOLD}Reverse Proxy:${NC} Available at ${CYAN}http://ollama.home/ollama/${NC} (with nginx module)"
    fi
    echo
    echo -e "${BOLD}Management Commands:${NC}"
    echo -e "  ${CYAN}systemctl status ollama${NC}      # Check service status"
    echo -e "  ${CYAN}journalctl -u ollama -f${NC}      # View logs"
    echo -e "  ${CYAN}systemctl restart ollama${NC}     # Restart service"
    echo
}

# Run main
main "$@"