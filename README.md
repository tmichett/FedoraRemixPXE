# Fedora Remix PXE Server

A containerized PXE boot server for network booting Fedora Remix LiveCDs and other Linux distributions. This project provides an easy-to-deploy solution using Podman containers.

**Container Image:** `quay.io/tmichett/fedoraremixpxe`

## Features

- **Single-Script Launcher**: One Python script handles everything - download, setup, extraction, and management
- **Containerized Design**: All services run in a single Podman container
- **Full PXE Stack**: Includes DHCP, TFTP, and HTTP servers
- **BIOS & UEFI Support**: Works with both legacy BIOS and modern UEFI systems
- **ISO and USB Extraction**: Extract boot files from ISO files or mounted USB drives
- **Built-in Diagnostics**: Network diagnostic script available via boot menu and HTTP
- **Firewall Ready**: Automatic firewall configuration for Fedora systems
- **Registry Published**: Pre-built images available on quay.io
- **LiveCD Integration**: Pre-installed on Fedora Remix LiveCD with container pre-cached

## Fedora Remix LiveCD Integration

If you're using the **Fedora Remix LiveCD**, the PXE server tools are already installed and ready to use!

### Pre-installed Components

| Location | Contents |
|----------|----------|
| `/opt/FedoraRemixPXETools/` | PXE server scripts |
| `/usr/local/bin/` | Symlinks for easy access |
| Root's container storage | Pre-cached container image |

### Available Commands (on LiveCD)

```bash
# Launch the PXE server (interactive setup)
sudo run-pxe-server

# Show connected DHCP clients
sudo show-dhcp-clients

# Test PXE server services
sudo test-pxe-services
```

The container image is **pre-cached**, so the PXE server starts immediately without downloading anything!

### Kickstart Snippets (for LiveCD builders)

If you're building your own Fedora Remix LiveCD, include these kickstart snippets:

```kickstart
## Download PXE tools from GitHub
%include KickstartSnippets/install-fedoraremix-pxe.ks

## Pre-cache the container image (optional, adds ~500MB to ISO)
%include KickstartSnippets/pull-pxe-container.ks
```

The snippets are available in the [Fedora_Remix repository](https://github.com/tmichett/Fedora_Remix).

---

## Quick Start (Standalone Installation)

For systems without the pre-installed tools:

```bash
# Download and run the launcher (requires root)
sudo ./run-pxe-server.py
```

The launcher will:
1. Download the container image if needed
2. Guide you through network configuration
3. Configure firewall rules automatically
4. Ask if you want to extract from ISO or USB
5. Start the PXE server with all services

### Launcher Commands

```bash
# Interactive setup and start
sudo ./run-pxe-server.py

# Check server status
./run-pxe-server.py --status

# View container logs
./run-pxe-server.py --logs

# Open shell in container
sudo ./run-pxe-server.py --shell

# Stop the server
sudo ./run-pxe-server.py --stop
```

## Alternative: Manual Setup

If you prefer more control, use the individual scripts:

### Prerequisites

- Fedora Linux (or compatible distribution)
- Podman installed (`sudo dnf install podman`)
- Root access for network configuration
- A Fedora LiveCD ISO file or mounted USB drive

### Installation

1. **Clone the repository:**
   ```bash
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

3. **Extract boot files from ISO or USB:**
   ```bash
   # From ISO
   sudo ./extract-iso.sh /path/to/Fedora-Live.iso
   
   # From mounted USB (auto-detects "FedoraRemix" label)
   sudo ./extract-usb.sh
   
   # From specific USB path
   sudo ./extract-usb.sh /run/media/user/MyUSB
   ```

4. **Boot a client via PXE!**

## Directory Structure

```
FedoraRemixPXE/
├── run-pxe-server.py      # Single-script launcher (recommended)
├── setup-pxe-server.sh    # Manual setup and configuration
├── pxe-server.sh          # Server management (start/stop/status)
├── extract-iso.sh         # ISO extraction utility
├── extract-usb.sh         # USB extraction utility
├── build-container.sh     # Build and push container to registry
├── test-services.sh       # Test containerized services
├── show-dhcp-clients.sh   # Show connected DHCP clients
├── pxe-initrd-diag.sh     # Initrd diagnostics (also in container)
├── Containerfile          # Container image definition
├── config/                # Configuration files
│   ├── dhcpd.conf         # DHCP server configuration (generated)
│   ├── dhcpd.conf.template # DHCP template with examples
│   └── pxe-server.env     # Saved environment variables
└── data/                  # Runtime data
    ├── tftpboot/          # TFTP root (kernel, initrd, boot files)
    │   ├── pxelinux.cfg/  # BIOS PXE menu configuration
    │   ├── efi64/         # UEFI boot files and GRUB config
    │   └── <profile>/     # Extracted kernel/initrd per profile
    └── http/              # HTTP server root
        ├── <profile>/     # SquashFS images served via HTTP
        └── diag/          # Diagnostic scripts
```

### LiveCD Installation Structure

When installed via kickstart on a LiveCD:

```
/opt/FedoraRemixPXETools/
├── run-pxe-server.py      # Main launcher script
├── show-dhcp-clients.sh   # DHCP client viewer
└── test-services.sh       # Service tester

/usr/local/bin/
├── run-pxe-server         # Symlink → run-pxe-server.py
├── show-dhcp-clients      # Symlink → show-dhcp-clients.sh
└── test-pxe-services      # Symlink → test-services.sh
```

## Container Registry

The container image is published to **quay.io/tmichett/fedoraremixpxe**.

### Using Pre-built Image

```bash
# Pull the latest image
podman pull quay.io/tmichett/fedoraremixpxe:latest

# Or just run the launcher - it pulls automatically
sudo ./run-pxe-server.py
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

#### From ISO File:

```bash
# Interactive mode - prompts for IP, profile name, and menu label
sudo ./extract-iso.sh /path/to/Fedora-Workstation-Live.iso

# Non-interactive mode
sudo ./extract-iso.sh -i 192.168.0.1 -p fedora43 -l "Fedora 43 Remix" -y /path/to/iso
```

#### From Mounted USB:

```bash
# Auto-detect "FedoraRemix" labeled USB
sudo ./extract-usb.sh

# Specify USB path or label
sudo ./extract-usb.sh /run/media/user/FedoraRemix

# Non-interactive mode
sudo ./extract-usb.sh -i 192.168.0.1 -p fedora43 -l "Fedora 43 Remix" -y
```

The extraction scripts automatically find and copy:
- `vmlinuz` (kernel) → `data/tftpboot/<profile>/`
- `initrd.img` → `data/tftpboot/<profile>/`
- `squashfs.img` → `data/http/<profile>/`

And generate boot menu configurations for both BIOS and UEFI.

## Boot Menu Options

After extraction, the PXE boot menu includes:

| Option | Description |
|--------|-------------|
| **Boot from local drive** | Continue to local boot (default) |
| **<Profile Name>** | Boot the LiveCD normally |
| **<Profile Name> (DHCP fallback)** | Use DHCP for kernel network (UEFI only) |
| **<Profile Name> (Debug Mode)** | Boot into initrd shell (rd.break) |
| **Network Diagnostics** | Boot to initrd shell with network for debugging |

## Diagnostics

### Built-in Diagnostic Script

The container includes a diagnostic script accessible via HTTP:

```bash
# From the PXE client's initrd shell (rd.break):
curl -s http://192.168.0.1/diag/pxe-initrd-diag.sh | bash
```

This script checks:
- Kernel command line
- Network interfaces and IP addresses
- NetworkManager status
- DHCP client status
- Connectivity to the PXE server

### Test Services

```bash
# Test all containerized services
sudo ./test-services.sh
# Or on LiveCD:
sudo test-pxe-services

# Show DHCP clients
sudo ./show-dhcp-clients.sh
# Or on LiveCD:
sudo show-dhcp-clients

# Watch DHCP activity in real-time
sudo show-dhcp-clients --watch
```

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
1. Detect available network interfaces (excluding wireless/virtual)
2. Display a table with interface status and IP addresses
3. Let you select and configure the static IP on the interface
4. Configure firewall rules (DHCP, TFTP, HTTP, DNS)
5. Bind DHCP to the specific interface for proper operation

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
    APPEND initrd=custom/initrd.img root=live:http://192.168.0.1/custom/squashfs.img ro rd.live.image rd.neednet=1 ip=dhcp
    IPAPPEND 2

# GRUB format (UEFI)
menuentry "Boot Custom Fedora" {
    linuxefi custom/vmlinuz root=live:http://192.168.0.1/custom/squashfs.img ro rd.live.image rd.neednet=1 ip=${myip}::${mygateway}:255.255.255.0:pxeclient::none nameserver=192.168.0.1
    initrdefi custom/initrd.img
}
```

## Network Requirements

### Firewall Ports

The following ports are automatically configured by the launcher:

| Port | Protocol | Service |
|------|----------|---------|
| 53   | UDP/TCP  | DNS |
| 67   | UDP      | DHCP Server |
| 68   | UDP      | DHCP Client |
| 69   | UDP      | TFTP |
| 80   | TCP      | HTTP |
| 4011 | UDP      | PXE Proxy DHCP (optional) |

The `run-pxe-server.py` script automatically configures `firewalld` if it's running.

### Existing DHCP Server

If you have an existing DHCP server on your network, you have two options:

1. **Disable DHCP in this container** and configure your existing DHCP server with PXE options:
   ```
   next-server <PXE_SERVER_IP>;
   filename "pxelinux.0";  # For BIOS
   # or
   filename "BOOTX64.EFI";  # For UEFI
   ```

2. **Use a separate network/VLAN** for PXE booting

## Troubleshooting

### Common Issues

**Client doesn't get IP address:**
- Check that DHCP is running: `./pxe-server.sh status`
- Verify firewall rules: `sudo firewall-cmd --list-all`
- Check for conflicting DHCP servers on the network
- View DHCP activity: `sudo show-dhcp-clients --watch`

**Client gets IP but doesn't boot:**
- Check TFTP is accessible: `tftp <server-ip> -c get pxelinux.0`
- Verify boot files exist in `data/tftpboot/`
- Check container logs: `./pxe-server.sh logs`

**UEFI client fails to boot:**
- Ensure `BOOTX64.EFI` and `grubx64.efi` exist in `data/tftpboot/efi64/`
- Check that Secure Boot is disabled on the client
- Try the TFTP root copy: `data/tftpboot/BOOTX64.EFI`

**LiveCD fails to load (squashfs.img not found):**
- Verify squashfs is accessible: `curl http://<server-ip>/<profile>/squashfs.img -I`
- Check HTTP server is running: `./pxe-server.sh status`
- Ensure sufficient memory on client (4GB+ recommended)
- Use the Debug Mode boot option to check network in initrd shell
- The UEFI menu passes the GRUB-obtained IP to the kernel to prevent IP loss

**Client loses network after GRUB menu:**
- This is a known issue with network handoff from PXE/GRUB to the kernel
- The boot configs now pass the static IP from GRUB to the kernel
- Try the "DHCP fallback" option if the static IP method doesn't work
- Use Debug Mode to run diagnostics: `curl -s http://<server>/diag/pxe-initrd-diag.sh | bash`

### Viewing Logs

```bash
# All container logs
./pxe-server.sh logs

# Follow logs in real-time
./pxe-server.sh logs -f

# Just DHCP activity
./pxe-server.sh logs | grep -i dhcp

# Test services
sudo test-pxe-services
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
   ┌─────────────────────────────────────────────────────────┐
   │                    Host Network                          │
   └─────────────────────────────────────────────────────────┘
                            │
                            ▼
   ┌─────────────────────────────────────────────────────────┐
   │                     PXE Client                           │
   │                                                          │
   │   1. DHCP Request → Get IP + Boot Server Info           │
   │   2. TFTP Download → Get bootloader (GRUB/pxelinux)     │
   │   3. TFTP Download → Get kernel + initrd                │
   │   4. HTTP Download → Get squashfs root filesystem       │
   │   5. Boot into LiveCD environment                       │
   └─────────────────────────────────────────────────────────┘
```

## Container Contents

The container image includes:

- **DHCP Server** (dhcpd) - Assigns IP addresses and PXE boot info
- **TFTP Server** (in.tftpd) - Serves bootloaders, kernel, and initrd
- **HTTP Server** (httpd) - Serves large root filesystem images
- **PXELinux/Syslinux** - BIOS bootloader files
- **Shim/GRUB2** - UEFI bootloader files (Secure Boot capable)
- **Extraction Script** - Built-in boot file extraction from ISO/USB
- **Diagnostic Script** - Network troubleshooting tools

## Related Projects

- [Fedora Remix](https://github.com/tmichett/Fedora_Remix) - Custom Fedora LiveCD builder with PXE tools pre-installed

## License

This project is provided as-is for educational and personal use.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## Author

Travis Michette (tmichett)
