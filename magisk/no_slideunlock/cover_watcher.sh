#!/system/bin/sh
# Watches /sdcard/koreader for writes to sleep_cover.png via inotifyd.
# inotifyd blocks with zero CPU overhead until a file event fires, then
# calls cover_handler.sh.  This supervisor loop restarts inotifyd if it
# exits (e.g. the directory wasn't mounted yet at boot).

MODULE_DIR=/data/adb/modules/no_slideunlock

# Wait for the sdcard to be mounted before starting the watch.
until [ -d /sdcard/koreader ]; do
    sleep 2
done

while true; do
    # w = closed after write (direct save)
    # m = moved in (atomic rename write)
    inotifyd "$MODULE_DIR/cover_handler.sh" /sdcard/koreader:wm
    # inotifyd exited — brief pause before restarting
    sleep 5
done
