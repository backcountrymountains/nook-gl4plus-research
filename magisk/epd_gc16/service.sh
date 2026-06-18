#!/system/bin/sh
# Run by Magisk on every boot.
# Makes the AllWinner EPD force_update_mode sysfs node world-writable so
# KOReader can set GC16 waveform without root at runtime.

EPD_MODE=/sys/devices/virtual/disp/disp/waveform/force_update_mode

# Wait until the sysfs node appears (virtual fs, should be immediate but be safe).
i=0
while [ ! -e "$EPD_MODE" ] && [ $i -lt 20 ]; do
    sleep 1
    i=$((i+1))
done

if [ -e "$EPD_MODE" ]; then
    chmod 666 "$EPD_MODE"
    # Reset to 0 (no forced mode) — default GU16 waveform until KOReader sets it.
    echo 0 > "$EPD_MODE"
fi
