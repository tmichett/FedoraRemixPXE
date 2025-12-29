#!/bin/bash
#
# PXE Server Management Script
# Start, stop, and manage the containerized PXE server
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
DATA_DIR="${SCRIPT_DIR}/data"
TFTP_DIR="${DATA_DIR}/tftpboot"
HTTP_DIR="${DATA_DIR}/http"
CONTAINER_NAME="pxe-server"
IMAGE_NAME="quay.io/tmichett/fedoraremixpxe:latest"
LOCAL_IMAGE_NAME="localhost/fedoraremixpxe:latest"

# Load saved configuration if available
if [[ -f "$CONFIG_DIR/pxe-server.env" ]]; then
    source "$CONFIG_DIR/pxe-server.env"
fi

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

start() {
    log_info "Starting PXE server..."
    
    # Check for saved configuration
    if [[ -z "$PXE_INTERFACE" ]]; then
        log_warn "No saved configuration found. Run setup-pxe-server.sh first."
        log_warn "Attempting to start without interface binding..."
    fi
    
    # Check if container exists but is stopped
    if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
        podman start "$CONTAINER_NAME"
    else
        # Determine which image to use (prefer local, fallback to registry)
        local use_image=""
        if podman image exists "$LOCAL_IMAGE_NAME" 2>/dev/null; then
            use_image="$LOCAL_IMAGE_NAME"
            log_info "Using local image: $use_image"
        elif podman image exists "$IMAGE_NAME" 2>/dev/null; then
            use_image="$IMAGE_NAME"
            log_info "Using image: $use_image"
        else
            # Try to pull from registry
            log_info "Image not found locally, pulling from registry..."
            if podman pull "$IMAGE_NAME" 2>/dev/null; then
                use_image="$IMAGE_NAME"
            else
                log_error "Container image not found. Please run:"
                log_error "  ./setup-pxe-server.sh   (to build locally)"
                log_error "  or"
                log_error "  podman pull $IMAGE_NAME"
                exit 1
            fi
        fi
        
        # Build environment variable arguments
        local env_args=""
        [[ -n "$PXE_INTERFACE" ]] && env_args="$env_args -e DHCP_INTERFACE=${PXE_INTERFACE}"
        [[ -n "$PXE_SERVER_IP" ]] && env_args="$env_args -e PXE_SERVER_IP=${PXE_SERVER_IP}"
        
        podman run -d \
            --name "$CONTAINER_NAME" \
            --network=host \
            --cap-add=NET_ADMIN \
            --cap-add=NET_RAW \
            $env_args \
            -v "$TFTP_DIR:/var/lib/tftpboot:Z" \
            -v "$HTTP_DIR:/var/www/html:Z" \
            -v "$CONFIG_DIR/dhcpd.conf:/etc/dhcp/dhcpd.conf:Z" \
            "$use_image"
    fi
    
    log_info "PXE server started"
    status
}

stop() {
    log_info "Stopping PXE server..."
    
    if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
        podman stop "$CONTAINER_NAME" 2>/dev/null || true
        log_info "PXE server stopped"
    else
        log_warn "PXE server container not found"
    fi
}

restart() {
    log_info "Restarting PXE server..."
    stop
    sleep 2
    start
}

status() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  PXE Server Status${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
        local state=$(podman inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
        
        case "$state" in
            running)
                echo -e "  ${GREEN}●${NC} Container: ${GREEN}Running${NC}"
                ;;
            paused)
                echo -e "  ${YELLOW}●${NC} Container: ${YELLOW}Paused${NC}"
                ;;
            exited)
                echo -e "  ${RED}●${NC} Container: ${RED}Stopped${NC}"
                ;;
            *)
                echo -e "  ${YELLOW}●${NC} Container: ${YELLOW}$state${NC}"
                ;;
        esac
        
        echo ""
        echo -e "  ${BLUE}Container Details:${NC}"
        podman ps -a --filter name="$CONTAINER_NAME" --format "    ID: {{.ID}}\n    Image: {{.Image}}\n    Status: {{.Status}}\n    Created: {{.Created}}"
        
        if [[ "$state" == "running" ]]; then
            echo ""
            echo -e "  ${BLUE}Services:${NC}"
            
            # Check DHCP
            if podman exec "$CONTAINER_NAME" pgrep dhcpd &>/dev/null; then
                echo -e "    ${GREEN}●${NC} DHCP Server (dhcpd)"
            else
                echo -e "    ${RED}●${NC} DHCP Server (dhcpd)"
            fi
            
            # Check TFTP
            if podman exec "$CONTAINER_NAME" pgrep in.tftpd &>/dev/null; then
                echo -e "    ${GREEN}●${NC} TFTP Server (in.tftpd)"
            else
                echo -e "    ${RED}●${NC} TFTP Server (in.tftpd)"
            fi
            
            # Check HTTP
            if podman exec "$CONTAINER_NAME" pgrep httpd &>/dev/null; then
                echo -e "    ${GREEN}●${NC} HTTP Server (httpd)"
            else
                echo -e "    ${RED}●${NC} HTTP Server (httpd)"
            fi
        fi
    else
        echo -e "  ${RED}●${NC} Container: ${RED}Not Created${NC}"
        echo ""
        echo -e "  Run ${YELLOW}setup-pxe-server.sh${NC} to create and start the PXE server."
    fi
    
    # Show boot image status
    echo ""
    echo -e "  ${BLUE}Boot Images:${NC}"
    if [[ -f "$TFTP_DIR/livecd/vmlinuz" ]] && [[ -f "$TFTP_DIR/livecd/initrd.img" ]]; then
        echo -e "    ${GREEN}●${NC} Kernel and initrd available"
    else
        echo -e "    ${YELLOW}●${NC} No kernel/initrd found - run extract-iso.sh"
    fi
    
    if [[ -f "$HTTP_DIR/livecd/squashfs.img" ]]; then
        local size=$(du -h "$HTTP_DIR/livecd/squashfs.img" 2>/dev/null | cut -f1)
        echo -e "    ${GREEN}●${NC} SquashFS image available ($size)"
    else
        echo -e "    ${YELLOW}●${NC} No squashfs image found - run extract-iso.sh"
    fi
    
    echo ""
}

logs() {
    local follow=""
    local lines="100"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--follow)
                follow="-f"
                shift
                ;;
            -n|--lines)
                lines="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    
    if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
        podman logs $follow --tail "$lines" "$CONTAINER_NAME"
    else
        log_error "Container not found"
        exit 1
    fi
}

shell() {
    if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
        local state=$(podman inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
        if [[ "$state" == "running" ]]; then
            podman exec -it "$CONTAINER_NAME" /bin/bash
        else
            log_error "Container is not running"
            exit 1
        fi
    else
        log_error "Container not found"
        exit 1
    fi
}

rebuild() {
    log_info "Rebuilding PXE server container image..."
    
    # Stop and remove existing container
    stop
    podman rm "$CONTAINER_NAME" 2>/dev/null || true
    
    # Rebuild image
    podman build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"
    
    log_info "Container image rebuilt successfully"
    log_info "Run '$0 start' to start the new container"
}

destroy() {
    log_warn "This will stop and remove the PXE server container."
    read -p "Are you sure? [y/N]: " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        stop
        podman rm "$CONTAINER_NAME" 2>/dev/null || true
        log_info "PXE server container removed"
    else
        log_info "Cancelled"
    fi
}

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  start      Start the PXE server container"
    echo "  stop       Stop the PXE server container"
    echo "  restart    Restart the PXE server container"
    echo "  status     Show PXE server status"
    echo "  logs       View container logs"
    echo "             Options: -f (follow), -n <lines>"
    echo "  shell      Open a shell in the container"
    echo "  rebuild    Rebuild the container image"
    echo "  destroy    Remove the container"
    echo ""
    echo "Examples:"
    echo "  $0 start"
    echo "  $0 logs -f"
    echo "  $0 status"
}

# Main
case "${1:-}" in
    start)
        check_root
        start
        ;;
    stop)
        check_root
        stop
        ;;
    restart)
        check_root
        restart
        ;;
    status)
        status
        ;;
    logs)
        shift
        logs "$@"
        ;;
    shell)
        shell
        ;;
    rebuild)
        check_root
        rebuild
        ;;
    destroy)
        check_root
        destroy
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac

