#!/bin/bash
# Test whether benoit-pierre's ffi/netinfo approach will work on the Nook GL4+.
# Probes each data source the module uses, from least to most privileged.
# Run with: bash scripts/test_netinfo.sh

ADB="adb shell"

echo "=== Network interfaces ==="
$ADB ls /sys/class/net/

echo ""
echo "=== Wireless interface detection (sysfs /wireless/ dir) ==="
for iface in wlan0 wlan1; do
    result=$($ADB "ls /sys/class/net/$iface/wireless/ 2>/dev/null && echo EXISTS || echo MISSING")
    echo "  /sys/class/net/$iface/wireless/ : $result"
done

echo ""
echo "=== IP addresses (getifaddrs AF_INET equivalent) ==="
$ADB ip addr show wlan0 2>/dev/null || $ADB ifconfig wlan0 2>/dev/null

echo ""
echo "=== MAC address via sysfs (getifaddrs AF_PACKET equivalent) ==="
$ADB cat /sys/class/net/wlan0/address 2>/dev/null || echo "MISSING"

echo ""
echo "=== SSID via /proc/net/wireless ==="
$ADB cat /proc/net/wireless 2>/dev/null || echo "MISSING"

echo ""
echo "=== SSID via wpa_supplicant status ==="
$ADB "wpa_cli -i wlan0 status 2>/dev/null | grep -E 'ssid|ip_address|address'" || echo "MISSING or permission denied"

echo ""
echo "=== SELinux context of the shell (affects what's readable) ==="
$ADB cat /proc/self/attr/current

echo ""
echo "=== getifaddrs availability (Bionic libc, should exist on Android 7+) ==="
$ADB "ls /system/lib64/libc.so 2>/dev/null && echo 'libc present' || echo 'missing'"
$ADB "grep -c getifaddrs /proc/self/maps 2>/dev/null || echo 'cannot grep maps'"
