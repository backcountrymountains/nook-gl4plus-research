#!/system/bin/sh
# Event-driven handler for two persistent Nook customisations:
#
#   1. slideUnlock suppression
#      sys.mode.slideUnlock is reset to false on every "screen on" event so
#      the Nook never shows the slide-to-unlock screen.  POWERHINT fires
#      during the wake-up sequence, before SystemUI renders the lock screen,
#      so this is both event-driven (no poll timer) and earlier than a poll.
#
#   2. Sleep cover propagation
#      Copies /sdcard/koreader/sleep_cover.png to all Art slots in
#      /system/media/SleepImageNook/ when the cover changes.
#
#      Two triggers:
#        "opening file"  — KOReader opened a book; wait 4s for render then copy.
#        "screen on"     — device woke; copy if cover mtime changed during sleep.
#      Screen-off is NOT used: the window between POWERHINT:screen OFF and
#      kernel suspend is ~7ms, too short for a safe /system remount+copy.
#
# Battery: logcat -s with a two-tag filter blocks in __skb_wait_for_more_packets
# with no timer wakeups.  The slideUnlock setprop and cover stat fire only on
# events (a handful per session), not on any timer.

MODULE_DIR=/data/adb/modules/no_slideunlock
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
                # Reset slideUnlock before SystemUI renders the lock screen.
                setprop sys.mode.slideUnlock false
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
    # logcat exited — reset slideUnlock as a failsafe during the restart gap,
    # then pause briefly before restarting the watch.
    setprop sys.mode.slideUnlock false
    sleep 2
done
