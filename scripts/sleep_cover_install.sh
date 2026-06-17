#!/system/bin/sh
# Root helper — runs on the device. Called by deploy_sleep_cover.sh.
set -e
STAGE=/data/local/tmp/sleep_cover_stage
NEW=/data/adb/modules/sleep_cover
OLD=/data/adb/modules/no_slideunlock

mkdir -p "$NEW"
for f in module.prop service.sh cover_watcher.sh cover_handler.sh; do
    cat "$STAGE/$f" > "$NEW/$f"
done
chmod 755 "$NEW/service.sh" "$NEW/cover_watcher.sh" "$NEW/cover_handler.sh"

pkill -f 'logcat -s KOReader' 2>/dev/null || true
pkill -f cover_watcher 2>/dev/null || true
sleep 1

rm -rf "$OLD"

nohup "$NEW/cover_watcher.sh" >/dev/null 2>&1 &

rm -rf "$STAGE"
echo "install OK"
