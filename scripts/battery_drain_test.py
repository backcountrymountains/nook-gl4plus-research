#!/usr/bin/env python3
"""
Battery drain test for Nook GL4 Plus running KOReader.

Opens Dungeon Crawler Carl Book 1 in KOReader, disables WiFi and USB charging,
then turns a page (VOLUME_DOWN → LPgFwd) every PAGE_TURN_INTERVAL_S seconds.

Between each page turn, captures logcat filtered to KRP and POWERHINT tags to
confirm the device enters deep sleep (power_enhance_enable=1) before the next
turn is requested.

Log file: claude_battery_drain.log  ← tail -f this to follow live
Ctrl-C to stop — charging and WiFi are always restored on exit.
"""

import logging
import signal
import subprocess
import sys
import time
from datetime import datetime
from urllib.parse import quote

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ADB = ["adb", "-H", "192.168.1.92", "-P", "5037"]

BOOK_PATH = (
    "/sdcard/NOOK/Book/"
    "Dungeon Crawler Carl_ A LitRPG_Gamelit Adventure - Matt Dinniman.epub"
)

PAGE_TURN_INTERVAL_S = 60   # seconds between page turns
STOP_AT_PERCENT = 5         # stop test when battery reaches this level
LOG_FILE = "claude_battery_drain.log"

CHARGING_NODE = "/sys/class/power_supply/battery/charging"
CAPACITY_NODE     = "/sys/class/power_supply/battery/capacity"
VOLTAGE_NODE      = "/sys/class/power_supply/battery/voltage_now"
CURRENT_NODE      = "/sys/class/power_supply/battery/current_now"
CURRENT_AVG_NODE  = "/sys/class/power_supply/battery/current_avg"

# ---------------------------------------------------------------------------
# Logging — all detail goes to file; only cycle summaries reach stdout
# ---------------------------------------------------------------------------

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.DEBUG,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# ADB helpers
# ---------------------------------------------------------------------------

def adb_shell(cmd: str, timeout: int = 10) -> str:
    try:
        result = subprocess.run(
            [*ADB, "shell", cmd],
            capture_output=True, text=True, timeout=timeout,
        )
        output = result.stdout.strip()
        if result.returncode != 0:
            log.warning("adb_shell non-zero rc=%d cmd=%r stderr=%r",
                        result.returncode, cmd, result.stderr.strip())
        return output
    except subprocess.TimeoutExpired:
        log.error("adb_shell timeout after %ds: %r", timeout, cmd)
        return ""


def read_battery() -> dict[str, int | None]:
    def read_int(node: str) -> int | None:
        raw = adb_shell(f"cat {node}")
        try:
            return int(raw)
        except ValueError:
            return None

    capacity = read_int(CAPACITY_NODE)
    voltage_uv = read_int(VOLTAGE_NODE)
    current_ua = read_int(CURRENT_NODE)
    current_avg_ua = read_int(CURRENT_AVG_NODE)
    charging_raw = adb_shell(f"cat {CHARGING_NODE}")

    return {
        "capacity":       capacity,
        "voltage_mv":     voltage_uv // 1000 if voltage_uv is not None else None,
        "current_ma":     current_ua // 1000 if current_ua is not None else None,
        "current_avg_ma": current_avg_ua // 1000 if current_avg_ua is not None else None,
        "charging":       charging_raw == "1",
    }


# ---------------------------------------------------------------------------
# Device state control
# ---------------------------------------------------------------------------

def disable_charging() -> None:
    adb_shell(f"su -c 'echo 0 > {CHARGING_NODE}'")
    time.sleep(1)
    status = adb_shell("cat /sys/class/power_supply/battery/status")
    log.info("charging disabled — status: %s", status)


def enable_charging() -> None:
    adb_shell(f"su -c 'echo 1 > {CHARGING_NODE}'")
    log.info("charging re-enabled")


def disable_wifi() -> None:
    adb_shell("svc wifi disable", timeout=15)
    log.info("wifi disabled")


def enable_wifi() -> None:
    adb_shell("svc wifi enable", timeout=15)
    log.info("wifi re-enabled")


def open_book() -> None:
    # URL-encode the file path for the data URI (spaces → %20, etc.)
    encoded = quote(BOOK_PATH, safe="/")
    uri = f"file://{encoded}"
    cmd = (
        f"am start -a android.intent.action.VIEW "
        f"-d '{uri}' "
        f"-t application/epub+zip "
        f"--activity-single-top "
        f"-n org.koreader.launcher/.MainActivity"
    )
    result = adb_shell(cmd, timeout=15)
    log.info("open_book am start: %s", result)


def page_turn() -> None:
    # Device may be in deep sleep (power_enhance_enable=1); allow extra time
    # for the ADB command to wake the CPU before the keyevent is processed.
    adb_shell("input keyevent 25", timeout=30)   # KEYCODE_VOLUME_DOWN → LPgFwd


# ---------------------------------------------------------------------------
# Logcat capture and analysis
# ---------------------------------------------------------------------------

def start_logcat() -> subprocess.Popen:
    """Start a background logcat process filtered to power-relevant tags."""
    adb_shell("logcat -c")   # clear buffer so we only see post-turn events
    return subprocess.Popen(
        [*ADB, "shell", "logcat", "-s", "KRP:V", "POWERHINT:V", "KOReader:I"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )


def stop_logcat(proc: subprocess.Popen) -> str:
    """Terminate the logcat process and return everything it captured."""
    proc.terminate()
    try:
        stdout, _ = proc.communicate(timeout=3)
        return stdout
    except subprocess.TimeoutExpired:
        proc.kill()
        stdout, _ = proc.communicate()
        return stdout or ""


def analyse_logcat(raw: str, cycle: int) -> bool:
    """
    Parse captured logcat lines. Returns True if deep sleep was confirmed
    (power_enhance_enable=1 seen in KRP output, or POWERHINT screen-off seen).
    """
    lines = [l for l in raw.splitlines() if l.strip()]
    krp_lines      = [l for l in lines if " KRP" in l]
    powerhint_lines = [l for l in lines if "POWERHINT" in l]
    koreader_lines  = [l for l in lines if "KOReader" in l]

    log.debug("cycle %d: %d KRP  %d POWERHINT  %d KOReader lines captured",
              cycle, len(krp_lines), len(powerhint_lines), len(koreader_lines))
    for line in krp_lines + powerhint_lines + koreader_lines:
        log.debug("  logcat: %s", line)

    # KRP writes power_enhance_enable when triggering deep sleep
    deep_sleep_from_krp = any(
        "power_enhance" in l.lower() or "enhance" in l.lower() or "sleep" in l.lower()
        for l in krp_lines
    )
    # POWERHINT fires on screen-off and screen-on transitions
    screen_off_seen = any("screen off" in l.lower() for l in powerhint_lines)

    deep_sleep = deep_sleep_from_krp or screen_off_seen

    if deep_sleep:
        log.info("cycle %d: deep sleep confirmed (krp=%s powerhint_off=%s)",
                 cycle, deep_sleep_from_krp, screen_off_seen)
    else:
        log.warning("cycle %d: deep sleep NOT confirmed in logcat", cycle)

    # Cross-check: read power_enhance_enable directly (may already be 0 if woken)
    pee = adb_shell("settings get system power_enhance_enable")
    log.debug("cycle %d: power_enhance_enable current value = %r", cycle, pee)

    return deep_sleep


# ---------------------------------------------------------------------------
# Cleanup — always run on exit
# ---------------------------------------------------------------------------

_cleaned_up = False

def cleanup(signum: int | None = None, frame: object = None) -> None:
    global _cleaned_up
    if _cleaned_up:
        return
    _cleaned_up = True
    log.info("=== test stopping — restoring device state ===")
    enable_charging()
    enable_wifi()
    log.info("=== battery drain test end ===")
    print("DONE: charging and WiFi restored")
    sys.exit(0)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    signal.signal(signal.SIGINT,  cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    log.info("=== battery drain test start ===")
    log.info("book: %s", BOOK_PATH)
    log.info("page turn interval: %ds", PAGE_TURN_INTERVAL_S)

    batt = read_battery()
    log.info("start: %s%%  %smV  %smA  charging=%s",
             batt["capacity"], batt["voltage_mv"], batt["current_ma"], batt["charging"])
    print(f"START: battery {batt['capacity']}%  |  {batt['voltage_mv']}mV  |  charging={batt['charging']}")

    print(f"Opening book and disabling WiFi + charging...")
    open_book()
    time.sleep(5)   # let KOReader open the book and settle

    disable_wifi()
    time.sleep(2)
    disable_charging()
    time.sleep(2)

    batt = read_battery()
    if batt["charging"]:
        log.error("charging still active after disable — aborting")
        print("ERROR: could not disable charging — check claude_battery_drain.log")
        enable_wifi()
        sys.exit(1)

    log.info("confirmed discharging at %s%%", batt["capacity"])
    print(f"Discharging confirmed at {batt['capacity']}%. Starting page turn loop.")
    print(f"{'Cycle':>6}  {'Time':>8}  {'Battery':>7}  {'Voltage':>8}  {'Inst':>7}  {'Avg':>7}  Sleep?")
    print("-" * 67)

    cycle = 0
    while True:
        cycle += 1
        log.info("--- cycle %d ---", cycle)

        logcat_proc = start_logcat()
        page_turn()
        log.info("cycle %d: page turn sent", cycle)

        # Wait for most of the interval, then terminate logcat and read battery
        time.sleep(PAGE_TURN_INTERVAL_S - 4)
        logcat_raw = stop_logcat(logcat_proc)
        deep_sleep = analyse_logcat(logcat_raw, cycle)
        time.sleep(2)   # brief pause before battery read

        batt = read_battery()
        log.info("cycle %d: %s%%  %smV  inst=%smA  avg=%smA  deep_sleep=%s",
                 cycle, batt["capacity"], batt["voltage_mv"],
                 batt["current_ma"], batt["current_avg_ma"], deep_sleep)

        ts   = datetime.now().strftime("%H:%M:%S")
        cap  = f"{batt['capacity']}%" if batt["capacity"] is not None else "?%"
        mv   = f"{batt['voltage_mv']}mV" if batt["voltage_mv"] is not None else "?mV"
        ma   = f"{batt['current_ma']}mA" if batt["current_ma"] is not None else "?mA"
        mavg = f"{batt['current_avg_ma']}mA" if batt["current_avg_ma"] is not None else "?mA"
        slp  = "YES" if deep_sleep else "NO "

        print(f"{cycle:>6}  {ts:>8}  {cap:>7}  {mv:>8}  {ma:>7}  {mavg:>7}  {slp}")

        if batt["capacity"] is not None and batt["capacity"] <= STOP_AT_PERCENT:
            log.warning("battery at %d%% — stopping test", batt["capacity"])
            print(f"\nSTOP: battery reached {batt['capacity']}%")
            break

    cleanup()


if __name__ == "__main__":
    main()
