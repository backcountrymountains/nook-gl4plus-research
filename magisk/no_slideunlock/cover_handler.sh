#!/system/bin/sh
# Copies /sdcard/koreader/sleep_cover.png to all Nook Art slots.
# Called by cover_watcher.sh on mtime change, or manually.

SLEEP_DIR=/system/media/SleepImageNook
COVER_SRC=/sdcard/koreader/sleep_cover.png

mount -o remount,rw /system
for art in Art1_bk.png Art1_wt.png Art2_bk.png Art2_wt.png \
            Art3_bk.png Art3_wt.png Art4_bk.png Art4_wt.png \
            Art5_bk.png Art5_wt.png Art6_wt.png; do
    cp "$COVER_SRC" "$SLEEP_DIR/$art"
done
mount -o remount,ro /system
