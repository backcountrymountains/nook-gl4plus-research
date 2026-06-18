#!/system/bin/sh
# Run by Magisk on every boot.
# Makes the AllWinner EPD force_update_mode sysfs node world-writable
# so KOReader can write it without root.

EPD_MODE=/sys/devices/virtual/disp/disp/waveform/force_update_mode

i=0
while [ ! -e "$EPD_MODE" ] && [ $i -lt 20 ]; do
    sleep 1
    i=$((i+1))
done

if [ -e "$EPD_MODE" ]; then
    chmod 666 "$EPD_MODE"
    echo 0 > "$EPD_MODE"
fi
