#!/usr/bin/env python3
"""
Fedora Remix PXE Server Launcher

A single-script launcher for the containerized PXE boot server.
This script handles container download, network configuration, and
extraction of boot files from ISO or USB sources.

Usage:
    ./run-pxe-server           # Interactive mode
    ./run-pxe-server --help    # Show help
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Configuration
IMAGE_NAME = "quay.io/tmichett/fedoraremixpxe:latest"
CONTAINER_NAME = "pxe-server"
DEFAULT_PXE_IP = "192.168.0.1"
DEFAULT_SUBNET = "192.168.0.0"
DEFAULT_NETMASK = "255.255.255.0"
DEFAULT_RANGE_START = "192.168.0.201"
DEFAULT_RANGE_END = "192.168.0.240"

# ANSI Colors
class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    CYAN = '\033[0;36m'
    MAGENTA = '\033[0;35m'
    BOLD = '\033[1m'
    NC = '\033[0m'  # No Color


def print_banner():
    """Print the application banner."""
    print(f"""
{Colors.CYAN}╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║   {Colors.BOLD}Fedora Remix PXE Server{Colors.NC}{Colors.CYAN}                                        ║
║   Containerized Network Boot Solution                            ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝{Colors.NC}
""")


def log_info(msg):
    print(f"{Colors.GREEN}[INFO]{Colors.NC} {msg}")


def log_warn(msg):
    print(f"{Colors.YELLOW}[WARN]{Colors.NC} {msg}")


def log_error(msg):
    print(f"{Colors.RED}[ERROR]{Colors.NC} {msg}")


def run_cmd(cmd, check=True, capture=False, quiet=False):
    """Run a command and optionally capture output."""
    if not quiet:
        pass  # Could log command here for debug
    try:
        result = subprocess.run(
            cmd,
            shell=isinstance(cmd, str),
            check=check,
            capture_output=capture,
            text=True
        )
        return result
    except subprocess.CalledProcessError as e:
        if not check:
            return e
        raise


def check_root():
    """Check if running as root."""
    if os.geteuid() != 0:
        log_error("This script must be run as root (use sudo)")
        sys.exit(1)


def check_podman():
    """Check if podman is installed."""
    if not shutil.which("podman"):
        log_error("Podman is not installed. Please install it first:")
        print("  sudo dnf install podman")
        sys.exit(1)


def container_exists():
    """Check if the PXE server container exists."""
    result = run_cmd(f"podman container exists {CONTAINER_NAME}", check=False, capture=True)
    return result.returncode == 0


def container_running():
    """Check if the PXE server container is running."""
    if not container_exists():
        return False
    result = run_cmd(
        f"podman inspect --format '{{{{.State.Status}}}}' {CONTAINER_NAME}",
        check=False, capture=True
    )
    return result.returncode == 0 and result.stdout.strip() == "running"


def image_exists():
    """Check if the container image exists locally."""
    result = run_cmd(f"podman image exists {IMAGE_NAME}", check=False, capture=True)
    return result.returncode == 0


def pull_image():
    """Pull the container image from the registry."""
    log_info(f"Pulling container image: {IMAGE_NAME}")
    result = run_cmd(f"podman pull {IMAGE_NAME}", check=False)
    if result.returncode != 0:
        log_error("Failed to pull container image")
        return False
    log_info("Container image pulled successfully")
    return True


def get_network_interfaces():
    """Get list of non-wireless, non-virtual network interfaces with details."""
    interfaces = []
    
    # Get interface list
    result = run_cmd("ip -o link show", capture=True)
    
    # Parse interfaces
    for line in result.stdout.strip().split('\n'):
        parts = line.split(': ')
        if len(parts) < 2:
            continue
        
        iface = parts[1].split('@')[0]  # Handle VLAN interfaces
        
        # Skip virtual, wireless, and loopback interfaces
        skip_prefixes = ('lo', 'veth', 'br-', 'docker', 'virbr', 'podman', 
                         'wlan', 'wlp', 'wlx', 'tun', 'tap')
        if any(iface.startswith(p) for p in skip_prefixes):
            continue
        
        # Get interface status
        state = "DOWN"
        if "state UP" in line or ",UP," in line:
            state = "UP"
        
        # Get MAC address
        mac_match = re.search(r'link/ether\s+([0-9a-f:]+)', line)
        mac = mac_match.group(1) if mac_match else "N/A"
        
        # Get IP address
        ip_result = run_cmd(f"ip -4 addr show {iface}", capture=True, check=False)
        ip_match = re.search(r'inet\s+(\d+\.\d+\.\d+\.\d+)', ip_result.stdout)
        ip_addr = ip_match.group(1) if ip_match else "--"
        
        interfaces.append({
            'name': iface,
            'state': state,
            'mac': mac,
            'ip': ip_addr
        })
    
    return interfaces


def select_network_interface():
    """Display network interfaces and let user select one."""
    interfaces = get_network_interfaces()
    
    if not interfaces:
        log_error("No suitable network interfaces found")
        sys.exit(1)
    
    print(f"""
{Colors.CYAN}╔══════════════════════════════════════════════════════════════════════════╗
║                     Available Network Interfaces                         ║
╠════╦════════════════╦══════════╦═══════════════════╦═════════════════════╣
║ #  ║ Interface      ║  Status  ║ IP Address        ║ MAC Address         ║
╠════╬════════════════╬══════════╬═══════════════════╬═════════════════════╣{Colors.NC}""")
    
    for i, iface in enumerate(interfaces, 1):
        print(f"{Colors.CYAN}║{Colors.NC} {i:<2} {Colors.CYAN}║{Colors.NC} {iface['name']:<14} {Colors.CYAN}║{Colors.NC} {iface['state']:<8} {Colors.CYAN}║{Colors.NC} {iface['ip']:<17} {Colors.CYAN}║{Colors.NC} {iface['mac']:<19} {Colors.CYAN}║{Colors.NC}")
    
    print(f"{Colors.CYAN}╚════╩════════════════╩══════════╩═══════════════════╩═════════════════════╝{Colors.NC}")
    print(f"\n{Colors.YELLOW}Note: Wireless and virtual adapters are excluded.{Colors.NC}\n")
    
    while True:
        try:
            choice = input(f"Select interface number for DHCP/PXE services [1]: ").strip()
            if not choice:
                choice = 1
            else:
                choice = int(choice)
            
            if 1 <= choice <= len(interfaces):
                return interfaces[choice - 1]
            else:
                print(f"Please enter a number between 1 and {len(interfaces)}")
        except ValueError:
            print("Please enter a valid number")


def get_pxe_configuration():
    """Interactively get PXE server configuration."""
    print(f"""
{Colors.CYAN}═══════════════════════════════════════════════════════════════
  PXE Server Configuration
═══════════════════════════════════════════════════════════════{Colors.NC}
""")
    
    config = {}
    
    # Select network interface
    iface = select_network_interface()
    config['interface'] = iface['name']
    
    # Get PXE Server IP
    default_ip = iface['ip'] if iface['ip'] != "--" else DEFAULT_PXE_IP
    print(f"\n{Colors.BLUE}PXE Server IP Address{Colors.NC}")
    print("  This IP will be assigned to the selected interface.")
    print("  Clients will connect to this IP for DHCP, TFTP, and HTTP.")
    ip = input(f"  Enter PXE Server IP [{default_ip}]: ").strip()
    config['server_ip'] = ip if ip else default_ip
    
    # Calculate subnet from IP
    ip_parts = config['server_ip'].split('.')
    config['subnet'] = f"{ip_parts[0]}.{ip_parts[1]}.{ip_parts[2]}.0"
    config['netmask'] = DEFAULT_NETMASK
    
    # DHCP range
    range_start = f"{ip_parts[0]}.{ip_parts[1]}.{ip_parts[2]}.201"
    range_end = f"{ip_parts[0]}.{ip_parts[1]}.{ip_parts[2]}.240"
    config['range_start'] = range_start
    config['range_end'] = range_end
    config['router'] = config['server_ip']
    config['dns'] = config['server_ip']
    
    return config


def find_usb_drives():
    """Find mounted USB drives with LiveOS content."""
    drives = []
    
    # Check common mount locations
    mount_locations = [
        Path("/run/media"),
        Path("/media"),
        Path("/mnt")
    ]
    
    for base in mount_locations:
        if not base.exists():
            continue
        
        # Check subdirectories
        for user_dir in base.iterdir():
            if user_dir.is_dir():
                # Could be user directory or direct mount
                search_dirs = [user_dir]
                if user_dir.name not in ['root']:
                    search_dirs.extend(user_dir.iterdir() if user_dir.is_dir() else [])
                
                for mount in search_dirs:
                    if not mount.is_dir():
                        continue
                    squashfs = mount / "LiveOS" / "squashfs.img"
                    if squashfs.exists():
                        size = squashfs.stat().st_size / (1024 * 1024 * 1024)
                        drives.append({
                            'path': str(mount),
                            'label': mount.name,
                            'size': f"{size:.1f} GB"
                        })
    
    return drives


def select_source():
    """Let user select between ISO or USB source."""
    print(f"""
{Colors.CYAN}═══════════════════════════════════════════════════════════════
  Boot Image Source
═══════════════════════════════════════════════════════════════{Colors.NC}

Select the source of your Fedora Remix boot image:

  {Colors.GREEN}1){Colors.NC} Live USB Drive (mounted)
  {Colors.GREEN}2){Colors.NC} ISO File
  {Colors.GREEN}3){Colors.NC} Skip extraction (use existing boot files)
""")
    
    while True:
        choice = input("Enter your choice [1]: ").strip()
        if not choice:
            choice = "1"
        
        if choice == "1":
            return select_usb_source()
        elif choice == "2":
            return select_iso_source()
        elif choice == "3":
            return None
        else:
            print("Please enter 1, 2, or 3")


def select_usb_source():
    """Select a USB drive source."""
    drives = find_usb_drives()
    
    if not drives:
        log_warn("No mounted USB drives with LiveOS found")
        print("\nMake sure your USB drive is mounted and contains:")
        print("  - LiveOS/squashfs.img")
        print("  - isolinux/vmlinuz (or vmlinuz0)")
        print("  - isolinux/initrd.img (or initrd0.img)")
        print()
        
        # Ask for manual path
        path = input("Enter USB mount path manually (or press Enter to go back): ").strip()
        if not path:
            return select_source()
        
        if not Path(path).exists():
            log_error(f"Path does not exist: {path}")
            return select_source()
        
        return {'type': 'usb', 'path': path, 'label': Path(path).name}
    
    print(f"\n{Colors.BLUE}Available USB Drives:{Colors.NC}\n")
    for i, drive in enumerate(drives, 1):
        print(f"  {Colors.GREEN}{i}){Colors.NC} {drive['label']} ({drive['size']})")
        print(f"     Path: {drive['path']}")
    
    print()
    
    while True:
        choice = input(f"Select USB drive [1]: ").strip()
        if not choice:
            choice = 1
        else:
            try:
                choice = int(choice)
            except ValueError:
                print("Please enter a valid number")
                continue
        
        if 1 <= choice <= len(drives):
            drive = drives[choice - 1]
            return {'type': 'usb', 'path': drive['path'], 'label': drive['label']}
        else:
            print(f"Please enter a number between 1 and {len(drives)}")


def select_iso_source():
    """Select an ISO file source."""
    print(f"\n{Colors.BLUE}ISO File Selection{Colors.NC}")
    print("Enter the full path to your Fedora Remix ISO file.\n")
    
    while True:
        path = input("ISO path: ").strip()
        
        if not path:
            return select_source()
        
        path = os.path.expanduser(path)
        
        if not os.path.isfile(path):
            log_error(f"File not found: {path}")
            continue
        
        if not path.lower().endswith('.iso'):
            log_warn("File doesn't have .iso extension")
            confirm = input("Continue anyway? [y/N]: ").strip().lower()
            if confirm != 'y':
                continue
        
        label = os.path.basename(path).replace('.iso', '').replace('.ISO', '')
        return {'type': 'iso', 'path': path, 'label': label}


def get_profile_config(source):
    """Get profile name and menu label for the boot image."""
    if source is None:
        return None
    
    default_profile = re.sub(r'[^a-zA-Z0-9]', '_', source['label'])[:20].lower()
    default_label = "Fedora Remix LiveCD"
    
    print(f"""
{Colors.CYAN}═══════════════════════════════════════════════════════════════
  Boot Profile Configuration  
═══════════════════════════════════════════════════════════════{Colors.NC}
""")
    
    print(f"{Colors.BLUE}Profile Name{Colors.NC}")
    print("  A short name for this boot image (used in file paths).")
    profile = input(f"  Enter profile name [{default_profile}]: ").strip()
    if not profile:
        profile = default_profile
    profile = re.sub(r'[^a-zA-Z0-9_]', '_', profile)
    
    print(f"\n{Colors.BLUE}Boot Menu Label{Colors.NC}")
    print("  The text shown in the PXE boot menu for this option.")
    label = input(f"  Enter menu label [{default_label}]: ").strip()
    if not label:
        label = default_label
    
    return {
        'profile': profile,
        'label': label,
        'source': source
    }


def generate_dhcp_config(config, config_dir):
    """Generate DHCP configuration file."""
    dhcp_config = f"""# DHCP Configuration for PXE Boot Services
# Generated by run-pxe-server

ddns-update-style none;

option space pxelinux;
option pxelinux.magic code 208 = string;
option pxelinux.configfile code 209 = text;
option pxelinux.pathprefix code 210 = text;
option pxelinux.reboottime code 211 = unsigned integer 32;
option architecture-type code 93 = unsigned integer 16;

subnet {config['subnet']} netmask {config['netmask']} {{

    # PXE Boot clients
    class "pxeclients" {{
        match if substring(option vendor-class-identifier, 0, 9) = "PXEClient";
        next-server {config['server_ip']};
        
        if option architecture-type = 00:07 {{
            filename "BOOTX64.EFI";
        }} else {{
            filename "pxelinux.0";
        }}
    }}

    option routers {config['router']};
    option subnet-mask {config['netmask']};
    option domain-name-servers {config['dns']};
    default-lease-time 600;
    max-lease-time 7200;

    pool {{
        allow members of "pxeclients";
        range {config['range_start']} {config['range_end']};
    }}
}}
"""
    
    dhcp_file = config_dir / "dhcpd.conf"
    dhcp_file.write_text(dhcp_config)
    log_info(f"Generated DHCP config: {dhcp_file}")


def configure_network_interface(interface, ip_address):
    """Configure static IP on the network interface."""
    log_info(f"Configuring {interface} with IP {ip_address}")
    
    # Check if nmcli is available
    if not shutil.which("nmcli"):
        log_warn("nmcli not found, skipping network configuration")
        log_warn(f"Please manually configure {interface} with IP {ip_address}")
        return
    
    # Create or modify connection
    conn_name = f"pxe-{interface}"
    
    # Delete existing connection if present
    run_cmd(f"nmcli connection delete '{conn_name}'", check=False, capture=True)
    
    # Create new connection
    run_cmd(
        f"nmcli connection add type ethernet con-name '{conn_name}' "
        f"ifname {interface} ipv4.addresses {ip_address}/24 "
        f"ipv4.method manual",
        check=False
    )
    
    # Activate connection
    run_cmd(f"nmcli connection up '{conn_name}'", check=False)


def start_container(config, data_dir, config_dir):
    """Start the PXE server container."""
    log_info("Starting PXE server container...")
    
    # Stop and remove existing container if present
    if container_exists():
        run_cmd(f"podman stop {CONTAINER_NAME}", check=False, capture=True)
        run_cmd(f"podman rm {CONTAINER_NAME}", check=False, capture=True)
    
    # Create data directories
    tftp_dir = data_dir / "tftpboot"
    http_dir = data_dir / "http"
    tftp_dir.mkdir(parents=True, exist_ok=True)
    http_dir.mkdir(parents=True, exist_ok=True)
    
    # Generate DHCP config
    generate_dhcp_config(config, config_dir)
    
    # Build podman run command
    cmd = [
        "podman", "run", "-d",
        "--name", CONTAINER_NAME,
        "--network=host",
        "--cap-add=NET_ADMIN",
        "--cap-add=NET_RAW",
        "-e", f"DHCP_INTERFACE={config['interface']}",
        "-e", f"PXE_SERVER_IP={config['server_ip']}",
        "-v", f"{tftp_dir}:/var/lib/tftpboot:Z",
        "-v", f"{http_dir}:/var/www/html:Z",
        "-v", f"{config_dir}/dhcpd.conf:/etc/dhcp/dhcpd.conf:Z",
        IMAGE_NAME
    ]
    
    result = run_cmd(cmd, check=False, capture=True)
    
    if result.returncode != 0:
        log_error("Failed to start container")
        print(result.stderr)
        return False
    
    log_info("Container started successfully")
    return True


def extract_boot_files(profile_config, config, data_dir):
    """Extract boot files from ISO or USB into the container."""
    if profile_config is None:
        log_info("Skipping boot file extraction")
        return True
    
    source = profile_config['source']
    profile = profile_config['profile']
    label = profile_config['label']
    
    log_info(f"Extracting boot files from {source['type'].upper()}: {source['path']}")
    
    # For USB, we mount it into the container
    # For ISO, we also mount it into the container
    
    source_mount = "/mnt/source"
    
    # Build extraction command
    extract_cmd = [
        "podman", "exec", CONTAINER_NAME,
        "/usr/local/bin/extract-boot-files.sh",
        source_mount,
        profile,
        config['server_ip'],
        label,
        source['type']
    ]
    
    # First, we need to mount the source into the running container
    # Stop current container, add mount, and restart
    run_cmd(f"podman stop {CONTAINER_NAME}", check=False, capture=True)
    run_cmd(f"podman rm {CONTAINER_NAME}", check=False, capture=True)
    
    # Restart with the source mounted
    tftp_dir = data_dir / "tftpboot"
    http_dir = data_dir / "http"
    config_dir = data_dir.parent / "config"
    
    cmd = [
        "podman", "run", "-d",
        "--name", CONTAINER_NAME,
        "--network=host",
        "--cap-add=NET_ADMIN",
        "--cap-add=NET_RAW",
        "--privileged",  # Needed for loop mount of ISO
        "-e", f"DHCP_INTERFACE={config['interface']}",
        "-e", f"PXE_SERVER_IP={config['server_ip']}",
        "-v", f"{tftp_dir}:/var/lib/tftpboot:Z",
        "-v", f"{http_dir}:/var/www/html:Z",
        "-v", f"{config_dir}/dhcpd.conf:/etc/dhcp/dhcpd.conf:Z",
        "-v", f"{source['path']}:{source_mount}:ro",
        IMAGE_NAME
    ]
    
    result = run_cmd(cmd, check=False, capture=True)
    if result.returncode != 0:
        log_error("Failed to restart container with source mount")
        print(result.stderr)
        return False
    
    # Wait for container to start
    import time
    time.sleep(2)
    
    # Run extraction
    log_info("Running extraction (this may take several minutes for large images)...")
    result = run_cmd(extract_cmd, check=False)
    
    if result.returncode != 0:
        log_error("Extraction failed")
        return False
    
    log_info("Boot files extracted successfully")
    return True


def show_status(config, data_dir):
    """Show the current status of the PXE server."""
    print(f"""
{Colors.GREEN}╔═══════════════════════════════════════════════════════════════╗
║                    PXE Server Running!                        ║
╚═══════════════════════════════════════════════════════════════╝{Colors.NC}

{Colors.BLUE}Server Configuration:{Colors.NC}
  Interface:      {config['interface']}
  Server IP:      {config['server_ip']}
  DHCP Range:     {config['range_start']} - {config['range_end']}

{Colors.BLUE}Services:{Colors.NC}""")
    
    # Check services
    for service, process in [("DHCP", "dhcpd"), ("TFTP", "in.tftpd"), ("HTTP", "httpd")]:
        result = run_cmd(f"podman exec {CONTAINER_NAME} pgrep {process}", check=False, capture=True)
        status = f"{Colors.GREEN}●{Colors.NC}" if result.returncode == 0 else f"{Colors.RED}●{Colors.NC}"
        print(f"  {status} {service} Server")
    
    # Show boot files status
    tftp_dir = data_dir / "tftpboot"
    http_dir = data_dir / "http"
    
    print(f"\n{Colors.BLUE}Boot Images:{Colors.NC}")
    
    # Find profiles
    found_profile = False
    for profile_dir in tftp_dir.iterdir():
        if profile_dir.is_dir() and (profile_dir / "vmlinuz").exists():
            found_profile = True
            print(f"  {Colors.GREEN}●{Colors.NC} {profile_dir.name}: kernel and initrd available")
    
    if not found_profile:
        print(f"  {Colors.YELLOW}●{Colors.NC} No boot images found")
    
    # Check for squashfs
    for http_profile in http_dir.iterdir():
        if http_profile.is_dir():
            squashfs = http_profile / "squashfs.img"
            if squashfs.exists():
                size = squashfs.stat().st_size / (1024 * 1024 * 1024)
                print(f"  {Colors.GREEN}●{Colors.NC} {http_profile.name}: squashfs available ({size:.1f} GB)")
    
    print(f"""
{Colors.BLUE}Diagnostics:{Colors.NC}
  Script URL:     http://{config['server_ip']}/diag/pxe-initrd-diag.sh
  
{Colors.YELLOW}Client Boot Instructions:{Colors.NC}
  1. Configure client to boot from network (PXE)
  2. Client will receive IP from DHCP ({config['range_start']} - {config['range_end']})
  3. Select boot option from PXE menu
  4. If debugging, select "Debug Mode" to enter initrd shell

{Colors.BLUE}Management Commands:{Colors.NC}
  View logs:      podman logs -f {CONTAINER_NAME}
  Shell access:   podman exec -it {CONTAINER_NAME} /bin/bash
  Stop server:    podman stop {CONTAINER_NAME}
  Remove server:  podman rm {CONTAINER_NAME}
""")


def main():
    parser = argparse.ArgumentParser(
        description="Fedora Remix PXE Server Launcher",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  ./run-pxe-server                    # Interactive setup
  ./run-pxe-server --status           # Show current status
  ./run-pxe-server --stop             # Stop the PXE server
        """
    )
    parser.add_argument('--status', action='store_true', help='Show PXE server status')
    parser.add_argument('--stop', action='store_true', help='Stop the PXE server')
    parser.add_argument('--logs', action='store_true', help='Show container logs')
    parser.add_argument('--shell', action='store_true', help='Open shell in container')
    
    args = parser.parse_args()
    
    # Create data directories
    data_dir = Path.home() / ".local" / "share" / "fedoraremix-pxe" / "data"
    config_dir = Path.home() / ".local" / "share" / "fedoraremix-pxe" / "config"
    data_dir.mkdir(parents=True, exist_ok=True)
    config_dir.mkdir(parents=True, exist_ok=True)
    
    check_podman()
    
    # Handle non-interactive commands
    if args.stop:
        check_root()
        if container_running():
            run_cmd(f"podman stop {CONTAINER_NAME}")
            log_info("PXE server stopped")
        else:
            log_warn("PXE server is not running")
        return
    
    if args.logs:
        if container_exists():
            os.execvp("podman", ["podman", "logs", "-f", CONTAINER_NAME])
        else:
            log_error("Container not found")
        return
    
    if args.shell:
        if container_running():
            os.execvp("podman", ["podman", "exec", "-it", CONTAINER_NAME, "/bin/bash"])
        else:
            log_error("Container is not running")
        return
    
    if args.status:
        # Load saved config if available
        env_file = config_dir / "pxe-server.env"
        if env_file.exists():
            config = {}
            for line in env_file.read_text().strip().split('\n'):
                if '=' in line and not line.startswith('#'):
                    key, value = line.split('=', 1)
                    key = key.strip().replace('PXE_', '').lower()
                    config[key] = value.strip().strip('"')
            
            # Map env names to config names
            config = {
                'interface': config.get('interface', 'unknown'),
                'server_ip': config.get('server_ip', 'unknown'),
                'range_start': config.get('range_start', 'unknown'),
                'range_end': config.get('range_end', 'unknown'),
            }
            show_status(config, data_dir)
        else:
            if container_running():
                log_info("PXE server is running, but no saved configuration found")
            else:
                log_warn("PXE server is not running. Use ./run-pxe-server to start.")
        return
    
    # Interactive mode - requires root
    check_root()
    
    print_banner()
    
    # Check for container image
    if not image_exists():
        log_info("Container image not found locally")
        if not pull_image():
            log_error("Cannot proceed without container image")
            sys.exit(1)
    else:
        log_info(f"Container image found: {IMAGE_NAME}")
    
    # Get configuration
    config = get_pxe_configuration()
    
    # Select boot image source
    source = select_source()
    profile_config = get_profile_config(source)
    
    # Show confirmation
    print(f"""
{Colors.CYAN}═══════════════════════════════════════════════════════════════
  Configuration Summary
═══════════════════════════════════════════════════════════════{Colors.NC}

  Network Interface:  {config['interface']}
  PXE Server IP:      {config['server_ip']}
  DHCP Range:         {config['range_start']} - {config['range_end']}
""")
    
    if profile_config:
        print(f"""  Boot Source:        {profile_config['source']['type'].upper()} - {profile_config['source']['path']}
  Profile Name:       {profile_config['profile']}
  Menu Label:         {profile_config['label']}
""")
    else:
        print("  Boot Source:        Using existing files\n")
    
    confirm = input("Proceed with this configuration? [Y/n]: ").strip().lower()
    if confirm == 'n':
        log_info("Cancelled")
        sys.exit(0)
    
    # Configure network interface
    configure_network_interface(config['interface'], config['server_ip'])
    
    # Save configuration
    env_content = f"""# PXE Server Configuration
PXE_INTERFACE="{config['interface']}"
PXE_SERVER_IP="{config['server_ip']}"
PXE_SUBNET="{config['subnet']}"
PXE_NETMASK="{config['netmask']}"
PXE_ROUTER="{config['router']}"
PXE_DNS="{config['dns']}"
PXE_RANGE_START="{config['range_start']}"
PXE_RANGE_END="{config['range_end']}"
"""
    (config_dir / "pxe-server.env").write_text(env_content)
    
    # Start container
    if not start_container(config, data_dir, config_dir):
        sys.exit(1)
    
    # Extract boot files if source was selected
    if profile_config:
        if not extract_boot_files(profile_config, config, data_dir):
            log_warn("Boot file extraction failed, but server is running")
            log_warn("You can manually extract files or try again later")
    
    # Show status
    show_status(config, data_dir)


if __name__ == "__main__":
    main()

