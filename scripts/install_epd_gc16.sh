#!/bin/bash
set -e

MODULE_DIR="$(cd "$(dirname "$0")/../magisk/epd_gc16" && pwd)"
ZIP=/tmp/epd_gc16.zip

cd "$MODULE_DIR"
rm -f "$ZIP"
zip -j "$ZIP" module.prop service.sh sepolicy.rule

adb push "$ZIP" /data/local/tmp/epd_gc16.zip
adb shell su -c "magisk --install-module /data/local/tmp/epd_gc16.zip"
adb shell rm /data/local/tmp/epd_gc16.zip

echo "Done. Reboot the device to activate v9."
