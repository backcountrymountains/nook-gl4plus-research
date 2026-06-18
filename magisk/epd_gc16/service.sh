#!/system/bin/sh
# Run by Magisk on every boot.
# Makes the AllWinner EPD force_update_mode sysfs node writable by KOReader.
#
# Two-phase approach:
# 1. Early: chmod 666 and initialize the node value (needs root, no SELinux rule needed).
# 2. Post-boot_completed: apply SELinux allow rule then chcon — both must happen together
#    after Android init's last restorecon pass, which resets the sysfs_leds label back
#    to the default sysfs label if chcon is applied too early.

EPD_MODE=/sys/devices/virtual/disp/disp/waveform/force_update_mode

# Phase 1: wait for node, chmod and initialize
i=0
while [ ! -e "$EPD_MODE" ] && [ $i -lt 20 ]; do
    sleep 1
    i=$((i+1))
done

if [ -e "$EPD_MODE" ]; then
    chmod 666 "$EPD_MODE"
    echo 0 > "$EPD_MODE"
fi

# Phase 2: after boot_completed (post-restorecon), add allow rule then relabel.
# chcon must follow magiskpolicy --live so the label is set into the correct policy state.
(
    i=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 120 ]; do
        sleep 1
        i=$((i+1))
    done
    if [ -e "$EPD_MODE" ]; then
        # sysfs_leds lacks mlstrustedobject; the MLS constraint blocks file:write even with
        # an allow rule unless the target type has that attribute. sysfs has it; sysfs_leds
        # does not, which is why the allow rule alone was insufficient.
        magiskpolicy --live "typeattribute sysfs_leds mlstrustedobject"
        magiskpolicy --live "allow untrusted_app sysfs_leds file { getattr open write }"
        chcon u:object_r:sysfs_leds:s0 "$EPD_MODE"
    fi
) &
