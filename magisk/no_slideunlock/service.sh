#!/system/bin/sh
# Run by Magisk on every boot.

MODULE_DIR=/data/adb/modules/no_slideunlock

# Suppress the SystemUI high-temperature warning dialog.
# Persists across reboots via Settings database; we re-apply here in case of
# factory reset.
settings put global show_temperature_warning 0

# Start the event-driven cover watcher in the background.
"$MODULE_DIR/cover_watcher.sh" &

# Poll sys.mode.slideUnlock every 3 seconds.
# System properties cannot use inotify, so polling is required.  3s gives a
# responsive lock-screen bypass without constant CPU wakeups.
while true; do
    if [ "$(getprop sys.mode.slideUnlock)" = "true" ]; then
        setprop sys.mode.slideUnlock false
    fi
    sleep 3
done
