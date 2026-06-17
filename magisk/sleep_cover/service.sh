#!/system/bin/sh
# Run by Magisk on every boot.
# All event-driven logic lives in cover_watcher.sh (logcat-based, no poll timers).

MODULE_DIR=/data/adb/modules/sleep_cover

# Suppress the SystemUI high-temperature warning dialog.
# Persists across reboots via Settings database; re-applied here in case of
# factory reset.
settings put global show_temperature_warning 0

# Start the event-driven watcher for sleep cover propagation.
"$MODULE_DIR/cover_watcher.sh" &
