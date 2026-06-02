#!/system/bin/sh
# Called by inotifyd: $1=events $2=watched_dir $3=filename
# Copies the KOReader sleep cover to all Nook Art slots.

[ "$3" = "sleep_cover.png" ] || exit 0

SLEEP_DIR=/system/media/SleepImageNook
COVER_SRC="$2/$3"

mount -o remount,rw /system
for art in Art1_bk.png Art1_wt.png Art2_bk.png Art2_wt.png \
            Art3_bk.png Art3_wt.png Art4_bk.png Art4_wt.png \
            Art5_bk.png Art5_wt.png Art6_wt.png; do
    cp "$COVER_SRC" "$SLEEP_DIR/$art"
done
mount -o remount,ro /system
