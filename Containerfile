# Containerfile for Fedora Remix PXE Server
# Provides DHCP, TFTP, and HTTP services for PXE booting

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
    && mkdir -p /var/lib/dhcpd \
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

# Create startup script
RUN cat > /usr/local/bin/start-pxe-services.sh << 'SCRIPT'
#!/bin/bash
set -e

echo "========================================"
echo "  Starting PXE Server Services"
echo "========================================"

# Environment variables (passed from host)
# DHCP_INTERFACE - the network interface to bind DHCP to
# PXE_SERVER_IP - the IP address of the PXE server

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

# Start DHCP server in foreground (keeps container running)
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

