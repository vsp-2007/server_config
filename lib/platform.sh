#!/bin/bash
# Platform Detection Library - Pi Server Setup v2
# Provides unified platform detection for Raspberry Pi and generic Debian/Ubuntu

set -euo pipefail

# Platform detection results (global variables)
PLATFORM=""
IS_PI=false
IS_LAPTOP=false
IS_VM=false
ARCH=""
DISTRO=""
DISTRO_VERSION=""
DISTRO_CODENAME=""

# State tracking for idempotency (backported from v3)
STATE_DIR="/var/lib/pi-server-setup/state"
mkdir -p "${STATE_DIR}"

is_configured() {
    [[ -f "${STATE_DIR}/network.state" ]] && grep -q "^${1}=true$" "${STATE_DIR}/network.state" 2>/dev/null
}

mark_configured() {
    local key="vpn_${1}_configured"
    sed -i "/^${key}=/d" "${STATE_DIR}/network.state" 2>/dev/null || true
    echo "${key}=true" >> "${STATE_DIR}/network.state"
}

is_static_ip_configured() {
    [[ -f "${STATE_DIR}/network.state" ]] && grep -q "^static_ip_configured=true$" "${STATE_DIR}/network.state" 2>/dev/null
}

mark_static_ip_configured() {
    sed -i "/^static_ip_configured=/d" "${STATE_DIR}/network.state" 2>/dev/null || true
    echo "static_ip_configured=true" >> "${STATE_DIR}/network.state"
}

# Detect platform and set global variables
detect_platform() {
    # Architecture
    ARCH=$(uname -m)
    case "${ARCH}" in
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armhf)  ARCH="armv7" ;;
        x86_64|amd64)  ARCH="amd64" ;;
        *)             ARCH="unknown" ;;
    esac

    # Distribution
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        DISTRO="${ID}"
        DISTRO_VERSION="${VERSION_ID}"
        DISTRO_CODENAME="${VERSION_CODENAME:-}"
    else
        DISTRO="unknown"
        DISTRO_VERSION="unknown"
        DISTRO_CODENAME="unknown"
    fi

    # Platform detection
    # Check for Raspberry Pi
    if [[ -f /proc/device-tree/model ]] && grep -qi "raspberry pi" /proc/device-tree/model 2>/dev/null; then
        PLATFORM="raspberry_pi"
        IS_PI=true
    elif [[ -f /sys/class/dmi/id/chassis_type ]]; then
        local chassis_type
        chassis_type=$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo "0")
        case "${chassis_type}" in
            8|9|10|11|12|14) IS_LAPTOP=true ;;
        esac
        PLATFORM="laptop"
    elif [[ -f /proc/cpuinfo ]] && grep -qi "hypervisor\|vmware\|virtualbox\|kvm\|qemu" /proc/cpuinfo 2>/dev/null; then
        PLATFORM="vm"
        IS_VM=true
    else
        PLATFORM="generic"
    fi

    log_info "Platform: ${PLATFORM} (${ARCH}) - ${DISTRO} ${DISTRO_VERSION} (${DISTRO_CODENAME})"
    export PLATFORM IS_PI IS_LAPTOP IS_VM ARCH DISTRO DISTRO_VERSION DISTRO_CODENAME
}

# Get platform-specific package names
get_packages_for_platform() {
    local -n packages_ref=$1
    local base_packages=("${!packages_ref}")
    local adjusted_packages=()

    for pkg in "${base_packages[@]}"; do
        case "${PLATFORM}" in
            raspberry_pi)
                # Pi-specific packages
                case "${pkg}" in
                    linux-firmware) adjusted_packages+=("raspberrypi-kernel raspberrypi-firmware") ;;
                    *) adjusted_packages+=("${pkg}") ;;
                esac
                ;;
            laptop)
                # Laptop-specific: power management
                adjusted_packages+=("${pkg}")
                if [[ "${pkg}" == "tlp" ]]; then
                    adjusted_packages+=("thermald" "powertop")
                fi
                ;;
            vm)
                # VM-specific: guest agents
                adjusted_packages+=("${pkg}")
                if [[ "${pkg}" == "qemu-guest-agent" ]]; then
                    adjusted_packages+=("spice-vdagent")
                fi
                ;;
            *)
                adjusted_packages+=("${pkg}")
                ;;
        esac
    done

    echo "${adjusted_packages[@]}"
}

# Services to disable on specific platforms
get_services_to_disable() {
    local -n disabled_ref=$1
    local base_disabled=("${!disabled_ref}")
    local adjusted_disabled=()

    case "${PLATFORM}" in
        raspberry_pi)
            # Disable desktop services on Pi
            adjusted_disabled+=("bluetooth" "cups" "avahi-daemon" "ModemManager")
            ;;
        laptop)
            # Keep laptop services
            ;;
        vm)
            # Disable hardware services on VM
            adjusted_disabled+=("bluetooth" "cups" "avahi-daemon" "ModemManager" "thermald")
            ;;
        *)
            adjusted_disabled+=("bluetooth" "cups" "avahi-daemon" "ModemManager")
            ;;
    esac

    echo "${adjusted_disabled[@]}"
}

# Get platform-specific user groups
get_extra_user_groups() {
    local base_groups=("$@")
    local adjusted_groups=("${base_groups[@]}")

    case "${PLATFORM}" in
        raspberry_pi)
            adjusted_groups+=("gpio" "i2c" "spi" "video" "render" "docker")
            ;;
        laptop)
            adjusted_groups+=("docker" "wireshark" "kvm" "libvirt")
            ;;
        vm)
            adjusted_groups+=("docker" "kvm" "libvirt")
            ;;
    esac

    # Return comma-separated for useradd -G
    local IFS=","
    echo "${adjusted_groups[*]}"
}

# Apply platform-specific optimizations
apply_platform_optimizations() {
    log_info "Applying ${PLATFORM} optimizations..."

    # Swap optimization for Pi
    if [[ "${IS_PI}" == "true" ]]; then
        # Swap optimization for Pi - only if dphys-swapfile exists
        if [[ -f /etc/dphys-swapfile ]]; then
            local current_swap
            current_swap=$(grep "^CONF_SWAPSIZE=" /etc/dphys-swapfile | cut -d= -f2)
            if [[ -z "${current_swap}" ]] || [[ "${current_swap}" -lt 2048 ]]; then
                log_info "Increasing swap to 2GB..."
                sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
                systemctl restart dphys-swapfile
            fi
        fi

        # GPU memory split (headless server) - only if /boot/config.txt exists
        if [[ -f /boot/config.txt ]] && ! grep -q "^gpu_mem=" /boot/config.txt; then
            echo "gpu_mem=16" >> /boot/config.txt
            log_info "Set GPU memory to 16MB (headless)"
        fi

        # Disable HDMI if headless - only if /boot/config.txt exists
        if [[ -f /boot/config.txt ]] && ! grep -q "^hdmi_blanking=" /boot/config.txt; then
            echo "hdmi_blanking=1" >> /boot/config.txt
        fi
    fi

    # Laptop optimizations
    if [[ "${IS_LAPTOP}" == "true" ]]; then
        # TLP already installed via get_packages_for_platform
        # Configure lid switch
        local logind_conf="/etc/systemd/logind.conf"
        if [[ -f "${logind_conf}" ]] && ! grep -q "^HandleLidSwitch=" "${logind_conf}"; then
            echo "HandleLidSwitch=ignore" >> "${logind_conf}"
            log_info "Configured lid switch to ignore"
        fi

        # Battery charge threshold (if supported)
        if [[ -f /sys/class/power_supply/BAT0/charge_control_end_threshold ]]; then
            echo 80 > /sys/class/power_supply/BAT0/charge_control_end_threshold 2>/dev/null || true
        fi
    fi

    # VM optimizations
    if [[ "${IS_VM}" == "true" ]]; then
        # Disable hardware-specific services
        systemctl disable bluetooth cups avahi-daemon ModemManager 2>/dev/null || true
    fi
}

# Platform-specific VNC setup
configure_vnc() {
    case "${PLATFORM}" in
        raspberry_pi)
            if command -v vncserver >/dev/null 2>&1; then
                log_info "Configuring RealVNC..."
                # RealVNC is pre-installed on Raspberry Pi OS
                systemctl enable vncserver-x11-serviced 2>/dev/null || true
                systemctl start vncserver-x11-serviced 2>/dev/null || true
                log_info "RealVNC configured (port 5900)"
            fi
            ;;
        laptop)
            log_info "VNC not configured on laptop (use system settings)"
            ;;
        *)
            log_info "VNC not configured for ${PLATFORM}"
            ;;
    esac
}

# Platform-specific temperature reading
get_temperature() {
    case "${PLATFORM}" in
        raspberry_pi)
            if command -v vcgencmd >/dev/null 2>&1; then
                vcgencmd measure_temp | sed 's/temp=//'
            else
                echo "N/A"
            fi
            ;;
        laptop|generic|vm)
            # Try to read from thermal zones
            local max_temp=0
            for zone in /sys/class/thermal/thermal_zone*/temp 2>/dev/null; do
                if [[ -f "${zone}" ]]; then
                    local temp
                    temp=$(cat "${zone}" 2>/dev/null || echo 0)
                    # Convert millidegrees to degrees
                    temp=$((temp / 1000))
                    if [[ ${temp} -gt ${max_temp} ]]; then
                        max_temp=${temp}
                    fi
                fi
            done
            if [[ ${max_temp} -gt 0 ]]; then
                echo "${max_temp}°C"
            else
                echo "N/A"
            fi
            ;;
    esac
}

# Platform-specific swap configuration
configure_swap() {
    case "${PLATFORM}" in
        raspberry_pi)
            # Use dphys-swapfile
            if [[ -f /etc/dphys-swapfile ]]; then
                local current_swap
                current_swap=$(grep "^CONF_SWAPSIZE=" /etc/dphys-swapfile | cut -d= -f2)
                if [[ -z "${current_swap}" ]] || [[ "${current_swap}" -lt 2048 ]]; then
                    log_info "Increasing swap to 2GB..."
                    sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
                    systemctl restart dphys-swapfile
                fi
            fi
            ;;
        laptop|generic|vm)
            # Use swap file
            if [[ ! -f /swapfile ]] && ! swapon --show | grep -q "^/swapfile"; then
                local swap_size_gb=2
                # For systems with lots of RAM, use smaller swap
                local total_mem_gb
                total_mem_gb=$(free -g | awk '/^Mem:/{print $2}')
                if [[ ${total_mem_gb} -ge 16 ]]; then
                    swap_size_gb=1
                elif [[ ${total_mem_gb} -ge 8 ]]; then
                    swap_size_gb=2
                fi

                log_info "Creating ${swap_size_gb}GB swap file..."
                fallocate -l "${swap_size_gb}G" /swapfile 2>/dev/null || {
                    # fallocate might fail on some filesystems, use dd as fallback
                    dd if=/dev/zero of=/swapfile bs=1G count="${swap_size_gb}" 2>/dev/null
                }
                chmod 600 /swapfile
                mkswap /swapfile
                swapon /swapfile
                echo "/swapfile none swap sw 0 0" >> /etc/fstab
                log_success "Swap file created (${swap_size_gb}GB)"
            fi
            ;;
    esac
}

# Initialize platform detection on source
detect_platform

# Export functions for use in other scripts
export -f detect_platform
export -f get_packages_for_platform
export -f get_services_to_disable
export -f apply_platform_optimizations
export -f configure_vnc
export -f get_temperature
export -f configure_swap
export -f is_configured
export -f mark_configured
export -f is_static_ip_configured
export -f mark_static_ip_configured