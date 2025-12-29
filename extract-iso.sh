#!/bin/bash
#
# ISO Extraction Script for PXE Boot
# Extracts kernel, initrd, and squashfs from a Fedora/RHEL LiveCD ISO
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
TFTP_DIR="${DATA_DIR}/tftpboot"
HTTP_DIR="${DATA_DIR}/http"
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
    echo "Usage: $0 <path-to-iso> [profile-name]"
    echo ""
    echo "Arguments:"
    echo "  path-to-iso    Path to a Fedora/RHEL LiveCD ISO file"
    echo "  profile-name   Optional name for this boot profile (default: livecd)"
    echo ""
    echo "Examples:"
    echo "  $0 /path/to/Fedora-Live.iso"
    echo "  $0 /path/to/Fedora-Live.iso fedora39"
    echo ""
    echo "This script will extract:"
    echo "  - vmlinuz (kernel) and initrd.img to TFTP directory"
    echo "  - squashfs.img to HTTP directory for network boot"
}

extract_iso() {
    local iso_path="$1"
    local profile="${2:-livecd}"
    
    if [[ ! -f "$iso_path" ]]; then
        log_error "ISO file not found: $iso_path"
        exit 1
    fi
    
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
    
    # Update PXE configuration if using default profile
    if [[ "$profile" == "livecd" ]]; then
        log_info "Profile 'livecd' is the default boot profile."
        log_info "No configuration changes needed."
    else
        log_warn "You may need to update the PXE boot menu configuration"
        log_warn "to include the new profile: $profile"
        log_info "Edit: $TFTP_DIR/pxelinux.cfg/default"
        log_info "Edit: $TFTP_DIR/efi64/grub.cfg"
    fi
    
    # Show summary
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ISO Extraction Complete!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BLUE}Profile:${NC}      $profile"
    echo -e "  ${BLUE}Kernel:${NC}       $TFTP_DIR/$profile/vmlinuz"
    echo -e "  ${BLUE}Initrd:${NC}       $TFTP_DIR/$profile/initrd.img"
    if [[ -f "$HTTP_DIR/$profile/squashfs.img" ]]; then
        local final_size=$(du -h "$HTTP_DIR/$profile/squashfs.img" | cut -f1)
        echo -e "  ${BLUE}SquashFS:${NC}     $HTTP_DIR/$profile/squashfs.img ($final_size)"
    fi
    echo ""
    echo -e "  ${YELLOW}Next steps:${NC}"
    echo "    1. Start or restart the PXE server:"
    echo "       sudo $SCRIPT_DIR/pxe-server.sh restart"
    echo ""
    echo "    2. Boot a client via PXE and select the LiveCD option"
    echo ""
}

# Main
check_root

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

case "$1" in
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        extract_iso "$1" "${2:-livecd}"
        ;;
esac

