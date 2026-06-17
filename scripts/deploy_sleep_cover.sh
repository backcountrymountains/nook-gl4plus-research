#!/usr/bin/env bash
# Deploy the sleep_cover Magisk module to the Nook GL4+.
# Replaces the old no_slideunlock module directory with sleep_cover.
# Kills and restarts the cover_watcher.sh process live — no reboot needed.
#
# SELinux note: adb push lands files in the shell_data_file context; cp into
# /data/adb/modules/ is blocked even under su. We stage everything in
# /data/local/tmp/ and use cat redirects (which inherit the destination
# context) via a root helper script.

set -e

ADB="adb -H 192.168.1.92 -P 5037"
SCRIPTS="$(dirname "$0")"
SRC="$SCRIPTS/../magisk/sleep_cover"
STAGE=/data/local/tmp/sleep_cover_stage

echo "=== Staging module files ==="
$ADB shell rm -rf "$STAGE"
$ADB shell mkdir -p "$STAGE"
$ADB push "$SRC/module.prop"          "$STAGE/module.prop"
$ADB push "$SRC/service.sh"           "$STAGE/service.sh"
$ADB push "$SRC/cover_watcher.sh"     "$STAGE/cover_watcher.sh"
$ADB push "$SRC/cover_handler.sh"     "$STAGE/cover_handler.sh"
$ADB push "$SCRIPTS/sleep_cover_install.sh" "$STAGE/install.sh"
$ADB shell chmod 755 "$STAGE/install.sh"

echo "=== Running root install script ==="
$ADB shell su -c "sh $STAGE/install.sh"

echo "=== Verifying ==="
NEW=/data/adb/modules/sleep_cover
OLD=/data/adb/modules/no_slideunlock
$ADB shell su -c "ls -la $NEW"
$ADB shell su -c "ls $OLD 2>/dev/null && echo 'ERROR: old module still present' || echo 'old module removed OK'"
echo "Watcher processes:"
$ADB shell su -c "ps -A" | grep -E "cover_watcher|logcat" || echo "WARNING: watcher not found in ps"

echo "=== Done ==="
