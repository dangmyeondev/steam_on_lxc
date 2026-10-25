#!/usr/bin/env bash
# ==============================================================================
# Linux Gaming Stream in Proxmox LXC — Step-by-Step Installer
# Supports: Debian 12 (Bookworm) / Debian 13 (Trixie) in Proxmox LXC
# Target: Headless Xorg + KDE Plasma + NVIDIA GPU + Sunshine + Steam/Moonlight
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME=$(eval echo "~$TARGET_USER")
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err() { echo -e "${RED}[ERROR]${NC} $*"; }

banner() {
    cat << "EOF"
  _      _                 _____ _                                  
 | |    (_)               / ____| |                                 
 | |     _ _ __  _   ___ _| (___ | |_ _ __ ___  __ _ _ __ ___       
 | |    | | '_ \| | | \ \ / \___ \| __| '__/ _ \/ _` | '_ ` _ \      
 | |____| | | | | |_| |>  < ____) | |_| | |  __/ (_| | | | | | |     
 |______|_|_| |_|\__,_/_/\_\_____/ \__|_|  \___|\__,_|_| |_| |_|     
                   in Proxmox LXC (Debian)                          
EOF
    echo -e "${BLUE}Target User:${NC} $TARGET_USER (${TARGET_HOME})"
    echo
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_err "This step requires root privileges. Please run with sudo: sudo ./install.sh <command>"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# STEP 0: Check Host Prerequisites & LXC Device Passthrough
# ------------------------------------------------------------------------------
step0_check_prereqs() {
    log_info "==> Step 0: Checking Host Device Sharing & LXC Environment..."
    local ok=1

    if ! grep -q "NVRM" /proc/driver/nvidia/version 2>/dev/null; then
        log_err "/proc/driver/nvidia/version not found!"
        log_err "NVIDIA kernel driver is NOT shared from the Proxmox host into this LXC container."
        ok=0
    else
        local host_driver
        host_driver=$(cat /proc/driver/nvidia/version | head -n1 | grep -oP 'NVRM version:.*?\b[0-9]+\.[0-9]+(\.[0-9]+)?\b' | awk '{print $NF}')
        log_success "Host NVIDIA kernel driver detected: ${host_driver:-Unknown}"
    fi

    # Check device nodes
    local required_nodes=(
        "/dev/nvidia0"
        "/dev/nvidiactl"
        "/dev/nvidia-modeset"
        "/dev/nvidia-uvm"
        "/dev/uinput"
    )

    for dev in "${required_nodes[@]}"; do
        if [ -e "$dev" ]; then
            log_success "Found device: $dev"
        else
            log_err "Missing device: $dev"
            ok=0
        fi
    done

    # Check DRI
    if [ -d "/dev/dri" ] && ls /dev/dri/renderD* >/dev/null 2>&1; then
        log_success "Found DRI render node: $(ls /dev/dri/renderD* | tr '\n' ' ')"
    else
        log_err "Missing /dev/dri/renderD* nodes!"
        ok=0
    fi

    if [ "$ok" -ne 1 ]; then
        echo
        log_err "Required host device nodes are missing in this LXC container."
        log_warn "Please add the following configuration to your container config on Proxmox host:"
        echo -e "${YELLOW}Host file: /etc/pve/lxc/<CTID>.conf${NC}"
        echo "--------------------------------------------------"
        cat "$SCRIPT_DIR/configs/pve/pve-lxc.conf.example"
        echo "--------------------------------------------------"
        log_warn "After adding the configuration on the Proxmox host, restart this LXC container and re-run."
        exit 1
    fi

    log_success "All host passthrough requirements verified successfully!"
}

# ------------------------------------------------------------------------------
# STEP 1: Install Base Packages & Dependencies
# ------------------------------------------------------------------------------
step1_base_packages() {
    check_root
    log_info "==> Step 1: Installing base packages, Xorg, KDE desktop & multimedia libraries..."

    dpkg --add-architecture i386
    apt-get update

    # Essential utilities
    apt-get install -y --no-install-recommends \
        curl wget gnupg lsb-release ca-certificates sudo pciutils kmod \
        dbus-user-session polkitd xdg-user-dirs xdotool zenity \
        mesa-utils vulkan-tools libvulkan1 libvulkan1:i386 \
        python3 python3-evdev python3-pip libxtst6 libx11-6

    # Xorg and minimal KDE Plasma desktop
    apt-get install -y --no-install-recommends \
        xserver-xorg-core xserver-xorg-input-all x11-xserver-utils x11-utils xterm \
        plasma-desktop plasma-workspace kwin-x11

    # Audio stack (PipeWire)
    apt-get install -y --no-install-recommends \
        pipewire wireplumber pipewire-pulse

    log_success "Base packages installed successfully."
}

# ------------------------------------------------------------------------------
# STEP 2: Install NVIDIA Userspace Driver (Matching Host Driver)
# ------------------------------------------------------------------------------
step2_nvidia_userspace() {
    check_root
    log_info "==> Step 2: Installing NVIDIA userspace libraries..."

    if [ ! -f /proc/driver/nvidia/version ]; then
        log_err "/proc/driver/nvidia/version missing! Cannot determine host driver version."
        exit 1
    fi

    local host_ver
    host_ver=$(grep -oP 'NVRM version:.*?\b\K[0-9]+(\.[0-9]+)+' /proc/driver/nvidia/version | head -n1)
    if [ -z "$host_ver" ]; then
        log_err "Failed to parse host driver version from /proc/driver/nvidia/version."
        exit 1
    fi
    log_info "Target NVIDIA Driver Version: $host_ver"

    # Check if existing installation matches
    if command -v nvidia-smi >/dev/null 2>&1; then
        local installed_ver
        installed_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || true)
        if [ "$installed_ver" = "$host_ver" ]; then
            log_success "NVIDIA userspace driver already matches host version ($installed_ver). Skipping reinstallation."
            return 0
        fi
    fi

    local installer="NVIDIA-Linux-x86_64-${host_ver}.run"
    local url="https://download.nvidia.com/XFree86/Linux-x86_64/${host_ver}/${installer}"
    local tmp_dir="/tmp/nvidia-install"
    mkdir -p "$tmp_dir"
    cd "$tmp_dir"

    log_info "Downloading $url ..."
    wget -c "$url" -O "$installer"

    log_info "Executing NVIDIA installer without kernel module..."
    sh "$installer" \
        --no-kernel-module \
        --no-dkms \
        --no-systemd \
        --no-backup \
        --no-nvidia-modprobe \
        --install-libglvnd \
        --install-compat32-libs \
        --no-nouveau-check \
        -s

    # Ensure Vulkan ICD
    mkdir -p /etc/vulkan/icd.d/
    if [ -f "$SCRIPT_DIR/configs/vulkan/nvidia_icd.json" ]; then
        cp "$SCRIPT_DIR/configs/vulkan/nvidia_icd.json" /etc/vulkan/icd.d/nvidia_icd.json
    else
        cat << 'EOF' > /etc/vulkan/icd.d/nvidia_icd.json
{
    "file_format_version" : "1.0.1",
    "ICD": {
        "library_path": "libGLX_nvidia.so.0",
        "api_version" : "1.4.329"
    }
}
EOF
    fi

    log_success "NVIDIA userspace driver installed successfully!"
}

# ------------------------------------------------------------------------------
# STEP 3: Configure Headless Xorg & Permissions
# ------------------------------------------------------------------------------
step3_configure_xorg() {
    check_root
    log_info "==> Step 3: Configuring Headless Xorg and permission rules..."

    # Detect PCI Bus ID of NVIDIA GPU
    local pci_raw
    pci_raw=$(lspci -nn | grep -iE 'vga|3d controller' | grep -i 'nvidia' | awk '{print $1}' | head -n1)
    local bus_id="PCI:10:0:0"
    if [ -n "$pci_raw" ]; then
        # Parse 0a:00.0 -> bus=0a (hex), slot=00 (hex), func=0
        local hex_bus hex_slot hex_func
        hex_bus=$(echo "$pci_raw" | cut -d: -f1)
        hex_slot=$(echo "$pci_raw" | cut -d: -f2 | cut -d. -f1)
        hex_func=$(echo "$pci_raw" | cut -d: -f2 | cut -d. -f2)
        local dec_bus dec_slot dec_func
        dec_bus=$((16#$hex_bus))
        dec_slot=$((16#$hex_slot))
        dec_func=$((16#$hex_func))
        bus_id="PCI:${dec_bus}:${dec_slot}:${dec_func}"
        log_info "Auto-detected GPU Bus ID: $pci_raw -> $bus_id"
    fi

    mkdir -p /etc/X11/xorg.conf.d /etc/udev/rules.d /etc/sudoers.d

    # Install Xorg configuration
    sed "s/BusID \"PCI:[0-9:]*\"/BusID \"$bus_id\"/g" \
        "$SCRIPT_DIR/configs/xorg/20-nvidia-headless.conf" > /etc/X11/xorg.conf.d/20-nvidia-headless.conf

    # Install udev rules
    cp "$SCRIPT_DIR/configs/udev/99-gaming.rules" /etc/udev/rules.d/99-gaming.rules

    # Install gaming-x.service
    cp "$SCRIPT_DIR/configs/systemd/system/gaming-x.service" /etc/systemd/system/gaming-x.service
    systemctl daemon-reload
    systemctl enable gaming-x.service

    # Install sudoers rule
    cp "$SCRIPT_DIR/configs/sudoers.d/99-gaming-x" /etc/sudoers.d/99-gaming-x
    chmod 440 /etc/sudoers.d/99-gaming-x

    # Add user to required groups
    for grp in video input render sudo; do
        if getent group "$grp" >/dev/null 2>&1; then
            usermod -aG "$grp" "$TARGET_USER" || true
        fi
    done

    # Ensure device permissions now
    chmod 666 /dev/dri/renderD* /dev/uinput /dev/uhid 2>/dev/null || true

    log_success "Headless Xorg and system permissions configured successfully!"
}

# ------------------------------------------------------------------------------
# STEP 4: Install Sunshine Streaming Server
# ------------------------------------------------------------------------------
step4_install_sunshine() {
    check_root
    log_info "==> Step 4: Installing Sunshine streaming server..."

    if ! command -v sunshine >/dev/null 2>&1; then
        curl -1sLf 'https://dl.cloudsmith.io/public/lizardbyte/stable/setup.deb.sh' | bash
        apt-get update
        apt-get install -y sunshine
    else
        log_info "Sunshine is already installed ($(sunshine --version 2>/dev/null || true))."
    fi

    # Set capabilities if needed
    setcap cap_sys_admin+ep /usr/bin/sunshine 2>/dev/null || true

    # Prepare user configuration
    local conf_dir="$TARGET_HOME/.config/sunshine"
    mkdir -p "$conf_dir"
    if [ ! -f "$conf_dir/sunshine.conf" ]; then
        cp "$SCRIPT_DIR/configs/sunshine/sunshine.conf.example" "$conf_dir/sunshine.conf"
    fi
    if [ ! -f "$conf_dir/apps.json" ]; then
        cp "$SCRIPT_DIR/configs/sunshine/apps.json.example" "$conf_dir/apps.json"
    fi
    chown -R "$TARGET_USER:$TARGET_USER" "$conf_dir"

    log_success "Sunshine installed and configured."
}

# ------------------------------------------------------------------------------
# STEP 5: Install Helper Scripts & Gamescope/Steam Wrapper
# ------------------------------------------------------------------------------
step5_install_scripts() {
    log_info "==> Step 5: Installing helper scripts into $TARGET_HOME/.local/bin..."

    mkdir -p "$TARGET_HOME/.local/bin"
    cp -r "$SCRIPT_DIR/bin/"* "$TARGET_HOME/.local/bin/"
    chmod +x "$TARGET_HOME/.local/bin/"*
    chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.local/bin"

    # Add ~/.local/bin to PATH in .bashrc and .profile if missing
    local bashrc="$TARGET_HOME/.bashrc"
    if [ -f "$bashrc" ] && ! grep -q 'PATH=.*\.local/bin' "$bashrc"; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$bashrc"
    fi
    local profile="$TARGET_HOME/.profile"
    if [ -f "$profile" ] && ! grep -q 'PATH=.*\.local/bin' "$profile"; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$profile"
    fi

    log_success "Helper scripts installed successfully."
}

# ------------------------------------------------------------------------------
# STEP 6: Configure Systemd User Services & Linger
# ------------------------------------------------------------------------------
step6_setup_user_services() {
    check_root
    log_info "==> Step 6: Setting up systemd user services for $TARGET_USER..."

    # Enable linger so user services start automatically at boot
    loginctl enable-linger "$TARGET_USER"

    local user_unit_dir="$TARGET_HOME/.config/systemd/user"
    mkdir -p "$user_unit_dir"
    cp "$SCRIPT_DIR/configs/systemd/user/"* "$user_unit_dir/"
    chown -R "$TARGET_USER:$TARGET_USER" "$user_unit_dir"

    # Reload and enable user services as target user
    su - "$TARGET_USER" -c "
        export XDG_RUNTIME_DIR=/run/user/\$(id -u)
        systemctl --user daemon-reload
        systemctl --user enable plasma-x11.service sunshine.service input-bridge.service sunshine-steam-sync.timer sunshine-display-idle.timer
    "

    log_success "User services enabled successfully!"
}

# ------------------------------------------------------------------------------
# STEP 7: Health Check & Diagnostics
# ------------------------------------------------------------------------------
step7_verify() {
    log_info "==> Step 7: Performing installation check..."
    if [ -x "$TARGET_HOME/.local/bin/stream-doctor" ]; then
        "$TARGET_HOME/.local/bin/stream-doctor" check || true
    else
        log_warn "stream-doctor script not found. Verification skipped."
    fi
    echo
    log_success "Setup complete! Connect your Moonlight client to: https://<CONTAINER-IP>:47990"
}

# ------------------------------------------------------------------------------
# Main Menu
# ------------------------------------------------------------------------------
usage() {
    echo "Usage: $0 [all|step0|step1|step2|step3|step4|step5|step6|check]"
    echo
    echo "Commands:"
    echo "  all      Run complete end-to-end installation (Step 0 to 7)"
    echo "  step0    Check host passthrough and container device requirements"
    echo "  step1    Install base Debian packages (Xorg, KDE, PipeWire, evdev)"
    echo "  step2    Install NVIDIA userspace driver matching host version"
    echo "  step3    Configure Headless Xorg, udev rules, and permissions"
    echo "  step4    Install Sunshine streaming server & config files"
    echo "  step5    Install helper scripts into ~/.local/bin"
    echo "  step6    Configure and enable systemd user services & loginctl linger"
    echo "  check    Run stream-doctor health check"
    echo
}

CMD="${1:-all}"

case "$CMD" in
    all)
        banner
        step0_check_prereqs
        step1_base_packages
        step2_nvidia_userspace
        step3_configure_xorg
        step4_install_sunshine
        step5_install_scripts
        step6_setup_user_services
        step7_verify
        ;;
    step0) step0_check_prereqs ;;
    step1) step1_base_packages ;;
    step2) step2_nvidia_userspace ;;
    step3) step3_configure_xorg ;;
    step4) step4_install_sunshine ;;
    step5) step5_install_scripts ;;
    step6) step6_setup_user_services ;;
    check) step7_verify ;;
    -h|--help|help) usage ;;
    *)
        log_err "Unknown command: $CMD"
        usage
        exit 1
        ;;
esac
