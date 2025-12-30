#!/bin/bash
#
# DHCP Client Viewer Script
# Shows clients that have connected to the DHCP server and their IP addresses
#

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
CONTAINER_NAME="pxe-server"

# Load configuration
if [[ -f "$CONFIG_DIR/pxe-server.env" ]]; then
    source "$CONFIG_DIR/pxe-server.env"
fi

print_header() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              DHCP Client Connections                          ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -a, --all       Show all leases (including expired)"
    echo "  -w, --watch     Watch for new connections (refresh every 5 seconds)"
    echo "  -r, --raw       Show raw lease file"
    echo "  -h, --help      Show this help"
    echo ""
}

# Check if container is running
check_container() {
    if ! podman container exists "$CONTAINER_NAME" 2>/dev/null; then
        echo -e "${RED}Error: Container '$CONTAINER_NAME' does not exist${NC}"
        echo "Start the PXE server with: sudo ./pxe-server.sh start"
        exit 1
    fi
    
    local state=$(podman inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
    if [[ "$state" != "running" ]]; then
        echo -e "${RED}Error: Container '$CONTAINER_NAME' is not running (state: $state)${NC}"
        echo "Start the PXE server with: sudo ./pxe-server.sh start"
        exit 1
    fi
}

# Parse DHCP leases and display in a table
show_leases() {
    local show_all="$1"
    local current_time=$(date +%s)
    
    # Get lease file content
    local lease_content=$(podman exec "$CONTAINER_NAME" cat /var/lib/dhcpd/dhcpd.leases 2>/dev/null)
    
    if [[ -z "$lease_content" ]]; then
        echo -e "${YELLOW}No DHCP leases found.${NC}"
        echo ""
        echo "Waiting for clients to connect..."
        return
    fi
    
    # Parse leases
    local leases=()
    local current_lease=""
    local in_lease=false
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^lease ]]; then
            in_lease=true
            current_lease="$line"
        elif [[ "$in_lease" == true ]]; then
            current_lease+=$'\n'"$line"
            if [[ "$line" =~ ^\} ]]; then
                in_lease=false
                leases+=("$current_lease")
                current_lease=""
            fi
        fi
    done <<< "$lease_content"
    
    # Count active vs expired
    local active_count=0
    local expired_count=0
    local total_count=${#leases[@]}
    
    # Display header
    echo -e "${BLUE}┌──────────────────┬───────────────────┬─────────────────────┬──────────┐${NC}"
    echo -e "${BLUE}│${NC}  ${CYAN}IP Address${NC}      ${BLUE}│${NC}  ${CYAN}MAC Address${NC}       ${BLUE}│${NC}  ${CYAN}Hostname${NC}            ${BLUE}│${NC}  ${CYAN}Status${NC}  ${BLUE}│${NC}"
    echo -e "${BLUE}├──────────────────┼───────────────────┼─────────────────────┼──────────┤${NC}"
    
    # Track unique clients (by MAC) for deduplication
    declare -A seen_macs
    
    for lease in "${leases[@]}"; do
        # Extract lease details
        local ip=$(echo "$lease" | grep -oP '(?<=lease )\d+\.\d+\.\d+\.\d+')
        local mac=$(echo "$lease" | grep -oP '(?<=hardware ethernet )[a-f0-9:]+' | head -1)
        local hostname=$(echo "$lease" | grep -oP '(?<=client-hostname ")[^"]+' | head -1)
        local ends=$(echo "$lease" | grep -oP '(?<=ends \d )\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}' | head -1)
        local starts=$(echo "$lease" | grep -oP '(?<=starts \d )\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}' | head -1)
        local binding_state=$(echo "$lease" | grep -oP '(?<=binding state )[a-z]+' | head -1)
        
        # Skip if no IP
        [[ -z "$ip" ]] && continue
        
        # Determine if active or expired
        local status="active"
        local status_color="${GREEN}"
        
        if [[ -n "$ends" ]]; then
            local ends_epoch=$(date -d "${ends//// }" +%s 2>/dev/null || echo 0)
            if [[ $ends_epoch -lt $current_time ]]; then
                status="expired"
                status_color="${RED}"
                ((expired_count++))
            else
                status="active"
                status_color="${GREEN}"
                ((active_count++))
            fi
        elif [[ "$binding_state" == "free" ]]; then
            status="free"
            status_color="${YELLOW}"
            ((expired_count++))
        else
            ((active_count++))
        fi
        
        # Skip expired leases unless --all
        if [[ "$show_all" != "true" && "$status" != "active" ]]; then
            continue
        fi
        
        # Skip duplicate MACs (show only most recent)
        if [[ -n "$mac" && -n "${seen_macs[$mac]}" && "$status" != "active" ]]; then
            continue
        fi
        seen_macs[$mac]=1
        
        # Format hostname
        hostname="${hostname:-<unknown>}"
        [[ ${#hostname} -gt 18 ]] && hostname="${hostname:0:15}..."
        
        # Format MAC
        mac="${mac:-<unknown>}"
        
        # Print row
        printf "${BLUE}│${NC}  %-15s ${BLUE}│${NC}  %-16s ${BLUE}│${NC}  %-18s ${BLUE}│${NC}  ${status_color}%-7s${NC} ${BLUE}│${NC}\n" \
            "$ip" "$mac" "$hostname" "$status"
    done
    
    echo -e "${BLUE}└──────────────────┴───────────────────┴─────────────────────┴──────────┘${NC}"
    
    echo ""
    echo -e "  ${GREEN}●${NC} Active: $active_count    ${RED}●${NC} Expired: $expired_count    Total: $total_count"
}

# Show raw lease file
show_raw() {
    echo -e "${BLUE}Raw DHCP Lease File:${NC}"
    echo ""
    podman exec "$CONTAINER_NAME" cat /var/lib/dhcpd/dhcpd.leases 2>/dev/null
}

# Watch mode - refresh every N seconds
watch_mode() {
    local interval=5
    
    echo -e "${YELLOW}Watching for DHCP clients (refresh every ${interval}s). Press Ctrl+C to stop.${NC}"
    echo ""
    
    while true; do
        clear
        print_header
        
        echo -e "${BLUE}Server:${NC} ${PXE_SERVER_IP:-unknown} on ${PXE_INTERFACE:-unknown}"
        echo -e "${BLUE}DHCP Range:${NC} ${PXE_RANGE_START:-unknown} - ${PXE_RANGE_END:-unknown}"
        echo -e "${BLUE}Last Update:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        
        show_leases "false"
        
        echo ""
        echo -e "${YELLOW}Refreshing in ${interval} seconds... (Ctrl+C to stop)${NC}"
        
        sleep $interval
    done
}

# Show recent DHCP activity from logs
show_recent_activity() {
    echo ""
    echo -e "${BLUE}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│${NC}  ${CYAN}Recent DHCP Activity (from logs)${NC}                          ${BLUE}│${NC}"
    echo -e "${BLUE}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    # Get recent DHCP-related log entries
    local dhcp_logs=$(podman logs "$CONTAINER_NAME" 2>&1 | grep -iE "DHCPDISCOVER|DHCPOFFER|DHCPREQUEST|DHCPACK|DHCPNAK" | tail -20)
    
    if [[ -z "$dhcp_logs" ]]; then
        echo "  No recent DHCP activity in logs."
    else
        echo "$dhcp_logs" | while read -r line; do
            if [[ "$line" =~ DHCPDISCOVER ]]; then
                echo -e "  ${YELLOW}→${NC} $line"
            elif [[ "$line" =~ DHCPOFFER ]]; then
                echo -e "  ${BLUE}←${NC} $line"
            elif [[ "$line" =~ DHCPREQUEST ]]; then
                echo -e "  ${CYAN}→${NC} $line"
            elif [[ "$line" =~ DHCPACK ]]; then
                echo -e "  ${GREEN}✓${NC} $line"
            elif [[ "$line" =~ DHCPNAK ]]; then
                echo -e "  ${RED}✗${NC} $line"
            else
                echo "  $line"
            fi
        done
    fi
}

# Main
SHOW_ALL=false
WATCH=false
RAW=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--all)
            SHOW_ALL=true
            shift
            ;;
        -w|--watch)
            WATCH=true
            shift
            ;;
        -r|--raw)
            RAW=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

check_container

if [[ "$WATCH" == true ]]; then
    watch_mode
    exit 0
fi

if [[ "$RAW" == true ]]; then
    show_raw
    exit 0
fi

print_header

echo -e "${BLUE}Server:${NC} ${PXE_SERVER_IP:-unknown} on ${PXE_INTERFACE:-unknown}"
echo -e "${BLUE}DHCP Range:${NC} ${PXE_RANGE_START:-unknown} - ${PXE_RANGE_END:-unknown}"
echo ""

show_leases "$SHOW_ALL"

show_recent_activity

echo ""
echo -e "${CYAN}Options:${NC}"
echo "  $0 --all     Show all leases including expired"
echo "  $0 --watch   Watch for new connections (live update)"
echo "  $0 --raw     Show raw lease file"
echo ""


