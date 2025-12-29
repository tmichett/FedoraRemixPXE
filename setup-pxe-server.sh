#!/bin/bash
#
# PXE Server Setup Script for Fedora Linux
# This script configures the host system and starts a containerized PXE server
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
DATA_DIR="${SCRIPT_DIR}/data"
TFTP_DIR="${DATA_DIR}/tftpboot"
HTTP_DIR="${DATA_DIR}/http"
ISO_DIR="${DATA_DIR}/iso"
CONTAINER_NAME="pxe-server"
IMAGE_NAME="quay.io/tmichett/fedoraremixpxe:latest"
LOCAL_IMAGE_NAME="localhost/fedoraremixpxe:latest"

# Network configuration (can be overridden via environment variables)
# By default, the PXE server acts as the gateway/router, DNS, and TFTP server
# All services run on the same IP address
PXE_INTERFACE="${PXE_INTERFACE:-}"
PXE_SERVER_IP="${PXE_SERVER_IP:-192.168.0.1}"
PXE_SUBNET="${PXE_SUBNET:-192.168.0.0}"
PXE_NETMASK="${PXE_NETMASK:-255.255.255.0}"
PXE_RANGE_START="${PXE_RANGE_START:-192.168.0.201}"
PXE_RANGE_END="${PXE_RANGE_END:-192.168.0.240}"
PXE_VIRTUAL_RANGE_START="${PXE_VIRTUAL_RANGE_START:-192.168.0.101}"
PXE_VIRTUAL_RANGE_END="${PXE_VIRTUAL_RANGE_END:-192.168.0.140}"
# Router and DNS default to the same as PXE server (single-server setup)
PXE_ROUTER="${PXE_ROUTER:-$PXE_SERVER_IP}"
PXE_DNS="${PXE_DNS:-$PXE_SERVER_IP}"
PXE_DOMAIN="${PXE_DOMAIN:-example.com}"

print_header() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           Fedora Remix PXE Server Setup                      ║"
    echo "║           Containerized PXE Boot Services                    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

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

check_podman() {
    if ! command -v podman &> /dev/null; then
        log_error "Podman is not installed. Please install it first:"
        echo "  sudo dnf install podman"
        exit 1
    fi
    log_info "Podman found: $(podman --version)"
}

detect_network() {
    log_info "Detecting network configuration..."
    
    # Get list of physical network interfaces
    # Exclude: loopback, virtual (veth, br-, docker, virbr, podman), and wireless
    local -a interfaces=()
    local -a iface_info=()
    
    while IFS= read -r iface; do
        # Skip empty lines
        [[ -z "$iface" ]] && continue
        
        # Skip virtual interfaces
        [[ "$iface" =~ ^(lo|veth|br-|docker|virbr|podman|tun|tap) ]] && continue
        
        # Check if wireless (has /sys/class/net/<iface>/wireless directory)
        if [[ -d "/sys/class/net/$iface/wireless" ]]; then
            continue
        fi
        
        # Check if it's a physical device (has /sys/class/net/<iface>/device)
        # This filters out some virtual interfaces
        if [[ ! -d "/sys/class/net/$iface/device" ]] && [[ "$iface" != "lo" ]]; then
            # Still include if it has an IP (might be a bridge we want)
            local has_ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -c "inet ")
            [[ "$has_ip" -eq 0 ]] && continue
        fi
        
        interfaces+=("$iface")
    done < <(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//')
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log_error "No suitable network interfaces found"
        exit 1
    fi
    
    if [[ -z "$PXE_INTERFACE" ]]; then
        echo ""
        echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║                     Available Network Interfaces                         ║${NC}"
        echo -e "${BLUE}╠════╦════════════════╦══════════╦═══════════════════╦═════════════════════╣${NC}"
        echo -e "${BLUE}║${NC} #  ${BLUE}║${NC} Interface      ${BLUE}║${NC}  Status  ${BLUE}║${NC} IP Address        ${BLUE}║${NC} MAC Address         ${BLUE}║${NC}"
        echo -e "${BLUE}╠════╬════════════════╬══════════╬═══════════════════╬═════════════════════╣${NC}"
        
        for i in "${!interfaces[@]}"; do
            local iface="${interfaces[$i]}"
            
            # Get interface status (UP/DOWN)
            local state=$(ip link show "$iface" 2>/dev/null | grep -oP '(?<=state )\w+' | head -1)
            local state_color=""
            case "$state" in
                UP)
                    state_color="${GREEN}"
                    state="UP"
                    ;;
                DOWN)
                    state_color="${RED}"
                    state="DOWN"
                    ;;
                *)
                    state_color="${YELLOW}"
                    state="${state:-UNKNOWN}"
                    ;;
            esac
            
            # Get IP address
            local ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
            ip="${ip:---}"
            
            # Get MAC address
            local mac=$(ip link show "$iface" 2>/dev/null | grep -oP '(?<=link/ether\s)[a-f0-9:]+' | head -1)
            mac="${mac:---}"
            
            # Format output
            printf "${BLUE}║${NC} %-2s ${BLUE}║${NC} %-14s ${BLUE}║${NC} %s%-8s${NC} ${BLUE}║${NC} %-17s ${BLUE}║${NC} %-19s ${BLUE}║${NC}\n" \
                "$((i+1))" "$iface" "$state_color" "$state" "$ip" "$mac"
        done
        
        echo -e "${BLUE}╚════╩════════════════╩══════════╩═══════════════════╩═════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}Note:${NC} Wireless adapters are excluded from this list."
        echo ""
        
        # Prompt for selection
        local valid_choice=false
        while [[ "$valid_choice" == "false" ]]; do
            read -p "Select interface number for DHCP/PXE services [1]: " choice
            choice=${choice:-1}
            
            if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#interfaces[@]} ]]; then
                valid_choice=true
                PXE_INTERFACE="${interfaces[$((choice-1))]}"
            else
                log_error "Invalid selection. Please enter a number between 1 and ${#interfaces[@]}"
            fi
        done
    fi
    
    if [[ -z "$PXE_INTERFACE" ]]; then
        log_error "No network interface selected"
        exit 1
    fi
    
    log_info "Using interface: $PXE_INTERFACE"
    
    # Check current IP on interface
    local current_ip=$(ip -4 addr show "$PXE_INTERFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    
    if [[ -n "$current_ip" ]]; then
        log_info "Current IP on $PXE_INTERFACE: $current_ip"
        if [[ "$current_ip" != "$PXE_SERVER_IP" ]]; then
            log_warn "Current IP ($current_ip) differs from configured PXE_SERVER_IP ($PXE_SERVER_IP)"
            echo ""
            echo "Options:"
            echo "  1. Use current IP ($current_ip) for PXE server"
            echo "  2. Configure interface with PXE server IP ($PXE_SERVER_IP)"
            echo "  3. Keep configured IP but don't change interface (manual setup)"
            read -p "Select option [1]: " ip_choice
            ip_choice=${ip_choice:-1}
            
            case $ip_choice in
                1)
                    PXE_SERVER_IP="$current_ip"
                    ;;
                2)
                    configure_static_ip
                    ;;
                3)
                    log_warn "Make sure $PXE_SERVER_IP is configured on $PXE_INTERFACE before starting PXE services"
                    ;;
            esac
        fi
    else
        log_warn "No IP address configured on $PXE_INTERFACE"
        echo ""
        read -p "Configure $PXE_INTERFACE with IP $PXE_SERVER_IP? [Y/n]: " configure_ip
        if [[ ! "$configure_ip" =~ ^[Nn]$ ]]; then
            configure_static_ip
        else
            log_error "PXE server requires an IP address on the interface"
            exit 1
        fi
    fi
    
    # Ensure router and DNS use server IP (single-server setup)
    PXE_ROUTER="$PXE_SERVER_IP"
    PXE_DNS="$PXE_SERVER_IP"
    
    log_info "PXE Server IP: $PXE_SERVER_IP"
    log_info "Router/Gateway: $PXE_ROUTER"
    log_info "DNS Server: $PXE_DNS"
    log_info "Domain: $PXE_DOMAIN"
}

configure_static_ip() {
    log_info "Configuring static IP $PXE_SERVER_IP on $PXE_INTERFACE..."
    
    # Calculate prefix length from netmask
    local prefix_len=24
    case "$PXE_NETMASK" in
        255.255.255.0)   prefix_len=24 ;;
        255.255.0.0)     prefix_len=16 ;;
        255.0.0.0)       prefix_len=8 ;;
        255.255.255.128) prefix_len=25 ;;
        255.255.255.192) prefix_len=26 ;;
        255.255.255.224) prefix_len=27 ;;
        255.255.255.240) prefix_len=28 ;;
    esac
    
    # Check if using NetworkManager
    if systemctl is-active --quiet NetworkManager; then
        log_info "Using NetworkManager to configure IP..."
        
        # Get connection name for interface
        local conn_name=$(nmcli -t -f NAME,DEVICE con show | grep ":${PXE_INTERFACE}$" | cut -d: -f1)
        
        if [[ -z "$conn_name" ]]; then
            # Create new connection
            conn_name="pxe-${PXE_INTERFACE}"
            nmcli con add type ethernet con-name "$conn_name" ifname "$PXE_INTERFACE" \
                ipv4.addresses "${PXE_SERVER_IP}/${prefix_len}" \
                ipv4.method manual \
                connection.autoconnect yes
        else
            # Modify existing connection
            nmcli con mod "$conn_name" \
                ipv4.addresses "${PXE_SERVER_IP}/${prefix_len}" \
                ipv4.method manual
        fi
        
        # Apply changes
        nmcli con up "$conn_name"
        
    else
        # Fallback to ip command (temporary, won't persist reboot)
        log_warn "NetworkManager not active, using ip command (temporary configuration)"
        
        # Flush existing IPs
        ip addr flush dev "$PXE_INTERFACE" 2>/dev/null || true
        
        # Add new IP
        ip addr add "${PXE_SERVER_IP}/${prefix_len}" dev "$PXE_INTERFACE"
        ip link set "$PXE_INTERFACE" up
        
        log_warn "This IP configuration will not persist after reboot!"
        log_warn "Consider using NetworkManager or creating a network config file."
    fi
    
    # Verify IP was set
    sleep 2
    local new_ip=$(ip -4 addr show "$PXE_INTERFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [[ "$new_ip" == "$PXE_SERVER_IP" ]]; then
        log_info "Successfully configured $PXE_SERVER_IP on $PXE_INTERFACE"
    else
        log_error "Failed to configure IP address"
        exit 1
    fi
}

configure_firewall() {
    log_info "Configuring firewall rules..."
    
    # Check if firewalld is running
    if systemctl is-active --quiet firewalld; then
        log_info "Configuring firewalld..."
        
        # Add PXE-related services
        firewall-cmd --permanent --add-service=tftp || true
        firewall-cmd --permanent --add-service=dhcp || true
        firewall-cmd --permanent --add-service=http || true
        
        # Add specific ports
        firewall-cmd --permanent --add-port=69/udp   # TFTP
        firewall-cmd --permanent --add-port=67/udp   # DHCP Server
        firewall-cmd --permanent --add-port=68/udp   # DHCP Client
        firewall-cmd --permanent --add-port=80/tcp   # HTTP
        firewall-cmd --permanent --add-port=4011/udp # PXE proxy DHCP
        
        # Reload firewall
        firewall-cmd --reload
        
        log_info "Firewall rules applied successfully"
    else
        log_warn "firewalld is not running. Skipping firewall configuration."
        log_warn "Make sure your firewall allows: TFTP(69/udp), DHCP(67-68/udp), HTTP(80/tcp)"
    fi
}

create_directories() {
    log_info "Creating directory structure..."
    
    mkdir -p "$TFTP_DIR"/{pxelinux.cfg,efi64}
    mkdir -p "$HTTP_DIR"/livecd
    mkdir -p "$ISO_DIR"
    mkdir -p "$CONFIG_DIR"
    
    log_info "Directories created:"
    log_info "  TFTP root: $TFTP_DIR"
    log_info "  HTTP root: $HTTP_DIR"
    log_info "  ISO storage: $ISO_DIR"
}

copy_boot_files() {
    log_info "Setting up PXE boot files..."
    
    # Check for syslinux/pxelinux files
    local syslinux_dirs=(
        "/usr/share/syslinux"
        "/usr/lib/syslinux/bios"
        "/usr/lib/SYSLINUX"
    )
    
    local syslinux_found=""
    for dir in "${syslinux_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            syslinux_found="$dir"
            break
        fi
    done
    
    if [[ -n "$syslinux_found" ]]; then
        log_info "Copying syslinux files from $syslinux_found..."
        cp -f "$syslinux_found/pxelinux.0" "$TFTP_DIR/" 2>/dev/null || true
        cp -f "$syslinux_found/ldlinux.c32" "$TFTP_DIR/" 2>/dev/null || true
        cp -f "$syslinux_found/libutil.c32" "$TFTP_DIR/" 2>/dev/null || true
        cp -f "$syslinux_found/vesamenu.c32" "$TFTP_DIR/" 2>/dev/null || true
        cp -f "$syslinux_found/menu.c32" "$TFTP_DIR/" 2>/dev/null || true
        cp -f "$syslinux_found/libcom32.c32" "$TFTP_DIR/" 2>/dev/null || true
    else
        log_warn "Syslinux not found. Installing..."
        dnf install -y syslinux syslinux-tftpboot 2>/dev/null || true
        # Try again after install
        for dir in "${syslinux_dirs[@]}"; do
            if [[ -d "$dir" ]]; then
                cp -f "$dir/pxelinux.0" "$TFTP_DIR/" 2>/dev/null || true
                cp -f "$dir/ldlinux.c32" "$TFTP_DIR/" 2>/dev/null || true
                cp -f "$dir/libutil.c32" "$TFTP_DIR/" 2>/dev/null || true
                cp -f "$dir/vesamenu.c32" "$TFTP_DIR/" 2>/dev/null || true
                cp -f "$dir/menu.c32" "$TFTP_DIR/" 2>/dev/null || true
                cp -f "$dir/libcom32.c32" "$TFTP_DIR/" 2>/dev/null || true
                break
            fi
        done
    fi
    
    # Copy UEFI shim and grub files
    local shim_paths=(
        "/boot/efi/EFI/fedora/shimx64.efi"
        "/usr/share/shim/*/shimx64.efi"
    )
    
    local grub_paths=(
        "/boot/efi/EFI/fedora/grubx64.efi"
        "/usr/share/grub/x86_64-efi/grubx64.efi"
    )
    
    for path in ${shim_paths[@]}; do
        if [[ -f $path ]]; then
            cp -f "$path" "$TFTP_DIR/efi64/BOOTX64.EFI" 2>/dev/null || true
            cp -f "$path" "$TFTP_DIR/efi64/shimx64.efi" 2>/dev/null || true
            log_info "Copied UEFI shim from $path"
            break
        fi
    done
    
    for path in ${grub_paths[@]}; do
        if [[ -f $path ]]; then
            cp -f "$path" "$TFTP_DIR/efi64/grubx64.efi" 2>/dev/null || true
            log_info "Copied GRUB EFI from $path"
            break
        fi
    done
    
    # Create symlinks for UEFI boot
    ln -sf efi64/BOOTX64.EFI "$TFTP_DIR/BOOTX64.EFI" 2>/dev/null || true
    
    # Copy splash image if available
    if [[ -f "$SCRIPT_DIR/assets/splash.png" ]]; then
        cp -f "$SCRIPT_DIR/assets/splash.png" "$TFTP_DIR/splash.png"
        cp -f "$SCRIPT_DIR/assets/splash.png" "$TFTP_DIR/pxe_splash.png"
        log_info "Copied PXE splash image"
    fi
}

generate_configs() {
    log_info "Generating configuration files..."
    
    # Generate DHCP configuration (matching PXEServer project layout)
    cat > "$CONFIG_DIR/dhcpd.conf" << EOF
# DHCP Configuration for PXE Boot Services
# Generated by setup-pxe-server.sh
# Network configuration matches PXEServer project

ddns-update-style none;

option space pxelinux;
option pxelinux.magic code 208 = string;
option pxelinux.configfile code 209 = text;
option pxelinux.pathprefix code 210 = text;
option pxelinux.reboottime code 211 = unsigned integer 32;
option architecture-type code 93 = unsigned integer 16;

subnet ${PXE_SUBNET} netmask ${PXE_NETMASK} {

    # Virtual machine clients (KVM/Xen/etc)
    class "virtual" {
        match if substring (hardware, 1, 3) = 52:54:00 or
             substring (hardware, 1, 3) = 00:16:3e or
             substring (hardware, 1, 3) = 00:16:36;
    }

    # Microsoft clients
    class "microsoft-clients" {
        match if substring(option vendor-class-identifier,0,4) = "MSFT";
    }

    # PXE Boot clients
    class "pxeclients" {
        match if substring(option vendor-class-identifier, 0, 9) = "PXEClient";
        next-server ${PXE_SERVER_IP};
        
        if option architecture-type = 00:07 {
            # UEFI SYSTEMS
            filename "BOOTX64.EFI";
        } else {
            # EVERYBODY ELSE (BIOS)
            filename "pxelinux.0";
        }
    }

    # Standard network options
    option routers ${PXE_ROUTER};
    option subnet-mask ${PXE_NETMASK};
    option domain-name "${PXE_DOMAIN}";
    option domain-name-servers ${PXE_DNS};
    default-lease-time 21600;
    max-lease-time 43200;

    # Pool for virtual machine clients (192.168.0.101-140)
    pool {
        deny members of "pxeclients";
        allow members of "virtual";
        default-lease-time 120;
        max-lease-time 180;
        range ${PXE_VIRTUAL_RANGE_START} ${PXE_VIRTUAL_RANGE_END};
    }

    # Pool for PXE boot clients (192.168.0.201-240)
    pool {
        deny members of "virtual";
        allow members of "pxeclients";
        default-lease-time 120;
        max-lease-time 180;
        range ${PXE_RANGE_START} ${PXE_RANGE_END};
    }
}
EOF

    # Generate PXELinux configuration (BIOS) - matching PXEServer project style
    cat > "$TFTP_DIR/pxelinux.cfg/default" << EOF
# PXELinux Configuration for BIOS Boot
# Generated by setup-pxe-server.sh

UI vesamenu.c32
timeout 600
MENU TITLE Travis's Fedora Remix PXE Boot Menu
MENU BACKGROUND splash.png
menu width 80
menu rows 14

label local
menu label Boot from ^local drive
menu default
localboot 0xffff

label linux
menu label ^Boot Fedora Remix 64-bit (LiveCD)
kernel livecd/vmlinuz
append initrd=livecd/initrd.img root=live:http://${PXE_SERVER_IP}/livecd/squashfs.img ro rd.live.image rd.luks=0 rd.dm=0

label linux-debug
menu label Boot Fedora Remix (^Debug Mode)
kernel livecd/vmlinuz
append initrd=livecd/initrd.img root=live:http://${PXE_SERVER_IP}/livecd/squashfs.img ro rd.live.image rd.luks=0 rd.dm=0 rd.shell
EOF

    # Generate GRUB configuration (UEFI) - matching PXEServer project style
    cat > "$TFTP_DIR/efi64/grub.cfg" << EOF
# GRUB Configuration for UEFI PXE Boot
# Generated by setup-pxe-server.sh

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

set color_normal=light-cyan/black
set color_highlight=black/light-cyan

menuentry "Boot Travis's Fedora Remix (Live)" --class fedora --class gnu-linux --class gnu --class os {
	linuxefi vmlinuz root=live:http://${PXE_SERVER_IP}/livecd/squashfs.img ro rd.live.image rd.luks=0 rd.dm=0
	initrdefi initrd.img
}

menuentry "Boot Fedora Remix (Debug Mode)" --class fedora --class gnu-linux --class gnu --class os {
	linuxefi vmlinuz root=live:http://${PXE_SERVER_IP}/livecd/squashfs.img ro rd.live.image rd.luks=0 rd.dm=0 rd.shell
	initrdefi initrd.img
}

menuentry 'Reboot' {
	reboot
}
EOF

    # Copy grub.cfg to root tftp dir as well (some UEFI implementations look there)
    cp "$TFTP_DIR/efi64/grub.cfg" "$TFTP_DIR/grub.cfg"
    
    # Also copy kernel/initrd symlinks to efi64 directory for UEFI boot
    # UEFI grub.cfg references vmlinuz and initrd.img relative to its location
    ln -sf ../livecd/vmlinuz "$TFTP_DIR/efi64/vmlinuz" 2>/dev/null || true
    ln -sf ../livecd/initrd.img "$TFTP_DIR/efi64/initrd.img" 2>/dev/null || true
    
    log_info "Configuration files generated"
}

build_container() {
    log_info "Building PXE server container..."
    
    # Build with both quay.io and local tags
    podman build \
        -t "$IMAGE_NAME" \
        -t "$LOCAL_IMAGE_NAME" \
        -f "$SCRIPT_DIR/Containerfile" \
        "$SCRIPT_DIR"
    
    log_info "Container image built successfully!"
    log_info "  Tagged: $IMAGE_NAME"
    log_info "  Tagged: $LOCAL_IMAGE_NAME"
}

save_config() {
    # Save current configuration to a file for later use by pxe-server.sh
    cat > "$CONFIG_DIR/pxe-server.env" << EOF
# PXE Server Configuration
# Generated by setup-pxe-server.sh
PXE_INTERFACE="${PXE_INTERFACE}"
PXE_SERVER_IP="${PXE_SERVER_IP}"
PXE_SUBNET="${PXE_SUBNET}"
PXE_NETMASK="${PXE_NETMASK}"
PXE_ROUTER="${PXE_ROUTER}"
PXE_DNS="${PXE_DNS}"
PXE_DOMAIN="${PXE_DOMAIN}"
PXE_RANGE_START="${PXE_RANGE_START}"
PXE_RANGE_END="${PXE_RANGE_END}"
PXE_VIRTUAL_RANGE_START="${PXE_VIRTUAL_RANGE_START}"
PXE_VIRTUAL_RANGE_END="${PXE_VIRTUAL_RANGE_END}"
EOF
    log_info "Saved configuration to $CONFIG_DIR/pxe-server.env"
}

start_container() {
    log_info "Starting PXE server container..."
    
    # Stop existing container if running
    podman stop "$CONTAINER_NAME" 2>/dev/null || true
    podman rm "$CONTAINER_NAME" 2>/dev/null || true
    
    # Run the container with host networking for DHCP to work properly
    # Pass the interface name so DHCP binds to correct interface
    podman run -d \
        --name "$CONTAINER_NAME" \
        --network=host \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        -e "DHCP_INTERFACE=${PXE_INTERFACE}" \
        -e "PXE_SERVER_IP=${PXE_SERVER_IP}" \
        -v "$TFTP_DIR:/var/lib/tftpboot:Z" \
        -v "$HTTP_DIR:/var/www/html:Z" \
        -v "$CONFIG_DIR/dhcpd.conf:/etc/dhcp/dhcpd.conf:Z" \
        "$IMAGE_NAME"
    
    log_info "PXE server container started: $CONTAINER_NAME"
}

show_status() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  PXE Server Setup Complete!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BLUE}Server IP:${NC}      $PXE_SERVER_IP"
    echo -e "  ${BLUE}Interface:${NC}      $PXE_INTERFACE"
    echo -e "  ${BLUE}Domain:${NC}         $PXE_DOMAIN"
    echo -e "  ${BLUE}Router:${NC}         $PXE_ROUTER"
    echo -e "  ${BLUE}DNS:${NC}            $PXE_DNS"
    echo -e "  ${BLUE}Virtual Pool:${NC}   $PXE_VIRTUAL_RANGE_START - $PXE_VIRTUAL_RANGE_END"
    echo -e "  ${BLUE}PXE Pool:${NC}       $PXE_RANGE_START - $PXE_RANGE_END"
    echo ""
    echo -e "  ${BLUE}Container:${NC}      $CONTAINER_NAME"
    echo -e "  ${BLUE}Status:${NC}         $(podman ps --filter name=$CONTAINER_NAME --format '{{.Status}}' 2>/dev/null || echo 'Unknown')"
    echo ""
    echo -e "  ${YELLOW}To add an ISO for PXE boot:${NC}"
    echo "    $SCRIPT_DIR/extract-iso.sh /path/to/fedora.iso"
    echo ""
    echo -e "  ${YELLOW}Management Commands:${NC}"
    echo "    $SCRIPT_DIR/pxe-server.sh start   - Start the PXE server"
    echo "    $SCRIPT_DIR/pxe-server.sh stop    - Stop the PXE server"
    echo "    $SCRIPT_DIR/pxe-server.sh status  - Show server status"
    echo "    $SCRIPT_DIR/pxe-server.sh logs    - View server logs"
    echo ""
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -i, --interface IFACE   Network interface to use"
    echo "  -s, --server-ip IP      PXE server IP address"
    echo "  -r, --range START END   DHCP PXE client IP range"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  PXE_INTERFACE           Network interface to use"
    echo "  PXE_SERVER_IP           Server IP address (default: 192.168.0.1)"
    echo "  PXE_SUBNET              Subnet (default: 192.168.0.0)"
    echo "  PXE_NETMASK             Netmask (default: 255.255.255.0)"
    echo "  PXE_RANGE_START         PXE client range start (default: 192.168.0.201)"
    echo "  PXE_RANGE_END           PXE client range end (default: 192.168.0.240)"
    echo "  PXE_VIRTUAL_RANGE_START Virtual client range start (default: 192.168.0.101)"
    echo "  PXE_VIRTUAL_RANGE_END   Virtual client range end (default: 192.168.0.140)"
    echo "  PXE_DOMAIN              Domain name (default: example.com)"
    echo ""
    echo "Note: Router and DNS default to PXE_SERVER_IP (single-server setup)"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--interface)
            PXE_INTERFACE="$2"
            shift 2
            ;;
        -s|--server-ip)
            PXE_SERVER_IP="$2"
            shift 2
            ;;
        -r|--range)
            PXE_RANGE_START="$2"
            PXE_RANGE_END="$3"
            shift 3
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Main execution
main() {
    print_header
    check_root
    check_podman
    detect_network
    configure_firewall
    create_directories
    copy_boot_files
    generate_configs
    save_config
    build_container
    start_container
    show_status
}

main "$@"

