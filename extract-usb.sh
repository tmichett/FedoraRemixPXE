#!/bin/bash
#
# USB Extraction Script for PXE Boot
# Copies kernel, initrd, and squashfs from a mounted LiveUSB
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

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

usage() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         Fedora Remix PXE - USB Extraction Script             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Usage: $0 [OPTIONS] [USB_PATH_OR_LABEL]"
    echo ""
    echo "Arguments:"
    echo "  USB_PATH_OR_LABEL   Path to mounted USB or volume label (default: FedoraRemix)"
    echo ""
    echo "Options:"
    echo "  -i, --ip IP        PXE server IP address"
    echo "  -p, --profile NAME Profile name (directory name for boot files)"
    echo "  -l, --label TEXT   Boot menu label"
    echo "  -y, --yes          Non-interactive mode (use defaults/provided values)"
    echo "  -h, --help         Show this help"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Auto-detect FedoraRemix USB"
    echo "  $0 /run/media/user/FedoraRemix       # Specify mount path"
    echo "  $0 -i 192.168.100.1 -p fedora43 -y   # Non-interactive with IP"
    echo ""
    echo "This script will:"
    echo "  1. Find or use the specified mounted USB drive"
    echo "  2. Copy vmlinuz and initrd to TFTP directory"
    echo "  3. Copy squashfs.img to HTTP directory"
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

# Find mounted USB by label
find_usb_by_label() {
    local label="$1"
    
    # Check common mount points
    local mount_points=(
        "/run/media/${SUDO_USER:-$USER}/$label"
        "/run/media/root/$label"
        "/media/${SUDO_USER:-$USER}/$label"
        "/media/$label"
        "/mnt/$label"
    )
    
    for mount in "${mount_points[@]}"; do
        if [[ -d "$mount" && -f "$mount/LiveOS/squashfs.img" ]]; then
            echo "$mount"
            return 0
        fi
    done
    
    # Try to find by scanning lsblk
    local found_mount=$(lsblk -o LABEL,MOUNTPOINT -n | grep -i "^$label" | awk '{print $2}' | head -1)
    if [[ -n "$found_mount" && -d "$found_mount" ]]; then
        echo "$found_mount"
        return 0
    fi
    
    return 1
}

# List available USB drives
list_usb_drives() {
    echo -e "${BLUE}Available mounted drives with LiveOS:${NC}"
    echo ""
    
    local found=0
    # Check /run/media
    for user_dir in /run/media/*; do
        if [[ -d "$user_dir" ]]; then
            for mount in "$user_dir"/*; do
                if [[ -d "$mount" && -f "$mount/LiveOS/squashfs.img" ]]; then
                    local label=$(basename "$mount")
                    local size=$(du -sh "$mount/LiveOS/squashfs.img" 2>/dev/null | cut -f1)
                    echo -e "  ${GREEN}●${NC} $mount (squashfs: $size)"
                    found=1
                fi
            done
        fi
    done
    
    # Check /media
    for mount in /media/*; do
        if [[ -d "$mount" && -f "$mount/LiveOS/squashfs.img" ]]; then
            local label=$(basename "$mount")
            local size=$(du -sh "$mount/LiveOS/squashfs.img" 2>/dev/null | cut -f1)
            echo -e "  ${GREEN}●${NC} $mount (squashfs: $size)"
            found=1
        fi
    done
    
    if [[ $found -eq 0 ]]; then
        echo -e "  ${YELLOW}No mounted LiveOS USB drives found${NC}"
        echo ""
        echo "  Make sure your USB drive is mounted and contains:"
        echo "    - LiveOS/squashfs.img"
        echo "    - isolinux/vmlinuz0 or isolinux/vmlinuz"
        echo "    - isolinux/initrd0.img or isolinux/initrd.img"
    fi
    echo ""
}

# Prompt for configuration
prompt_config() {
    local usb_label=$(basename "$1")
    
    # Calculate defaults
    local default_ip=$(get_default_ip)
    local default_profile=$(echo "$usb_label" | sed 's/[^a-zA-Z0-9]/_/g' | tr '[:upper:]' '[:lower:]')
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
    read -p "  Enter PXE Server IP [$default_ip]: " input_ip
    PXE_IP="${input_ip:-$default_ip}"
    echo ""
    
    # Get Profile Name
    echo -e "${BLUE}Profile Name${NC}"
    echo -e "  A short name for this boot image (used in file paths)."
    read -p "  Enter profile name [$default_profile]: " input_profile
    PROFILE_NAME="${input_profile:-$default_profile}"
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
# Generated by extract-usb.sh
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
# Generated by extract-usb.sh
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
    
    # Clean up old broken symlinks
    rm -f "$TFTP_DIR/efi64/vmlinuz" 2>/dev/null || true
    rm -f "$TFTP_DIR/efi64/initrd.img" 2>/dev/null || true
    
    log_info "Boot configurations created successfully"
}

# Copy UEFI boot files to TFTP root
copy_uefi_files() {
    local usb_path="$1"
    
    log_info "Copying UEFI boot files..."
    
    # Copy EFI files if they exist on USB
    if [[ -f "$usb_path/EFI/BOOT/BOOTX64.EFI" ]]; then
        cp -f "$usb_path/EFI/BOOT/BOOTX64.EFI" "$TFTP_DIR/"
        cp -f "$usb_path/EFI/BOOT/BOOTX64.EFI" "$TFTP_DIR/efi64/"
    fi
    
    if [[ -f "$usb_path/EFI/BOOT/grubx64.efi" ]]; then
        cp -f "$usb_path/EFI/BOOT/grubx64.efi" "$TFTP_DIR/"
        cp -f "$usb_path/EFI/BOOT/grubx64.efi" "$TFTP_DIR/efi64/"
    fi
    
    # Copy syslinux files if they exist
    if [[ -f "$usb_path/isolinux/vesamenu.c32" ]]; then
        cp -f "$usb_path/isolinux/vesamenu.c32" "$TFTP_DIR/"
    fi
    if [[ -f "$usb_path/isolinux/ldlinux.c32" ]]; then
        cp -f "$usb_path/isolinux/ldlinux.c32" "$TFTP_DIR/"
    fi
    if [[ -f "$usb_path/isolinux/libutil.c32" ]]; then
        cp -f "$usb_path/isolinux/libutil.c32" "$TFTP_DIR/"
    fi
    if [[ -f "$usb_path/isolinux/libcom32.c32" ]]; then
        cp -f "$usb_path/isolinux/libcom32.c32" "$TFTP_DIR/"
    fi
}

extract_usb() {
    local usb_path="$1"
    
    # Validate USB path
    if [[ ! -d "$usb_path" ]]; then
        log_error "USB path not found: $usb_path"
        exit 1
    fi
    
    if [[ ! -f "$usb_path/LiveOS/squashfs.img" ]]; then
        log_error "No LiveOS/squashfs.img found in $usb_path"
        log_error "This doesn't appear to be a valid Fedora LiveUSB"
        exit 1
    fi
    
    # Display header
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         Fedora Remix PXE - USB Extraction Script             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    
    log_info "USB Source: $usb_path"
    
    # Prompt for configuration
    prompt_config "$usb_path"
    
    local profile="$PROFILE_NAME"
    
    # Create destination directories
    mkdir -p "$TFTP_DIR/$profile"
    mkdir -p "$HTTP_DIR/$profile"
    
    # Find kernel
    local vmlinuz=""
    local kernel_locations=(
        "isolinux/vmlinuz0"
        "isolinux/vmlinuz"
        "images/pxeboot/vmlinuz"
        "boot/vmlinuz"
    )
    
    for loc in "${kernel_locations[@]}"; do
        if [[ -f "$usb_path/$loc" ]]; then
            vmlinuz="$usb_path/$loc"
            log_info "Found kernel: $loc"
            break
        fi
    done
    
    if [[ -z "$vmlinuz" ]]; then
        log_error "Could not find kernel (vmlinuz) on USB"
        exit 1
    fi
    
    # Find initrd
    local initrd=""
    local initrd_locations=(
        "isolinux/initrd0.img"
        "isolinux/initrd.img"
        "images/pxeboot/initrd.img"
        "boot/initrd.img"
    )
    
    for loc in "${initrd_locations[@]}"; do
        if [[ -f "$usb_path/$loc" ]]; then
            initrd="$usb_path/$loc"
            log_info "Found initrd: $loc"
            break
        fi
    done
    
    if [[ -z "$initrd" ]]; then
        log_error "Could not find initrd on USB"
        exit 1
    fi
    
    # Copy kernel
    log_info "Copying kernel to $TFTP_DIR/$profile/vmlinuz..."
    cp -f "$vmlinuz" "$TFTP_DIR/$profile/vmlinuz"
    
    # Copy initrd
    log_info "Copying initrd to $TFTP_DIR/$profile/initrd.img..."
    cp -f "$initrd" "$TFTP_DIR/$profile/initrd.img"
    
    # Copy squashfs
    local squashfs="$usb_path/LiveOS/squashfs.img"
    local squashfs_size=$(du -h "$squashfs" | cut -f1)
    log_info "Copying squashfs image ($squashfs_size) to HTTP directory..."
    log_info "This may take a few minutes..."
    
    cp -f "$squashfs" "$HTTP_DIR/$profile/squashfs.img"
    log_info "SquashFS copied successfully"
    
    # Copy UEFI boot files
    copy_uefi_files "$usb_path"
    
    # Generate boot configurations
    generate_boot_configs "$profile" "$PXE_IP" "$MENU_LABEL"
    
    # Show summary
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              USB Extraction Complete!                         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Source:${NC}       $usb_path"
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
    
    local final_size=$(du -h "$HTTP_DIR/$profile/squashfs.img" 2>/dev/null | cut -f1)
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
ARG_USB=""

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
        --list)
            list_usb_drives
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            ARG_USB="$1"
            shift
            ;;
    esac
done

# Main
check_root

# Determine USB path
USB_PATH=""

if [[ -n "$ARG_USB" ]]; then
    # User specified a path or label
    if [[ -d "$ARG_USB" ]]; then
        USB_PATH="$ARG_USB"
    else
        # Try to find by label
        USB_PATH=$(find_usb_by_label "$ARG_USB")
        if [[ -z "$USB_PATH" ]]; then
            log_error "Could not find USB with label or path: $ARG_USB"
            echo ""
            list_usb_drives
            exit 1
        fi
    fi
else
    # Auto-detect FedoraRemix
    USB_PATH=$(find_usb_by_label "FedoraRemix")
    if [[ -z "$USB_PATH" ]]; then
        log_warn "No FedoraRemix USB found. Searching for other LiveOS drives..."
        echo ""
        list_usb_drives
        exit 1
    fi
fi

extract_usb "$USB_PATH"


