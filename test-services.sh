#!/bin/bash
#
# PXE Server Service Test Script
# Tests all containerized services (DHCP, TFTP, HTTP) and displays status
#

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
DATA_DIR="${SCRIPT_DIR}/data"
CONTAINER_NAME="pxe-server"

# Load configuration
if [[ -f "$CONFIG_DIR/pxe-server.env" ]]; then
    source "$CONFIG_DIR/pxe-server.env"
fi

PXE_IP="${PXE_SERVER_IP:-192.168.0.1}"

print_header() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              PXE Server Service Test                          ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    echo -e "${BLUE}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│${NC}  ${CYAN}$1${NC}"
    echo -e "${BLUE}└─────────────────────────────────────────────────────────────┘${NC}"
}

test_pass() {
    echo -e "  ${GREEN}✓${NC} $1"
}

test_fail() {
    echo -e "  ${RED}✗${NC} $1"
}

test_warn() {
    echo -e "  ${YELLOW}!${NC} $1"
}

test_info() {
    echo -e "  ${BLUE}ℹ${NC} $1"
}

# Check if container is running
check_container() {
    print_section "Container Status"
    
    if ! command -v podman &> /dev/null; then
        test_fail "Podman is not installed"
        return 1
    fi
    
    if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
        local state=$(podman inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
        if [[ "$state" == "running" ]]; then
            test_pass "Container '$CONTAINER_NAME' is running"
            local uptime=$(podman inspect --format '{{.State.StartedAt}}' "$CONTAINER_NAME" 2>/dev/null)
            test_info "Started: $uptime"
            return 0
        else
            test_fail "Container '$CONTAINER_NAME' exists but is not running (state: $state)"
            return 1
        fi
    else
        test_fail "Container '$CONTAINER_NAME' does not exist"
        return 1
    fi
}

# Test DHCP service
test_dhcp() {
    print_section "DHCP Server (Port 67/UDP)"
    
    # Check if dhcpd process is running
    if podman exec "$CONTAINER_NAME" pgrep dhcpd &>/dev/null; then
        test_pass "DHCP daemon (dhcpd) is running"
        
        # Get DHCP config details
        local subnet=$(podman exec "$CONTAINER_NAME" grep "^subnet" /etc/dhcp/dhcpd.conf 2>/dev/null | head -1)
        if [[ -n "$subnet" ]]; then
            test_info "Config: $subnet"
        fi
        
        # Check if listening on correct interface
        local listen_info=$(podman exec "$CONTAINER_NAME" cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' | grep -o 'enp[a-z0-9]*')
        if [[ -n "$listen_info" ]]; then
            test_info "Listening on interface: $listen_info"
        fi
        
        # Check lease file
        local lease_count=$(podman exec "$CONTAINER_NAME" wc -l /var/lib/dhcpd/dhcpd.leases 2>/dev/null | awk '{print $1}')
        test_info "Lease file has $lease_count lines"
        
        return 0
    else
        test_fail "DHCP daemon is NOT running"
        
        # Check logs for errors
        echo ""
        test_warn "Recent DHCP errors from logs:"
        podman logs "$CONTAINER_NAME" 2>&1 | grep -i "dhcp\|error\|fail" | tail -5 | while read line; do
            echo "    $line"
        done
        return 1
    fi
}

# Test TFTP service
test_tftp() {
    print_section "TFTP Server (Port 69/UDP)"
    
    # Check if tftpd process is running
    if podman exec "$CONTAINER_NAME" pgrep in.tftpd &>/dev/null; then
        test_pass "TFTP daemon (in.tftpd) is running"
        
        # Check TFTP root directory
        local tftp_files=$(podman exec "$CONTAINER_NAME" ls /var/lib/tftpboot/ 2>/dev/null | wc -l)
        test_info "TFTP root has $tftp_files files/directories"
        
        # Check for boot files
        if podman exec "$CONTAINER_NAME" test -f /var/lib/tftpboot/pxelinux.0 2>/dev/null; then
            test_pass "BIOS bootloader (pxelinux.0) present"
        else
            test_warn "BIOS bootloader (pxelinux.0) not found"
        fi
        
        if podman exec "$CONTAINER_NAME" test -f /var/lib/tftpboot/BOOTX64.EFI 2>/dev/null; then
            test_pass "UEFI bootloader (BOOTX64.EFI) present"
        else
            test_warn "UEFI bootloader (BOOTX64.EFI) not found"
        fi
        
        # Check for kernel/initrd
        local profiles=$(podman exec "$CONTAINER_NAME" find /var/lib/tftpboot -name "vmlinuz" -type f 2>/dev/null)
        if [[ -n "$profiles" ]]; then
            test_pass "Kernel files found:"
            echo "$profiles" | while read f; do
                echo "      $f"
            done
        else
            test_warn "No kernel files found in TFTP root"
        fi
        
        # Test TFTP connectivity (if tftp client available)
        if command -v tftp &> /dev/null; then
            echo ""
            test_info "Testing TFTP connectivity to $PXE_IP..."
            if timeout 2 bash -c "echo 'get pxelinux.cfg/default' | tftp $PXE_IP 69" 2>/dev/null; then
                test_pass "TFTP is accessible from host"
            else
                test_warn "Could not verify TFTP access (may still work for PXE clients)"
            fi
        fi
        
        return 0
    else
        test_fail "TFTP daemon is NOT running"
        return 1
    fi
}

# Test HTTP service
test_http() {
    print_section "HTTP Server (Port 80/TCP)"
    
    # Check if httpd process is running
    if podman exec "$CONTAINER_NAME" pgrep httpd &>/dev/null; then
        test_pass "HTTP daemon (httpd) is running"
        
        # Check HTTP root directory
        local http_files=$(podman exec "$CONTAINER_NAME" find /var/www/html -type f 2>/dev/null | wc -l)
        test_info "HTTP root has $http_files files"
        
        # Check for squashfs
        local squashfs=$(podman exec "$CONTAINER_NAME" find /var/www/html -name "squashfs.img" -type f 2>/dev/null)
        if [[ -n "$squashfs" ]]; then
            test_pass "SquashFS image found:"
            echo "$squashfs" | while read f; do
                local size=$(podman exec "$CONTAINER_NAME" du -h "$f" 2>/dev/null | cut -f1)
                echo "      $f ($size)"
            done
        else
            test_warn "No squashfs.img found in HTTP root"
        fi
        
        # Test HTTP connectivity
        echo ""
        test_info "Testing HTTP connectivity to $PXE_IP..."
        if curl -s -o /dev/null -w "%{http_code}" "http://$PXE_IP/" --connect-timeout 2 | grep -q "200\|403\|301"; then
            test_pass "HTTP server is responding"
            
            # Check if squashfs is accessible
            local profile_dirs=$(podman exec "$CONTAINER_NAME" ls /var/www/html/ 2>/dev/null | head -5)
            for profile in $profile_dirs; do
                if [[ -n "$profile" && "$profile" != "." ]]; then
                    local url="http://$PXE_IP/$profile/squashfs.img"
                    local response=$(curl -s -o /dev/null -w "%{http_code}" "$url" --connect-timeout 2 2>/dev/null)
                    if [[ "$response" == "200" ]]; then
                        test_pass "SquashFS accessible: $url"
                    fi
                fi
            done
        else
            test_fail "HTTP server is NOT responding on $PXE_IP"
        fi
        
        return 0
    else
        test_fail "HTTP daemon is NOT running"
        return 1
    fi
}

# Test network configuration
test_network() {
    print_section "Network Configuration"
    
    # Check host interface
    if [[ -n "$PXE_INTERFACE" ]]; then
        if ip link show "$PXE_INTERFACE" &>/dev/null; then
            local state=$(ip link show "$PXE_INTERFACE" | grep -o "state [A-Z]*" | awk '{print $2}')
            if [[ "$state" == "UP" ]]; then
                test_pass "Interface $PXE_INTERFACE is UP"
            else
                test_fail "Interface $PXE_INTERFACE is $state"
            fi
            
            local ip_addr=$(ip -4 addr show "$PXE_INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+')
            if [[ -n "$ip_addr" ]]; then
                test_pass "IP Address: $ip_addr"
            else
                test_fail "No IPv4 address on $PXE_INTERFACE"
            fi
        else
            test_fail "Interface $PXE_INTERFACE does not exist"
        fi
    else
        test_warn "PXE_INTERFACE not configured"
    fi
    
    # Check if ports are listening
    echo ""
    test_info "Checking port availability..."
    
    if ss -uln | grep -q ":67 "; then
        test_pass "DHCP port 67/UDP is listening"
    else
        test_warn "DHCP port 67/UDP not detected (may be in container namespace)"
    fi
    
    if ss -uln | grep -q ":69 "; then
        test_pass "TFTP port 69/UDP is listening"
    else
        test_warn "TFTP port 69/UDP not detected (may be in container namespace)"
    fi
    
    if ss -tln | grep -q ":80 "; then
        test_pass "HTTP port 80/TCP is listening"
    else
        test_warn "HTTP port 80/TCP not detected"
    fi
}

# Test boot configuration files
test_boot_configs() {
    print_section "Boot Configuration Files"
    
    # Check BIOS config
    if podman exec "$CONTAINER_NAME" test -f /var/lib/tftpboot/pxelinux.cfg/default 2>/dev/null; then
        test_pass "BIOS config (pxelinux.cfg/default) exists"
        local bios_ip=$(podman exec "$CONTAINER_NAME" grep -o 'http://[0-9.]*' /var/lib/tftpboot/pxelinux.cfg/default 2>/dev/null | head -1)
        if [[ -n "$bios_ip" ]]; then
            test_info "BIOS config points to: $bios_ip"
            if [[ "$bios_ip" == "http://$PXE_IP" ]]; then
                test_pass "BIOS config IP matches server IP"
            else
                test_warn "BIOS config IP ($bios_ip) differs from server IP (http://$PXE_IP)"
            fi
        fi
        
        # Check for ip=dhcp
        if podman exec "$CONTAINER_NAME" grep -q "ip=dhcp" /var/lib/tftpboot/pxelinux.cfg/default 2>/dev/null; then
            test_pass "BIOS config has ip=dhcp parameter"
        else
            test_warn "BIOS config missing ip=dhcp parameter"
        fi
    else
        test_fail "BIOS config (pxelinux.cfg/default) not found"
    fi
    
    # Check UEFI config
    if podman exec "$CONTAINER_NAME" test -f /var/lib/tftpboot/efi64/grub.cfg 2>/dev/null; then
        test_pass "UEFI config (efi64/grub.cfg) exists"
        local uefi_ip=$(podman exec "$CONTAINER_NAME" grep -o 'http://[0-9.]*' /var/lib/tftpboot/efi64/grub.cfg 2>/dev/null | head -1)
        if [[ -n "$uefi_ip" ]]; then
            test_info "UEFI config points to: $uefi_ip"
            if [[ "$uefi_ip" == "http://$PXE_IP" ]]; then
                test_pass "UEFI config IP matches server IP"
            else
                test_warn "UEFI config IP ($uefi_ip) differs from server IP (http://$PXE_IP)"
            fi
        fi
        
        # Check for ip=dhcp
        if podman exec "$CONTAINER_NAME" grep -q "ip=dhcp" /var/lib/tftpboot/efi64/grub.cfg 2>/dev/null; then
            test_pass "UEFI config has ip=dhcp parameter"
        else
            test_warn "UEFI config missing ip=dhcp parameter"
        fi
    else
        test_fail "UEFI config (efi64/grub.cfg) not found"
    fi
}

# Show summary
show_summary() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Test Summary${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    local all_pass=true
    
    # Quick service check
    if podman exec "$CONTAINER_NAME" pgrep dhcpd &>/dev/null; then
        echo -e "  ${GREEN}●${NC} DHCP Server:  ${GREEN}Running${NC}"
    else
        echo -e "  ${RED}●${NC} DHCP Server:  ${RED}Not Running${NC}"
        all_pass=false
    fi
    
    if podman exec "$CONTAINER_NAME" pgrep in.tftpd &>/dev/null; then
        echo -e "  ${GREEN}●${NC} TFTP Server:  ${GREEN}Running${NC}"
    else
        echo -e "  ${RED}●${NC} TFTP Server:  ${RED}Not Running${NC}"
        all_pass=false
    fi
    
    if podman exec "$CONTAINER_NAME" pgrep httpd &>/dev/null; then
        echo -e "  ${GREEN}●${NC} HTTP Server:  ${GREEN}Running${NC}"
    else
        echo -e "  ${RED}●${NC} HTTP Server:  ${RED}Not Running${NC}"
        all_pass=false
    fi
    
    echo ""
    echo -e "  ${BLUE}Server IP:${NC}     $PXE_IP"
    echo -e "  ${BLUE}Interface:${NC}     ${PXE_INTERFACE:-unknown}"
    echo -e "  ${BLUE}DHCP Range:${NC}    ${PXE_RANGE_START:-unknown} - ${PXE_RANGE_END:-unknown}"
    echo ""
    
    if [[ "$all_pass" == true ]]; then
        echo -e "  ${GREEN}All services are running. Ready for PXE boot!${NC}"
    else
        echo -e "  ${RED}Some services are not running. Check the details above.${NC}"
    fi
    echo ""
}

# Main
print_header

if ! check_container; then
    echo ""
    echo -e "${RED}Container is not running. Start it with:${NC}"
    echo "  sudo ./pxe-server.sh start"
    exit 1
fi

echo ""
test_network
echo ""
test_dhcp
echo ""
test_tftp
echo ""
test_http
echo ""
test_boot_configs

show_summary


