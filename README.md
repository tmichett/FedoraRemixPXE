# Fedora Remix PXE Server

A containerized PXE boot server for network booting Fedora Remix LiveCDs and other Linux distributions. This project provides an easy-to-deploy solution using Podman containers.

**Container Image:** `quay.io/tmichett/fedoraremixpxe`

## Features

- **Containerized Design**: All services run in a single Podman container
- **Full PXE Stack**: Includes DHCP, TFTP, and HTTP servers
- **BIOS & UEFI Support**: Works with both legacy BIOS and modern UEFI systems
- **Easy ISO Extraction**: Simple script to prepare LiveCD ISOs for PXE boot
- **Firewall Ready**: Automatic firewall configuration for Fedora systems
- **Registry Published**: Pre-built images available on quay.io

## Quick Start

### Prerequisites

- Fedora Linux (or compatible distribution)
- Podman installed (`sudo dnf install podman`)
- Root access for network configuration
- A Fedora LiveCD ISO file

### Installation

1. **Clone the repository:**
   ```bash
   cd ~/Github
   git clone https://github.com/tmichett/FedoraRemixPXE.git
   cd FedoraRemixPXE
   ```

2. **Run the setup script:**
   ```bash
   sudo ./setup-pxe-server.sh
   ```
   
   The script will:
   - Detect your network interface and IP
   - Configure firewall rules
   - Build the PXE server container
   - Start the container with all services

3. **Extract an ISO for PXE boot:**
   ```bash
   sudo ./extract-iso.sh /path/to/Fedora-Live.iso
   ```

4. **Boot a client via PXE!**

## Directory Structure

```
FedoraRemixPXE/
├── setup-pxe-server.sh    # Initial setup and configuration
├── pxe-server.sh          # Server management (start/stop/status)
├── extract-iso.sh         # ISO extraction utility
├── build-container.sh     # Build and push container to registry
├── Containerfile          # Container image definition
├── config/                # Configuration files
│   └── dhcpd.conf         # DHCP server configuration (generated)
└── data/                  # Runtime data
    ├── tftpboot/          # TFTP root (kernel, initrd, boot files)
    │   ├── pxelinux.cfg/  # BIOS PXE menu configuration
    │   ├── efi64/         # UEFI boot files and GRUB config
    │   └── livecd/        # Extracted kernel/initrd
    └── http/              # HTTP server root
        └── livecd/        # SquashFS images served via HTTP
```

## Container Registry

The container image is published to **quay.io/tmichett/fedoraremixpxe**.

### Using Pre-built Image

```bash
# Pull the latest image
podman pull quay.io/tmichett/fedoraremixpxe:latest

# Run setup (will use the pulled image)
sudo ./setup-pxe-server.sh
```

### Building and Pushing

```bash
# Build the container locally
./build-container.sh build

# Build with a specific version tag
./build-container.sh build v1.0.0

# Log in to quay.io
./build-container.sh login

# Build and push to registry
./build-container.sh all

# Push a specific version
./build-container.sh push v1.0.0
```

## Usage

### Server Management

```bash
# Start the PXE server
sudo ./pxe-server.sh start

# Stop the PXE server
sudo ./pxe-server.sh stop

# Restart the PXE server
sudo ./pxe-server.sh restart

# Check server status
./pxe-server.sh status

# View server logs
./pxe-server.sh logs

# Follow logs in real-time
./pxe-server.sh logs -f

# Open a shell in the container
sudo ./pxe-server.sh shell

# Rebuild the container after changes
sudo ./pxe-server.sh rebuild
```

### Adding Boot Images

To add a new ISO for PXE boot:

```bash
# Extract with default profile name 'livecd'
sudo ./extract-iso.sh /path/to/Fedora-Workstation-Live.iso

# Extract with custom profile name
sudo ./extract-iso.sh /path/to/Fedora-Server.iso fedora-server
```

The extraction script automatically finds and copies:
- `vmlinuz` (kernel) → `data/tftpboot/<profile>/`
- `initrd.img` → `data/tftpboot/<profile>/`
- `squashfs.img` → `data/http/<profile>/`

## Configuration

### Default Network Settings

The PXE server acts as a single-server setup where one machine provides all services:

| Setting | Default Value |
|---------|---------------|
| **PXE Server IP** | 192.168.0.1 |
| **Router/Gateway** | 192.168.0.1 (same as server) |
| **DNS Server** | 192.168.0.1 (same as server) |
| **Domain** | example.com |
| **Virtual Pool** | 192.168.0.101 - 192.168.0.140 |
| **PXE Client Pool** | 192.168.0.201 - 192.168.0.240 |

The setup script will:
1. Detect available network interfaces
2. Check/configure the static IP on the selected interface
3. Bind DHCP to the specific interface for proper operation

### Custom Network Settings

The setup script accepts environment variables for customization:

```bash
# Custom network configuration
sudo PXE_INTERFACE=eth0 \
     PXE_SERVER_IP=192.168.1.1 \
     PXE_SUBNET=192.168.1.0 \
     PXE_NETMASK=255.255.255.0 \
     PXE_RANGE_START=192.168.1.201 \
     PXE_RANGE_END=192.168.1.240 \
     PXE_VIRTUAL_RANGE_START=192.168.1.101 \
     PXE_VIRTUAL_RANGE_END=192.168.1.140 \
     PXE_DOMAIN=mynetwork.local \
     ./setup-pxe-server.sh
```

Or use command-line options:

```bash
sudo ./setup-pxe-server.sh -i eth0 -s 192.168.0.1 -r 192.168.0.201 192.168.0.240
```

**Note:** Router and DNS automatically use the PXE_SERVER_IP (single-server setup).

### DHCP Configuration

The DHCP configuration is generated in `config/dhcpd.conf`. The configuration includes:

- **Virtual client pool** (192.168.0.101-140): For VMs with recognized MAC prefixes (KVM, Xen, etc.)
- **PXE client pool** (192.168.0.201-240): For physical machines booting via PXE

You can edit this file directly and restart the server:

```bash
# Edit configuration
sudo nano config/dhcpd.conf

# Restart to apply changes
sudo ./pxe-server.sh restart
```

See `config/dhcpd.conf.template` for configuration examples.

### Boot Menu Customization

**BIOS (PXELinux):** Edit `data/tftpboot/pxelinux.cfg/default`

**UEFI (GRUB):** Edit `data/tftpboot/efi64/grub.cfg`

Example menu entry for a custom ISO:

```
# PXELinux format (BIOS)
LABEL fedora-custom
    MENU LABEL ^Boot Custom Fedora
    KERNEL custom/vmlinuz
    APPEND initrd=custom/initrd.img root=live:http://192.168.0.1/custom/squashfs.img ro rd.live.image

# GRUB format (UEFI)
menuentry "Boot Custom Fedora" {
    linuxefi custom/vmlinuz root=live:http://192.168.0.1/custom/squashfs.img ro rd.live.image
    initrdefi custom/initrd.img
}
```

## Network Requirements

### Firewall Ports

The following ports must be open on the PXE server:

| Port | Protocol | Service |
|------|----------|---------|
| 67   | UDP      | DHCP Server |
| 68   | UDP      | DHCP Client |
| 69   | UDP      | TFTP |
| 80   | TCP      | HTTP |
| 4011 | UDP      | PXE Proxy DHCP (optional) |

The setup script automatically configures `firewalld` if it's running.

### Existing DHCP Server

If you have an existing DHCP server on your network, you have two options:

1. **Disable DHCP in this container** and configure your existing DHCP server with PXE options:
   ```
   next-server <PXE_SERVER_IP>;
   filename "pxelinux.0";  # For BIOS
   # or
   filename "efi64/BOOTX64.EFI";  # For UEFI
   ```

2. **Use a separate network/VLAN** for PXE booting

## Troubleshooting

### Common Issues

**Client doesn't get IP address:**
- Check that DHCP is running: `./pxe-server.sh status`
- Verify firewall rules: `sudo firewall-cmd --list-all`
- Check for conflicting DHCP servers on the network

**Client gets IP but doesn't boot:**
- Check TFTP is accessible: `tftp <server-ip> -c get pxelinux.0`
- Verify boot files exist in `data/tftpboot/`
- Check container logs: `./pxe-server.sh logs`

**UEFI client fails to boot:**
- Ensure `BOOTX64.EFI` and `grubx64.efi` exist in `data/tftpboot/efi64/`
- Check that Secure Boot is disabled on the client

**LiveCD fails to load:**
- Verify squashfs is accessible: `curl http://<server-ip>/livecd/squashfs.img -I`
- Check HTTP server is running: `./pxe-server.sh status`
- Ensure sufficient memory on client (4GB+ recommended)

### Viewing Logs

```bash
# All container logs
./pxe-server.sh logs

# Follow logs in real-time
./pxe-server.sh logs -f

# Just DHCP activity
./pxe-server.sh logs | grep -i dhcp
```

### Testing TFTP

```bash
# Test TFTP access from another machine
tftp <pxe-server-ip> -c get pxelinux.0
ls -la pxelinux.0
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     PXE Server Container                     │
│                                                              │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│  │   DHCP   │    │   TFTP   │    │   HTTP   │              │
│  │  Server  │    │  Server  │    │  Server  │              │
│  │ (dhcpd)  │    │(in.tftpd)│    │ (httpd)  │              │
│  └────┬─────┘    └────┬─────┘    └────┬─────┘              │
│       │               │               │                     │
│       │  Port 67/68   │  Port 69      │  Port 80           │
└───────┼───────────────┼───────────────┼─────────────────────┘
        │               │               │
        ▼               ▼               ▼
   ┌─────────────────────────────────────────────────────┐
   │                    Host Network                      │
   └─────────────────────────────────────────────────────┘
                            │
                            ▼
   ┌─────────────────────────────────────────────────────┐
   │                     PXE Client                       │
   │                                                      │
   │   1. DHCP Request → Get IP + Boot Server Info       │
   │   2. TFTP Download → Get kernel + initrd            │
   │   3. HTTP Download → Get squashfs root filesystem   │
   │   4. Boot into LiveCD environment                   │
   └─────────────────────────────────────────────────────┘
```

## License

This project is provided as-is for educational and personal use.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.
