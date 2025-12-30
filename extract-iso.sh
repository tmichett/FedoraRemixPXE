#!/bin/bash
#
# ISO Extraction Script for PXE Boot
# Extracts kernel, initrd, and squashfs from a Fedora/RHEL LiveCD ISO
# and generates PXE boot menu configurations
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
TFTP_DIR="${DATA_DIR}/tftpboot"
HTTP_DIR="${DATA_DIR}/http"
CONFIG_DIR="${SCRIPT_DIR}/config"
MOUNT_POINT="/tmp/pxe-iso-mount-$$"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log_info "Unmounting ISO..."
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi
    rmdir "$MOUNT_POINT" 2>/dev/null || true
}

trap cleanup EXIT

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

usage() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         Fedora Remix PXE - ISO Extraction Script             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Usage: $0 [OPTIONS] <path-to-iso>"
    echo ""
    echo "Arguments:"
    echo "  path-to-iso    Path to a Fedora/RHEL LiveCD ISO file"
    echo ""
    echo "Options:"
    echo "  -i, --ip IP        PXE server IP address"
    echo "  -p, --profile NAME Profile name (directory name for boot files)"
    echo "  -l, --label TEXT   Boot menu label"
    echo "  -y, --yes          Non-interactive mode (use defaults/provided values)"
    echo "  -h, --help         Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 /path/to/Fedora-Live.iso"
    echo "  $0 -i 192.168.100.1 -p fedora43 -l 'Fedora 43 Remix' -y /path/to/iso"
    echo ""
    echo "This script will:"
    echo "  1. Extract vmlinuz (kernel) and initrd.img to TFTP directory"
    echo "  2. Extract squashfs.img to HTTP directory for network boot"
    echo "  3. Ask for configuration details (IP, profile name, etc.)"
    echo "  4. Generate PXE boot menu configurations (BIOS and UEFI)"
    echo ""
}

# Get default PXE server IP from config or detect it
get_default_ip() {
    local config_file="${CONFIG_DIR}/pxe-server.env"
    
    if [[ -f "$config_file" ]]; then
        source "$config_file"
        if [[ -n "$PXE_SERVER_IP" ]]; then
            echo "$PXE_SERVER_IP"
            return
        fi
    fi
    
    # Try to detect from network
    local detected_ip=$(ip -4 addr show | grep -oP '(?<=inet\s)192\.168\.\d+\.\d+' | head -1)
    if [[ -n "$detected_ip" ]]; then
        echo "$detected_ip"
        return
    fi
    
    echo "192.168.0.1"
}

# Prompt for configuration
prompt_config() {
    local iso_basename=$(basename "$1" .iso)
    
    # Calculate defaults
    local default_ip=$(get_default_ip)
    local default_profile=$(echo "$iso_basename" | sed 's/[^a-zA-Z0-9]/_/g' | tr '[:upper:]' '[:lower:]')
    default_profile="${default_profile:0:20}"
    local default_label="Fedora Remix LiveCD"
    
    # Use command-line arguments if provided
    if [[ -n "$ARG_IP" ]]; then
        default_ip="$ARG_IP"
    fi
    if [[ -n "$ARG_PROFILE" ]]; then
        default_profile="$ARG_PROFILE"
    fi
    if [[ -n "$ARG_LABEL" ]]; then
        default_label="$ARG_LABEL"
    fi
    
    # Non-interactive mode
    if [[ "$ARG_YES" == true ]]; then
        PXE_IP="$default_ip"
        PROFILE_NAME=$(echo "$default_profile" | sed 's/[^a-zA-Z0-9_]/_/g')
        MENU_LABEL="$default_label"
        
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}  PXE Boot Configuration (Non-Interactive)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  PXE Server IP:  ${GREEN}$PXE_IP${NC}"
        echo -e "  Profile Name:   ${GREEN}$PROFILE_NAME${NC}"
        echo -e "  Menu Label:     ${GREEN}$MENU_LABEL${NC}"
        echo ""
        return
    fi
    
    # Interactive mode
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  PXE Boot Configuration${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Get PXE Server IP
    echo -e "${BLUE}PXE Server IP Address${NC}"
    echo -e "  This is the IP address of this PXE server that clients will connect to."
    echo -e "  It should be on the same network as your PXE clients."
    read -p "  Enter PXE Server IP [$default_ip]: " input_ip
    PXE_IP="${input_ip:-$default_ip}"
    echo ""
    
    # Get Profile Name
    echo -e "${BLUE}Profile Name${NC}"
    echo -e "  A short name for this boot image (used in file paths)."
    echo -e "  Use only letters, numbers, and underscores."
    read -p "  Enter profile name [$default_profile]: " input_profile
    PROFILE_NAME="${input_profile:-$default_profile}"
    # Sanitize profile name
    PROFILE_NAME=$(echo "$PROFILE_NAME" | sed 's/[^a-zA-Z0-9_]/_/g')
    echo ""
    
    # Get Menu Label
    echo -e "${BLUE}Boot Menu Label${NC}"
    echo -e "  The text shown in the PXE boot menu for this option."
    read -p "  Enter menu label [$default_label]: " input_label
    MENU_LABEL="${input_label:-$default_label}"
    echo ""
    
    # Confirm
    echo -e "${YELLOW}Configuration Summary:${NC}"
    echo -e "  PXE Server IP:  ${GREEN}$PXE_IP${NC}"
    echo -e "  Profile Name:   ${GREEN}$PROFILE_NAME${NC}"
    echo -e "  Menu Label:     ${GREEN}$MENU_LABEL${NC}"
    echo ""
    read -p "Proceed with these settings? [Y/n]: " confirm
    if [[ "${confirm,,}" == "n" ]]; then
        log_error "Aborted by user"
        exit 1
    fi
    echo ""
}

# Generate PXE boot configurations
generate_boot_configs() {
    local profile="$1"
    local ip="$2"
    local label="$3"
    
    log_info "Generating PXE boot menu configurations..."
    
    # Create directories
    mkdir -p "$TFTP_DIR/pxelinux.cfg"
    mkdir -p "$TFTP_DIR/efi64"
    
    # Generate BIOS boot config (pxelinux)
    log_info "Creating BIOS boot menu (pxelinux.cfg/default)..."
    cat > "$TFTP_DIR/pxelinux.cfg/default" << EOF
# PXELinux Configuration for BIOS Boot
# Generated by extract-iso.sh
# Profile: $profile

UI vesamenu.c32
TIMEOUT 600
MENU TITLE Travis's Fedora Remix PXE Boot Menu
MENU BACKGROUND splash.png
MENU WIDTH 80
MENU ROWS 14

LABEL local
    MENU LABEL Boot from ^local drive
    MENU DEFAULT
    LOCALBOOT 0xffff

LABEL $profile
    MENU LABEL ^$label
    KERNEL $profile/vmlinuz
    APPEND initrd=$profile/initrd.img root=live:http://$ip/$profile/squashfs.img ro rd.live.image rd.luks=0 rd.dm=0 rd.neednet=1 ip=dhcp
    IPAPPEND 2

LABEL ${profile}-debug
    MENU LABEL $label (^Debug Mode)
    KERNEL $profile/vmlinuz
    APPEND initrd=$profile/initrd.img root=live:http://$ip/$profile/squashfs.img ro rd.live.image rd.luks=0 rd.dm=0 rd.neednet=1 ip=dhcp rd.break
    IPAPPEND 2
EOF
    
    # Generate UEFI boot config (grub.cfg)
    # Uses GRUB network variables to pass static IP to kernel
    log_info "Creating UEFI boot menu (grub.cfg)..."
    cat > "$TFTP_DIR/efi64/grub.cfg" << EOF
# GRUB2 configuration for UEFI PXE boot
# Generated by extract-iso.sh
# Profile: $profile
# Uses GRUB network variables to pass IP config to kernel

function load_video {
    insmod efi_gop
    insmod efi_uga
    insmod video_bochs
    insmod video_cirrus
    insmod all_video
}

load_video
set gfxpayload=keep
insmod gzio
insmod png
insmod all_video
insmod net
insmod efinet

set color_normal=light-cyan/black
set color_highlight=black/light-cyan

set default=0
set timeout=60

# Get network info from GRUB's PXE boot
set myip="\${net_efinet0_ip}"
set mygateway="\${net_efinet0_gateway}"
set mynetmask="255.255.255.0"
set myhostname="pxeclient"

# Fallback if efinet0 variables aren't set
if [ -z "\$myip" ]; then
    set myip="\${net_default_ip}"
fi
if [ -z "\$mygateway" ]; then
    set mygateway="$ip"
fi

menuentry "$label" --class fedora --class gnu-linux --class gnu --class os {
    echo "Booting with IP: \${myip}, Gateway: \${mygateway}"
    linuxefi $profile/vmlinuz root=live:http://$ip/$profile/squashfs.img ro rd.live.image rd.luks=0 rd.dm=0 rd.neednet=1 ip=\${myip}::\${mygateway}:\${mynetmask}:\${myhostname}::none nameserver=$ip
    initrdefi $profile/initrd.img
}

menuentry "$label (DHCP fallback)" --class fedora --class gnu-linux --class gnu --class os {
    linuxefi $profile/vmlinuz root=live:http://$ip/$profile/squashfs.img ro rd.live.image rd.luks=0 rd.dm=0 rd.neednet=1 ip=dhcp
    initrdefi $profile/initrd.img
}

menuentry "$label (Debug Mode)" --class fedora --class gnu-linux --class gnu --class os {
    linuxefi $profile/vmlinuz root=live:http://$ip/$profile/squashfs.img ro rd.live.image rd.luks=0 rd.dm=0 rd.neednet=1 ip=\${myip}::\${mygateway}:\${mynetmask}:\${myhostname}::none nameserver=$ip rd.break
    initrdefi $profile/initrd.img
}

menuentry "Boot from Local Disk" --class hd {
    exit
}

menuentry "Reboot" --class reboot {
    reboot
}
EOF

    # Copy grub.cfg to TFTP root as well
    cp -f "$TFTP_DIR/efi64/grub.cfg" "$TFTP_DIR/grub.cfg"
    
    # Clean up any old broken symlinks in efi64
    rm -f "$TFTP_DIR/efi64/vmlinuz" 2>/dev/null || true
    rm -f "$TFTP_DIR/efi64/initrd.img" 2>/dev/null || true
    
    log_info "Boot configurations created successfully"
}

extract_iso() {
    local iso_path="$1"
    
    if [[ ! -f "$iso_path" ]]; then
        log_error "ISO file not found: $iso_path"
        exit 1
    fi
    
    # Display header
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         Fedora Remix PXE - ISO Extraction Script             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    
    # Prompt for configuration
    prompt_config "$iso_path"
    
    local profile="$PROFILE_NAME"
    
    log_info "Extracting ISO: $iso_path"
    log_info "Profile name: $profile"
    
    # Create mount point
    mkdir -p "$MOUNT_POINT"
    
    # Create destination directories
    mkdir -p "$TFTP_DIR/$profile"
    mkdir -p "$HTTP_DIR/$profile"
    
    # Mount ISO
    log_info "Mounting ISO..."
    mount -o loop,ro "$iso_path" "$MOUNT_POINT"
    
    # Find and copy kernel files
    log_info "Searching for kernel and initrd..."
    
    local vmlinuz=""
    local initrd=""
    
    # Common locations for vmlinuz and initrd in Fedora/RHEL LiveCDs
    local kernel_locations=(
        "isolinux/vmlinuz"
        "isolinux/vmlinuz0"
        "images/pxeboot/vmlinuz"
        "EFI/BOOT/vmlinuz"
        "LiveOS/vmlinuz"
        "boot/vmlinuz"
    )
    
    local initrd_locations=(
        "isolinux/initrd.img"
        "isolinux/initrd0.img"
        "images/pxeboot/initrd.img"
        "EFI/BOOT/initrd.img"
        "LiveOS/initrd.img"
        "boot/initrd.img"
    )
    
    # Find vmlinuz
    for loc in "${kernel_locations[@]}"; do
        if [[ -f "$MOUNT_POINT/$loc" ]]; then
            vmlinuz="$MOUNT_POINT/$loc"
            log_info "Found kernel: $loc"
            break
        fi
    done
    
    # Find initrd
    for loc in "${initrd_locations[@]}"; do
        if [[ -f "$MOUNT_POINT/$loc" ]]; then
            initrd="$MOUNT_POINT/$loc"
            log_info "Found initrd: $loc"
            break
        fi
    done
    
    if [[ -z "$vmlinuz" ]]; then
        log_error "Could not find vmlinuz in ISO"
        log_info "Searching for any vmlinuz file..."
        find "$MOUNT_POINT" -name "vmlinuz*" -type f 2>/dev/null | head -5
        exit 1
    fi
    
    if [[ -z "$initrd" ]]; then
        log_error "Could not find initrd.img in ISO"
        log_info "Searching for any initrd file..."
        find "$MOUNT_POINT" -name "initrd*" -type f 2>/dev/null | head -5
        exit 1
    fi
    
    # Copy kernel and initrd to TFTP directory
    log_info "Copying kernel to $TFTP_DIR/$profile/vmlinuz..."
    cp -f "$vmlinuz" "$TFTP_DIR/$profile/vmlinuz"
    
    log_info "Copying initrd to $TFTP_DIR/$profile/initrd.img..."
    cp -f "$initrd" "$TFTP_DIR/$profile/initrd.img"
    
    # Find and copy squashfs
    log_info "Searching for squashfs image..."
    
    local squashfs=""
    local squashfs_locations=(
        "LiveOS/squashfs.img"
        "LiveOS/rootfs.img"
        "images/install.img"
    )
    
    for loc in "${squashfs_locations[@]}"; do
        if [[ -f "$MOUNT_POINT/$loc" ]]; then
            squashfs="$MOUNT_POINT/$loc"
            log_info "Found squashfs: $loc"
            break
        fi
    done
    
    if [[ -z "$squashfs" ]]; then
        log_warn "Could not find squashfs.img in standard locations"
        log_info "Searching for squashfs files..."
        local found_squashfs=$(find "$MOUNT_POINT" -name "*.img" -size +100M -type f 2>/dev/null | head -1)
        if [[ -n "$found_squashfs" ]]; then
            squashfs="$found_squashfs"
            log_info "Found potential squashfs: $squashfs"
        fi
    fi
    
    if [[ -n "$squashfs" ]]; then
        local squashfs_size=$(du -h "$squashfs" | cut -f1)
        log_info "Copying squashfs image ($squashfs_size) to HTTP directory..."
        log_info "This may take a few minutes..."
        
        cp -f "$squashfs" "$HTTP_DIR/$profile/squashfs.img"
        log_info "SquashFS copied successfully"
    else
        log_error "No squashfs image found. PXE boot will not work without it."
        log_info "You may need to manually copy the root filesystem image."
    fi
    
    # Unmount ISO
    log_info "Unmounting ISO..."
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    
    # Generate boot configurations
    generate_boot_configs "$profile" "$PXE_IP" "$MENU_LABEL"
    
    # Show summary
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ISO Extraction Complete!                         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Source ISO:${NC} $iso_path"
    echo ""
    
    # Load DHCP config for display
    local dhcp_subnet=""
    local dhcp_range=""
    local dhcp_interface=""
    if [[ -f "$CONFIG_DIR/pxe-server.env" ]]; then
        source "$CONFIG_DIR/pxe-server.env"
        dhcp_subnet="${PXE_SUBNET:-unknown}/${PXE_NETMASK:-255.255.255.0}"
        dhcp_range="${PXE_RANGE_START:-unknown} - ${PXE_RANGE_END:-unknown}"
        dhcp_interface="${PXE_INTERFACE:-unknown}"
    fi
    
    echo -e "  ${BLUE}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${BLUE}│${NC}  ${CYAN}PXE Server Configuration${NC}                                  ${BLUE}│${NC}"
    echo -e "  ${BLUE}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${BLUE}│${NC}  Server IP:        ${GREEN}$PXE_IP${NC}"
    echo -e "  ${BLUE}│${NC}  Network Interface: $dhcp_interface"
    echo -e "  ${BLUE}│${NC}  Profile Name:     $profile"
    echo -e "  ${BLUE}│${NC}  Menu Label:       $MENU_LABEL"
    echo -e "  ${BLUE}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    echo -e "  ${BLUE}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${BLUE}│${NC}  ${CYAN}DHCP Server Settings${NC}                                      ${BLUE}│${NC}"
    echo -e "  ${BLUE}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${BLUE}│${NC}  Subnet:           $dhcp_subnet"
    echo -e "  ${BLUE}│${NC}  Client IP Range:  $dhcp_range"
    echo -e "  ${BLUE}│${NC}  Gateway/Router:   ${PXE_ROUTER:-$PXE_IP}"
    echo -e "  ${BLUE}│${NC}  DNS Server:       ${PXE_DNS:-$PXE_IP}"
    echo -e "  ${BLUE}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    echo -e "  ${BLUE}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${BLUE}│${NC}  ${CYAN}Boot Files (TFTP)${NC}                                         ${BLUE}│${NC}"
    echo -e "  ${BLUE}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${BLUE}│${NC}  Kernel:   $TFTP_DIR/$profile/vmlinuz"
    echo -e "  ${BLUE}│${NC}  Initrd:   $TFTP_DIR/$profile/initrd.img"
    echo -e "  ${BLUE}│${NC}  TFTP URL: tftp://$PXE_IP/$profile/vmlinuz"
    echo -e "  ${BLUE}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    local final_size=""
    if [[ -f "$HTTP_DIR/$profile/squashfs.img" ]]; then
        final_size=$(du -h "$HTTP_DIR/$profile/squashfs.img" 2>/dev/null | cut -f1)
    fi
    echo -e "  ${BLUE}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${BLUE}│${NC}  ${CYAN}Root Filesystem (HTTP)${NC}                                    ${BLUE}│${NC}"
    echo -e "  ${BLUE}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${BLUE}│${NC}  SquashFS: $HTTP_DIR/$profile/squashfs.img"
    echo -e "  ${BLUE}│${NC}  Size:     ${final_size:-unknown}"
    echo -e "  ${BLUE}│${NC}  HTTP URL: ${GREEN}http://$PXE_IP/$profile/squashfs.img${NC}"
    echo -e "  ${BLUE}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    echo -e "  ${BLUE}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${BLUE}│${NC}  ${CYAN}Boot Menu Configurations${NC}                                  ${BLUE}│${NC}"
    echo -e "  ${BLUE}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${BLUE}│${NC}  BIOS:  $TFTP_DIR/pxelinux.cfg/default"
    echo -e "  ${BLUE}│${NC}  UEFI:  $TFTP_DIR/efi64/grub.cfg"
    echo -e "  ${BLUE}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    echo -e "  ${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${YELLOW}│${NC}  ${YELLOW}Next Steps${NC}                                                 ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${YELLOW}│${NC}  1. Start or restart the PXE server:"
    echo -e "  ${YELLOW}│${NC}     ${GREEN}sudo $SCRIPT_DIR/pxe-server.sh restart${NC}"
    echo -e "  ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}  2. Boot a client via PXE and select:"
    echo -e "  ${YELLOW}│${NC}     \"${GREEN}$MENU_LABEL${NC}\""
    echo -e "  ${YELLOW}│${NC}"
    echo -e "  ${YELLOW}│${NC}  3. Client will:"
    echo -e "  ${YELLOW}│${NC}     - Get IP from DHCP ($dhcp_range)"
    echo -e "  ${YELLOW}│${NC}     - Load kernel/initrd via TFTP from $PXE_IP"
    echo -e "  ${YELLOW}│${NC}     - Fetch root filesystem via HTTP from $PXE_IP"
    echo -e "  ${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# Parse command line arguments
ARG_IP=""
ARG_PROFILE=""
ARG_LABEL=""
ARG_YES=false
ARG_ISO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help|help)
            usage
            exit 0
            ;;
        -i|--ip)
            ARG_IP="$2"
            shift 2
            ;;
        -p|--profile)
            ARG_PROFILE="$2"
            shift 2
            ;;
        -l|--label)
            ARG_LABEL="$2"
            shift 2
            ;;
        -y|--yes)
            ARG_YES=true
            shift
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            ARG_ISO="$1"
            shift
            ;;
    esac
done

# Main
check_root

if [[ -z "$ARG_ISO" ]]; then
    usage
    exit 1
fi

extract_iso "$ARG_ISO"
