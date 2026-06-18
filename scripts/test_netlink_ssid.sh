#!/bin/bash
# Test if nl80211 Netlink SSID query works from the shell (u:r:shell:s0).
# If it fails here, it will definitely fail from untrusted_app.

echo "=== SELinux context ==="
adb shell cat /proc/self/attr/current

echo ""
echo "=== Try reading SSID via iw (uses nl80211) ==="
adb shell "iw dev wlan0 link 2>&1 || echo 'iw not available'"

echo ""
echo "=== Try nl80211 via ip (fallback) ==="
adb shell "ip link show wlan0 2>&1"

echo ""
echo "=== Check if wpa_supplicant socket is accessible ==="
adb shell "ls -la /data/misc/wifi/sockets/ 2>/dev/null || ls -la /var/run/wpa_supplicant/ 2>/dev/null || echo 'socket not accessible from shell'"

echo ""
echo "=== Check logcat for any SELinux denials after our probes ==="
adb shell "logcat -d 2>/dev/null | grep -i 'avc.*denied.*netlink\|avc.*denied.*wlan\|avc.*denied.*wifi' | tail -10 || echo 'no relevant avc denials'"
