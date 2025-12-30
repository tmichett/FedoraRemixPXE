#!/bin/bash
#
# PXE Boot Initrd Diagnostics Script
# Run this in the initrd shell (rd.break) to diagnose network issues
#
# Usage: Copy to USB or type manually in initrd shell
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

if [ -f /run/NetworkManager/NetworkManager.pid ]; then
    echo "  PID file exists: $(cat /run/NetworkManager/NetworkManager.pid)"
fi
echo ""

# 7. NetworkManager connections
echo "=== 7. NETWORKMANAGER CONNECTIONS ==="
ls -la /run/NetworkManager/system-connections/ 2>/dev/null || echo "  No connections in /run/NetworkManager/system-connections/"
ls -la /etc/NetworkManager/system-connections/ 2>/dev/null || echo "  No connections in /etc/NetworkManager/system-connections/"
echo ""

# 8. DHCP client status
echo "=== 8. DHCP CLIENT STATUS ==="
if pgrep -f dhclient > /dev/null 2>&1; then
    echo "✓ dhclient is running"
elif pgrep -f nm-dhcp > /dev/null 2>&1; then
    echo "✓ nm-dhcp-helper is running"
else
    echo "✗ No DHCP client running"
fi

# Check for DHCP lease files
echo "  DHCP lease files:"
ls -la /var/lib/NetworkManager/dhcp* 2>/dev/null || echo "    No lease files found"
ls -la /run/NetworkManager/dhcp* 2>/dev/null || echo "    No lease files in /run"
echo ""

# 9. DNS configuration
echo "=== 9. DNS CONFIGURATION ==="
cat /etc/resolv.conf 2>/dev/null || echo "  No /etc/resolv.conf"
echo ""

# 10. systemd services status
echo "=== 10. RELEVANT SYSTEMD SERVICES ==="
for svc in nm-initrd nm-wait-online-initrd network-online.target dracut-cmdline; do
    status=$(systemctl is-active $svc 2>/dev/null || echo "unknown")
    case $status in
        active) echo "  ✓ $svc: $status" ;;
        inactive) echo "  ○ $svc: $status" ;;
        failed) echo "  ✗ $svc: $status" ;;
        *) echo "  ? $svc: $status" ;;
    esac
done
echo ""

# 11. Recent journal logs for NetworkManager
echo "=== 11. RECENT NETWORKMANAGER LOGS ==="
journalctl -u nm-initrd -n 20 --no-pager 2>/dev/null || echo "  No journal available"
echo ""

# 12. BOOTIF parameter check
echo "=== 12. BOOTIF CHECK ==="
bootif=$(cat /proc/cmdline | grep -o 'BOOTIF=[^ ]*')
if [ -n "$bootif" ]; then
    echo "✓ BOOTIF found: $bootif"
else
    echo "○ BOOTIF not present in kernel cmdline"
    echo "  (This is normal for UEFI PXE boot)"
fi
echo ""

# 13. Try to ping gateway
echo "=== 13. CONNECTIVITY TEST ==="
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

# Try to ping PXE server
echo "  Testing PXE server (192.168.0.1)..."
if ping -c 1 -W 2 192.168.0.1 > /dev/null 2>&1; then
    echo "  ✓ Can ping 192.168.0.1"
else
    echo "  ✗ Cannot ping 192.168.0.1"
fi
echo ""

# 14. curl/wget test
echo "=== 14. HTTP TEST ==="
if command -v curl > /dev/null 2>&1; then
    echo "  Testing HTTP to 192.168.0.1..."
    if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 http://192.168.0.1/ 2>/dev/null | grep -q "200\|403"; then
        echo "  ✓ HTTP server responding"
    else
        echo "  ✗ HTTP server not responding"
    fi
else
    echo "  curl not available"
fi
echo ""

# 15. Summary and recommendations
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                        SUMMARY                                 ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Check for common issues
issues=0

if [ ! -f /run/NetworkManager/initrd/neednet ]; then
    echo "ISSUE: neednet file missing - NetworkManager won't start"
    echo "  FIX: Add 'rd.neednet=1' to kernel command line"
    issues=$((issues + 1))
fi

if ! pgrep -x NetworkManager > /dev/null 2>&1; then
    echo "ISSUE: NetworkManager not running"
    echo "  FIX: Check if nm-initrd.service started correctly"
    echo "  TRY: systemctl start nm-initrd"
    issues=$((issues + 1))
fi

if ! ip addr show | grep -q "inet 192.168"; then
    echo "ISSUE: No IP address assigned"
    echo "  FIX: Check DHCP server is running and reachable"
    echo "  TRY: nmcli device connect <interface>"
    echo "  OR:  dhclient <interface>"
    issues=$((issues + 1))
fi

if [ $issues -eq 0 ]; then
    echo "No obvious issues detected."
    echo "Network appears to be configured correctly."
fi

echo ""
echo "=== MANUAL RECOVERY COMMANDS ==="
echo ""
echo "To manually configure network:"
echo "  # Find your interface name"
echo "  ip link show"
echo ""
echo "  # Bring up interface"
echo "  ip link set <iface> up"
echo ""
echo "  # Get DHCP lease"
echo "  dhclient <iface>"
echo "  # OR"
echo "  nmcli device connect <iface>"
echo ""
echo "  # Verify IP"
echo "  ip addr show <iface>"
echo ""
echo "  # Test connectivity"
echo "  ping 192.168.0.1"
echo ""
echo "  # Continue boot after fixing network"
echo "  exit"
echo ""

