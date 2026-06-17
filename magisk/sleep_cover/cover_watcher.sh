#!/system/bin/sh
# Event-driven sleep cover propagation for the Nook GL4+.
#
# Copies /sdcard/koreader/sleep_cover.png to all Art slots in
# /system/media/SleepImageNook/ when the cover changes.
#
# Two triggers:
#   "opening file"  — KOReader opened a book; wait 4s for render then copy.
#   "screen on"     — device woke; copy if cover mtime changed during sleep.
# Screen-on is the right time to copy: the B&N sleep screen service reads
# the Art files on screen-off (to build the sleep image), not on screen-on,
# so there is no reader that can race against the cp during wake.
# Screen-off is NOT used: the window between POWERHINT:screen OFF and
# kernel suspend is ~7ms — too short for a safe remount+copy, and the Art
# files are actively being consumed by the sleep screen service at that point.
#
# Battery: logcat -s with a two-tag filter blocks in __skb_wait_for_more_packets
# with no timer wakeups.  The cover stat fires only on events (a handful per
# session), not on any timer.

MODULE_DIR=/data/adb/modules/sleep_cover
COVER_FILE=/sdcard/koreader/sleep_cover.png
MTIME_TMP=/data/local/tmp/cover_watcher_mtime

until [ -d /sdcard/koreader ]; do
    sleep 2
done

# On startup: copy if the Art file doesn't match the cover (self-healing after
# a watcher restart that happened while the cover had already changed).
COVER_SZ=$(stat -c %s "$COVER_FILE" 2>/dev/null)
ART_SZ=$(stat -c %s /system/media/SleepImageNook/Art1_bk.png 2>/dev/null)
if [ -n "$COVER_SZ" ] && [ "$COVER_SZ" != "$ART_SZ" ]; then
    "$MODULE_DIR/cover_handler.sh"
fi
stat -c %Y "$COVER_FILE" 2>/dev/null > "$MTIME_TMP" || printf "" > "$MTIME_TMP"

while true; do
    logcat -s KOReader:I POWERHINT:I | while IFS= read -r line; do
        case "$line" in
            *"screen on"*)
                # Copy cover if mtime changed OR if Art file size doesn't match
                # (catches any case where mtime and reality diverged).
                MTIME=$(stat -c %Y "$COVER_FILE" 2>/dev/null)
                COVER_SZ=$(stat -c %s "$COVER_FILE" 2>/dev/null)
                ART_SZ=$(stat -c %s /system/media/SleepImageNook/Art1_bk.png 2>/dev/null)
                LAST=$(cat "$MTIME_TMP" 2>/dev/null)
                if [ -n "$MTIME" ] && { [ "$MTIME" != "$LAST" ] || [ "$COVER_SZ" != "$ART_SZ" ]; }; then
                    printf "%s" "$MTIME" > "$MTIME_TMP"
                    "$MODULE_DIR/cover_handler.sh"
                fi
                ;;
            *"opening file"*)
                # Wait for KOReader to finish rendering the new book's cover.
                sleep 4
                CURRENT=$(stat -c %Y "$COVER_FILE" 2>/dev/null)
                LAST=$(cat "$MTIME_TMP" 2>/dev/null)
                if [ -n "$CURRENT" ] && [ "$CURRENT" != "$LAST" ]; then
                    printf "%s" "$CURRENT" > "$MTIME_TMP"
                    "$MODULE_DIR/cover_handler.sh"
                fi
                ;;
        esac
    done
    # logcat exited — pause briefly before restarting the watch.
    sleep 2
done
