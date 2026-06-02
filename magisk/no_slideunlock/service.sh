#!/system/bin/sh
# Watch sys.mode.slideUnlock and reset it to false whenever PowerManagerService sets it.
# Also watches /sdcard/koreader/sleep_cover.png (written by KOReader's built-in
# coverimage plugin) and copies it into all /system/media/SleepImageNook/ Art slots
# whenever the file is updated (i.e. a new book was opened).
# Suppresses the SystemUI temperature warning dialog on boot via Settings.Global.

SLEEP_DIR=/system/media/SleepImageNook
COVER_SRC=/sdcard/koreader/sleep_cover.png
TIMESTAMP=/data/local/tmp/nook_sleep_cover_ts

# Suppress the high-temperature warning dialog shown by com.android.systemui PowerUI.
# show_temperature_warning=0 in Settings.Global disables it; this survives reboot but
# not a factory reset, so we re-apply it here each boot.
settings put global show_temperature_warning 0

copy_cover() {
    # /system is mounted ro at runtime; remount rw for the copy, then restore.
    mount -o remount,rw /system
    for art in Art1_bk.png Art1_wt.png Art2_bk.png Art2_wt.png \
                Art3_bk.png Art3_wt.png Art4_bk.png Art4_wt.png \
                Art5_bk.png Art5_wt.png Art6_wt.png; do
        cp "$COVER_SRC" "$SLEEP_DIR/$art"
    done
    mount -o remount,ro /system
}

while true; do
    val=$(getprop sys.mode.slideUnlock)
    if [ "$val" = "true" ]; then
        setprop sys.mode.slideUnlock false
    fi

    if [ -f "$COVER_SRC" ]; then
        if [ ! -f "$TIMESTAMP" ] || [ "$COVER_SRC" -nt "$TIMESTAMP" ]; then
            touch "$TIMESTAMP"
            copy_cover
        fi
    fi

    sleep 1
done
