# Containerfile for Fedora Remix PXE Server
# Provides DHCP, TFTP, and HTTP services for PXE booting
# Includes extraction tools and diagnostic scripts

FROM registry.fedoraproject.org/fedora:43

LABEL maintainer="Travis Michette <tmichett>"
LABEL description="Containerized PXE Boot Server with DHCP, TFTP, and HTTP services"
LABEL org.opencontainers.image.source="https://github.com/tmichett/FedoraRemixPXE"
LABEL org.opencontainers.image.title="Fedora Remix PXE Server"
LABEL org.opencontainers.image.vendor="tmichett"

# Install required packages
RUN dnf install -y \
    dhcp-server \
    tftp-server \
    httpd \
    syslinux \
    syslinux-tftpboot \
    shim-x64 \
    grub2-efi-x64 \
    grub2-efi-x64-modules \
    iproute \
    procps-ng \
    && dnf clean all

# Create directories
RUN mkdir -p /var/lib/tftpboot/pxelinux.cfg \
    && mkdir -p /var/lib/tftpboot/efi64 \
    && mkdir -p /var/lib/tftpboot/livecd \
    && mkdir -p /var/www/html/livecd \
    && mkdir -p /var/www/html/diag \
    && mkdir -p /var/lib/dhcpd \
    && mkdir -p /usr/local/share/pxe-templates \
    && touch /var/lib/dhcpd/dhcpd.leases

# Copy syslinux files to TFTP root
RUN cp -f /usr/share/syslinux/pxelinux.0 /var/lib/tftpboot/ 2>/dev/null || true \
    && cp -f /usr/share/syslinux/ldlinux.c32 /var/lib/tftpboot/ 2>/dev/null || true \
    && cp -f /usr/share/syslinux/libutil.c32 /var/lib/tftpboot/ 2>/dev/null || true \
    && cp -f /usr/share/syslinux/vesamenu.c32 /var/lib/tftpboot/ 2>/dev/null || true \
    && cp -f /usr/share/syslinux/menu.c32 /var/lib/tftpboot/ 2>/dev/null || true \
    && cp -f /usr/share/syslinux/libcom32.c32 /var/lib/tftpboot/ 2>/dev/null || true

# Copy UEFI boot files
RUN cp -f /boot/efi/EFI/fedora/shimx64.efi /var/lib/tftpboot/efi64/BOOTX64.EFI 2>/dev/null || \
    cp -f /usr/share/shim/*/shimx64.efi /var/lib/tftpboot/efi64/BOOTX64.EFI 2>/dev/null || true \
    && cp -f /boot/efi/EFI/fedora/grubx64.efi /var/lib/tftpboot/efi64/grubx64.efi 2>/dev/null || \
    cp -f /usr/share/grub/x86_64-efi/grubx64.efi /var/lib/tftpboot/efi64/grubx64.efi 2>/dev/null || true \
    && ln -sf efi64/BOOTX64.EFI /var/lib/tftpboot/BOOTX64.EFI 2>/dev/null || true

# Configure Apache for PXE serving
RUN sed -i 's/Listen 80/Listen 0.0.0.0:80/' /etc/httpd/conf/httpd.conf \
    && echo "ServerName pxe-server" >> /etc/httpd/conf/httpd.conf

# Configure TFTP - use in.tftpd directly
RUN echo 'TFTP_ADDRESS="0.0.0.0:69"' > /etc/sysconfig/tftp \
    && echo 'TFTP_OPTIONS="-v -s /var/lib/tftpboot"' >> /etc/sysconfig/tftp

# Create the PXE initrd diagnostic script (available via HTTP)
RUN cat > /var/www/html/diag/pxe-initrd-diag.sh << 'DIAGSCRIPT'
#!/bin/bash
#
# PXE Boot Initrd Diagnostics Script
# Run this in the initrd shell (rd.break) to diagnose network issues
#
# To use: curl -s http://PXE_SERVER_IP/diag/pxe-initrd-diag.sh | bash
#

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║         PXE Boot Initrd Network Diagnostics                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# 1. Kernel command line
echo "=== 1. KERNEL COMMAND LINE ==="
cat /proc/cmdline
echo ""

# 2. Check if neednet file exists
echo "=== 2. NEEDNET FILE CHECK ==="
if [ -f /run/NetworkManager/initrd/neednet ]; then
    echo "✓ /run/NetworkManager/initrd/neednet EXISTS"
    cat /run/NetworkManager/initrd/neednet 2>/dev/null
else
    echo "✗ /run/NetworkManager/initrd/neednet MISSING"
    echo "  This file must exist for NetworkManager to start!"
    echo "  Check if ip=dhcp or rd.neednet=1 is in kernel cmdline"
fi
echo ""

# 3. Network interfaces
echo "=== 3. NETWORK INTERFACES ==="
ip link show 2>/dev/null || ifconfig -a 2>/dev/null
echo ""

# 4. IP addresses
echo "=== 4. IP ADDRESSES ==="
ip addr show 2>/dev/null || ifconfig 2>/dev/null
echo ""

# 5. Routing table
echo "=== 5. ROUTING TABLE ==="
ip route show 2>/dev/null || route -n 2>/dev/null
echo ""

# 6. NetworkManager status
echo "=== 6. NETWORKMANAGER STATUS ==="
if pgrep -x NetworkManager > /dev/null 2>&1; then
    echo "✓ NetworkManager is RUNNING (PID: $(pgrep -x NetworkManager))"
else
    echo "✗ NetworkManager is NOT RUNNING"
fi
echo ""

# 7. DHCP client status
echo "=== 7. DHCP CLIENT STATUS ==="
if pgrep -f dhclient > /dev/null 2>&1; then
    echo "✓ dhclient is running"
elif pgrep -f nm-dhcp > /dev/null 2>&1; then
    echo "✓ nm-dhcp-helper is running"
else
    echo "✗ No DHCP client running"
fi
echo ""

# 8. DNS configuration
echo "=== 8. DNS CONFIGURATION ==="
cat /etc/resolv.conf 2>/dev/null || echo "  No /etc/resolv.conf"
echo ""

# 9. Connectivity test
echo "=== 9. CONNECTIVITY TEST ==="
gateway=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
if [ -n "$gateway" ]; then
    echo "  Default gateway: $gateway"
    if ping -c 1 -W 2 $gateway > /dev/null 2>&1; then
        echo "  ✓ Can ping gateway"
    else
        echo "  ✗ Cannot ping gateway"
    fi
else
    echo "  ✗ No default gateway configured"
fi
echo ""

# 10. Manual recovery commands
echo "=== MANUAL RECOVERY COMMANDS ==="
echo "  ip link show              # List interfaces"
echo "  ip link set <iface> up    # Bring up interface"
echo "  dhclient <iface>          # Get DHCP lease"
echo "  ip addr show <iface>      # Verify IP"
echo "  exit                      # Continue boot"
echo ""
DIAGSCRIPT

RUN chmod +x /var/www/html/diag/pxe-initrd-diag.sh

# Create extraction script for use inside container
RUN cat > /usr/local/bin/extract-boot-files.sh << 'EXTRACTSCRIPT'
#!/bin/bash
#
# Internal extraction script for PXE server container
# Called by the launcher with appropriate arguments
#

set -e

SOURCE_PATH="$1"
PROFILE="$2"
PXE_IP="$3"
MENU_LABEL="$4"
SOURCE_TYPE="$5"  # "iso" or "usb"

TFTP_DIR="/var/lib/tftpboot"
HTTP_DIR="/var/www/html"

if [[ -z "$SOURCE_PATH" || -z "$PROFILE" || -z "$PXE_IP" ]]; then
    echo "Usage: extract-boot-files.sh <source-path> <profile> <pxe-ip> <menu-label> <source-type>"
    exit 1
fi

MENU_LABEL="${MENU_LABEL:-Fedora Remix LiveCD}"

echo "Extracting boot files..."
echo "  Source: $SOURCE_PATH"
echo "  Profile: $PROFILE"
echo "  PXE IP: $PXE_IP"
echo "  Menu Label: $MENU_LABEL"

# Create directories
mkdir -p "$TFTP_DIR/$PROFILE"
mkdir -p "$HTTP_DIR/$PROFILE"
mkdir -p "$TFTP_DIR/pxelinux.cfg"
mkdir -p "$TFTP_DIR/efi64"

# Handle ISO vs USB source
MOUNT_POINT=""
if [[ "$SOURCE_TYPE" == "iso" ]]; then
    MOUNT_POINT="/tmp/iso-mount-$$"
    mkdir -p "$MOUNT_POINT"
    mount -o loop,ro "$SOURCE_PATH" "$MOUNT_POINT"
    SOURCE_PATH="$MOUNT_POINT"
fi

# Find kernel
VMLINUZ=""
for loc in isolinux/vmlinuz0 isolinux/vmlinuz images/pxeboot/vmlinuz boot/vmlinuz; do
    if [[ -f "$SOURCE_PATH/$loc" ]]; then
        VMLINUZ="$SOURCE_PATH/$loc"
        echo "Found kernel: $loc"
        break
    fi
done

if [[ -z "$VMLINUZ" ]]; then
    echo "ERROR: Could not find kernel"
    [[ -n "$MOUNT_POINT" ]] && umount "$MOUNT_POINT" && rmdir "$MOUNT_POINT"
    exit 1
fi

# Find initrd
INITRD=""
for loc in isolinux/initrd0.img isolinux/initrd.img images/pxeboot/initrd.img boot/initrd.img; do
    if [[ -f "$SOURCE_PATH/$loc" ]]; then
        INITRD="$SOURCE_PATH/$loc"
        echo "Found initrd: $loc"
        break
    fi
done

if [[ -z "$INITRD" ]]; then
    echo "ERROR: Could not find initrd"
    [[ -n "$MOUNT_POINT" ]] && umount "$MOUNT_POINT" && rmdir "$MOUNT_POINT"
    exit 1
fi

# Find squashfs
SQUASHFS=""
for loc in LiveOS/squashfs.img LiveOS/rootfs.img images/install.img; do
    if [[ -f "$SOURCE_PATH/$loc" ]]; then
        SQUASHFS="$SOURCE_PATH/$loc"
        echo "Found squashfs: $loc"
        break
    fi
done

if [[ -z "$SQUASHFS" ]]; then
    echo "ERROR: Could not find squashfs image"
    [[ -n "$MOUNT_POINT" ]] && umount "$MOUNT_POINT" && rmdir "$MOUNT_POINT"
    exit 1
fi

# Copy files
echo "Copying kernel..."
cp -f "$VMLINUZ" "$TFTP_DIR/$PROFILE/vmlinuz"

echo "Copying initrd..."
cp -f "$INITRD" "$TFTP_DIR/$PROFILE/initrd.img"

echo "Copying squashfs (this may take a few minutes)..."
cp -f "$SQUASHFS" "$HTTP_DIR/$PROFILE/squashfs.img"

# Copy UEFI files if present
if [[ -f "$SOURCE_PATH/EFI/BOOT/BOOTX64.EFI" ]]; then
    cp -f "$SOURCE_PATH/EFI/BOOT/BOOTX64.EFI" "$TFTP_DIR/" 2>/dev/null || true
    cp -f "$SOURCE_PATH/EFI/BOOT/BOOTX64.EFI" "$TFTP_DIR/efi64/" 2>/dev/null || true
fi
if [[ -f "$SOURCE_PATH/EFI/BOOT/grubx64.efi" ]]; then
    cp -f "$SOURCE_PATH/EFI/BOOT/grubx64.efi" "$TFTP_DIR/" 2>/dev/null || true
    cp -f "$SOURCE_PATH/EFI/BOOT/grubx64.efi" "$TFTP_DIR/efi64/" 2>/dev/null || true
fi

# Unmount if we mounted an ISO
if [[ -n "$MOUNT_POINT" ]]; then
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
fi

# Generate BIOS boot config
echo "Generating PXE boot menu configurations..."
cat > "$TFTP_DIR/pxelinux.cfg/default" << EOF
# PXELinux Configuration for BIOS Boot
# Generated automatically

UI vesamenu.c32
TIMEOUT 600
MENU TITLE Travis's Fedora Remix PXE Boot Menu
MENU WIDTH 80
MENU ROWS 14

LABEL local
    MENU LABEL Boot from ^local drive
    MENU DEFAULT
    LOCALBOOT 0xffff

LABEL $PROFILE
    MENU LABEL ^$MENU_LABEL
    KERNEL $PROFILE/vmlinuz
    APPEND initrd=$PROFILE/initrd.img root=live:http://$PXE_IP/$PROFILE/squashfs.img ro rd.live.image rd.luks=0 rd.dm=0 rd.neednet=1 ip=dhcp
    IPAPPEND 2

LABEL ${PROFILE}-debug
    MENU LABEL $MENU_LABEL (^Debug Mode)
    KERNEL $PROFILE/vmlinuz
    APPEND initrd=$PROFILE/initrd.img root=live:http://$PXE_IP/$PROFILE/squashfs.img ro rd.live.image rd.luks=0 rd.dm=0 rd.neednet=1 ip=dhcp rd.break
    IPAPPEND 2

LABEL diagnostics
    MENU LABEL ^Network Diagnostics (initrd shell)
    KERNEL $PROFILE/vmlinuz
    APPEND initrd=$PROFILE/initrd.img rd.break rd.neednet=1 ip=dhcp
    IPAPPEND 2
EOF

# Generate UEFI boot config (grub.cfg)
cat > "$TFTP_DIR/efi64/grub.cfg" << EOF
# GRUB2 configuration for UEFI PXE boot
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

if [ -z "\$myip" ]; then
    set myip="\${net_default_ip}"
fi
if [ -z "\$mygateway" ]; then
    set mygateway="$PXE_IP"
fi

menuentry "$MENU_LABEL" --class fedora --class gnu-linux --class gnu --class os {
    echo "Booting with IP: \${myip}, Gateway: \${mygateway}"
    linuxefi $PROFILE/vmlinuz root=live:http://$PXE_IP/$PROFILE/squashfs.img ro rd.live.image rd.luks=0 rd.dm=0 rd.neednet=1 ip=\${myip}::\${mygateway}:\${mynetmask}:\${myhostname}::none nameserver=$PXE_IP
    initrdefi $PROFILE/initrd.img
}

menuentry "$MENU_LABEL (DHCP fallback)" --class fedora --class gnu-linux --class gnu --class os {
    linuxefi $PROFILE/vmlinuz root=live:http://$PXE_IP/$PROFILE/squashfs.img ro rd.live.image rd.luks=0 rd.dm=0 rd.neednet=1 ip=dhcp
    initrdefi $PROFILE/initrd.img
}

menuentry "$MENU_LABEL (Debug Mode)" --class fedora --class gnu-linux --class gnu --class os {
    linuxefi $PROFILE/vmlinuz root=live:http://$PXE_IP/$PROFILE/squashfs.img ro rd.live.image rd.luks=0 rd.dm=0 rd.neednet=1 ip=\${myip}::\${mygateway}:\${mynetmask}:\${myhostname}::none nameserver=$PXE_IP rd.break
    initrdefi $PROFILE/initrd.img
}

menuentry "Network Diagnostics (initrd shell)" --class fedora --class gnu-linux {
    echo "Booting into initrd diagnostics shell..."
    echo "Run: curl -s http://$PXE_IP/diag/pxe-initrd-diag.sh | bash"
    linuxefi $PROFILE/vmlinuz rd.break rd.neednet=1 ip=\${myip}::\${mygateway}:\${mynetmask}:\${myhostname}::none nameserver=$PXE_IP
    initrdefi $PROFILE/initrd.img
}

menuentry "Boot from Local Disk" --class hd {
    exit
}

menuentry "Reboot" --class reboot {
    reboot
}
EOF

# Copy grub.cfg to TFTP root
cp -f "$TFTP_DIR/efi64/grub.cfg" "$TFTP_DIR/grub.cfg"

echo ""
echo "Extraction complete!"
echo "  Kernel:    $TFTP_DIR/$PROFILE/vmlinuz"
echo "  Initrd:    $TFTP_DIR/$PROFILE/initrd.img"
echo "  SquashFS:  $HTTP_DIR/$PROFILE/squashfs.img"
echo "  BIOS Menu: $TFTP_DIR/pxelinux.cfg/default"
echo "  UEFI Menu: $TFTP_DIR/efi64/grub.cfg"
echo ""
echo "Diagnostics available at: http://$PXE_IP/diag/pxe-initrd-diag.sh"
EXTRACTSCRIPT

RUN chmod +x /usr/local/bin/extract-boot-files.sh

# Create startup script
RUN cat > /usr/local/bin/start-pxe-services.sh << 'SCRIPT'
#!/bin/bash
set -e

echo "========================================"
echo "  Starting PXE Server Services"
echo "========================================"

echo "Configuration:"
echo "  DHCP Interface: ${DHCP_INTERFACE:-auto}"
echo "  PXE Server IP:  ${PXE_SERVER_IP:-auto}"
echo ""

# Create dhcpd leases file if not exists
touch /var/lib/dhcpd/dhcpd.leases
chown dhcpd:dhcpd /var/lib/dhcpd/dhcpd.leases

# Ensure directories have correct permissions
chmod -R 755 /var/lib/tftpboot
chmod -R 755 /var/www/html

# Start TFTP server in background
echo "Starting TFTP server..."
/usr/sbin/in.tftpd -L -v -s /var/lib/tftpboot &
echo "  TFTP server started (port 69)"

# Start Apache in background
echo "Starting HTTP server..."
/usr/sbin/httpd -DFOREGROUND &
HTTPD_PID=$!
echo "  HTTP server started (port 80)"

# Wait for httpd to start
sleep 2

# Build DHCP command with interface if specified
DHCP_CMD="/usr/sbin/dhcpd -f -cf /etc/dhcp/dhcpd.conf -user dhcpd -group dhcpd --no-pid"

if [[ -n "${DHCP_INTERFACE}" ]]; then
    DHCP_CMD="${DHCP_CMD} ${DHCP_INTERFACE}"
    echo "Starting DHCP server on interface: ${DHCP_INTERFACE}"
else
    echo "Starting DHCP server on all interfaces..."
fi

echo "  DHCP server starting (port 67)"
echo ""
echo "PXE Server is ready!"
echo "========================================"

exec ${DHCP_CMD}
SCRIPT

RUN chmod +x /usr/local/bin/start-pxe-services.sh

# Expose ports
EXPOSE 67/udp 68/udp 69/udp 80/tcp 4011/udp

# Volumes for configuration and data
VOLUME ["/var/lib/tftpboot", "/var/www/html", "/etc/dhcp"]

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD pgrep dhcpd && pgrep httpd || exit 1

# Default command
CMD ["/usr/local/bin/start-pxe-services.sh"]
