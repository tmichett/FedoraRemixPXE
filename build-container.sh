#!/bin/bash
#
# Build and Push Container Script
# Builds the PXE server container and optionally pushes to quay.io
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Container registry configuration
REGISTRY="quay.io"
NAMESPACE="tmichett"
IMAGE_NAME="fedoraremixpxe"
FULL_IMAGE_NAME="${REGISTRY}/${NAMESPACE}/${IMAGE_NAME}"

# Also tag as localhost for local use
LOCAL_IMAGE_NAME="localhost/${IMAGE_NAME}:latest"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           Fedora Remix PXE Server Container Build            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

get_version() {
    # Get version from git tag, commit, or default
    local version=""
    
    if git describe --tags --exact-match 2>/dev/null; then
        version=$(git describe --tags --exact-match 2>/dev/null)
    elif git rev-parse --short HEAD 2>/dev/null; then
        version=$(git rev-parse --short HEAD 2>/dev/null)
    else
        version="latest"
    fi
    
    echo "$version"
}

build() {
    local version="${1:-latest}"
    
    log_info "Building container image..."
    log_info "  Image: ${FULL_IMAGE_NAME}:${version}"
    
    cd "$SCRIPT_DIR"
    
    # Build with multiple tags
    podman build \
        -t "${FULL_IMAGE_NAME}:${version}" \
        -t "${FULL_IMAGE_NAME}:latest" \
        -t "${LOCAL_IMAGE_NAME}" \
        -f Containerfile \
        .
    
    log_info "Container image built successfully!"
    echo ""
    log_info "Tagged images:"
    echo "  - ${FULL_IMAGE_NAME}:${version}"
    echo "  - ${FULL_IMAGE_NAME}:latest"
    echo "  - ${LOCAL_IMAGE_NAME}"
}

push() {
    local version="${1:-latest}"
    
    log_info "Pushing container image to ${REGISTRY}..."
    
    # Check if logged in to registry
    if ! podman login --get-login "${REGISTRY}" &>/dev/null; then
        log_warn "Not logged in to ${REGISTRY}"
        log_info "Please log in to continue:"
        podman login "${REGISTRY}"
    fi
    
    # Push both version tag and latest
    log_info "Pushing ${FULL_IMAGE_NAME}:${version}..."
    podman push "${FULL_IMAGE_NAME}:${version}"
    
    if [[ "$version" != "latest" ]]; then
        log_info "Pushing ${FULL_IMAGE_NAME}:latest..."
        podman push "${FULL_IMAGE_NAME}:latest"
    fi
    
    log_info "Container image pushed successfully!"
    echo ""
    log_info "Image available at:"
    echo "  - ${FULL_IMAGE_NAME}:${version}"
    echo "  - ${FULL_IMAGE_NAME}:latest"
}

build_and_push() {
    local version="${1:-$(get_version)}"
    
    build "$version"
    echo ""
    push "$version"
}

list_images() {
    log_info "Local images for ${IMAGE_NAME}:"
    podman images | grep -E "(${FULL_IMAGE_NAME}|${IMAGE_NAME})" || echo "  No images found"
}

clean() {
    log_info "Removing local images..."
    
    podman rmi "${FULL_IMAGE_NAME}:latest" 2>/dev/null || true
    podman rmi "${LOCAL_IMAGE_NAME}" 2>/dev/null || true
    
    # Remove dangling images
    podman image prune -f
    
    log_info "Cleanup complete"
}

usage() {
    echo "Usage: $0 <command> [version]"
    echo ""
    echo "Commands:"
    echo "  build [version]    Build the container image (default: latest)"
    echo "  push [version]     Push the container image to ${REGISTRY}"
    echo "  all [version]      Build and push the container image"
    echo "  list               List local container images"
    echo "  clean              Remove local container images"
    echo "  login              Log in to ${REGISTRY}"
    echo ""
    echo "Examples:"
    echo "  $0 build                    # Build with 'latest' tag"
    echo "  $0 build v1.0.0             # Build with specific version"
    echo "  $0 all                      # Build and push with auto-detected version"
    echo "  $0 push v1.0.0              # Push specific version"
    echo ""
    echo "Container Image: ${FULL_IMAGE_NAME}"
}

# Main
print_header

case "${1:-}" in
    build)
        build "${2:-latest}"
        ;;
    push)
        push "${2:-latest}"
        ;;
    all)
        build_and_push "${2:-}"
        ;;
    list)
        list_images
        ;;
    clean)
        clean
        ;;
    login)
        podman login "${REGISTRY}"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac



