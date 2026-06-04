/*
 * bdt_wakeup — battery drain test wakeup driver for Nook GL4+ / KOReader
 *
 * Uses CLOCK_BOOTTIME_ALARM timerfd to wake from AllWinner KRP deep sleep.
 * Unlike a raw RTC wakealarm write, the kernel holds a wakelock automatically
 * when this timer fires, giving us a CPU window before the device re-suspends.
 *
 * Startup:
 *   Polls usb/online every 2s. Arms the 60-second timer the moment USB
 *   is physically removed. Safe to launch before unplugging.
 *
 * USB reconnect during test:
 *   Detected each cycle. Binary pauses (stops sending key events, stops
 *   arming timer), logs "paused", and waits for USB to be removed again.
 *   Resume is automatic — no restart needed. This lets you plug in to check
 *   the log mid-test without losing the session.
 *
 * Stopping:
 *   - Via ADB:    adb shell su -c 'kill $(cat /data/local/tmp/bdt_wakeup.pid)'
 *   - Via device: delete /sdcard/koreader/bdt_running (e.g. from KOReader's
 *                 file browser); binary checks each cycle and exits cleanly.
 *
 * Per-cycle order (while USB is disconnected):
 *   1. read() blocks           → device free to enter KRP mem suspend
 *   2. Timer fires             → kernel wakes, wakelock held, read() returns
 *   3. Check USB / stop file   → pause or exit if needed
 *   4. Read battery sysfs      → safe: fully awake, I2C powered, wakelock held
 *   5. Log to file
 *   6. Check KOReader running  → skip keyevent if not foreground
 *   7. KEYCODE_WAKEUP + input tap → KRP renders page, schedules sleep ~1s later
 *   8. Return to read()        → KRP deep sleep fires, we block until next alarm
 *
 * Build:
 *   CC=<ndk>/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi21-clang
 *   $CC -O2 -o bdt_wakeup bdt_wakeup.c
 *
 * Deploy:
 *   adb push bdt_wakeup /data/local/tmp/
 *   adb shell 'su 0 -c "chmod +x /data/local/tmp/bdt_wakeup"'
 *   adb shell 'su 0 -c "/data/local/tmp/bdt_wakeup"'
 *   # binary self-daemonizes (fork+setsid), su returns immediately
 *   # unplug USB — timer starts counting from disconnect moment
 */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <sys/timerfd.h>
#include <sys/types.h>
#include <fcntl.h>

#define LOG_PATH      "/sdcard/koreader/bdt_external.log"
#define PID_PATH      "/data/local/tmp/bdt_wakeup.pid"
#define SENTINEL      "/sdcard/koreader/bdt_running"
#define INTERVAL_SEC  60

/* CLOCK_BOOTTIME_ALARM (9): advances during suspend, wakes device on expiry,
 * kernel holds wakelock automatically on delivery. */
#ifndef CLOCK_BOOTTIME_ALARM
#define CLOCK_BOOTTIME_ALARM 9
#endif

static volatile int g_running = 1;

static void on_signal(int sig) { (void)sig; g_running = 0; }

static long read_sysfs(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    long v = -1;
    fscanf(f, "%ld", &v);
    fclose(f);
    return v;
}

static int usb_connected(void) {
    return read_sysfs("/sys/class/power_supply/usb/online") == 1;
}

/* Returns 1 if the sentinel file has been deleted (stop requested). */
static int stop_requested(void) {
    FILE *f = fopen(SENTINEL, "r");
    if (!f) return 1;   /* file gone → stop */
    fclose(f);
    return 0;
}

static int koreader_running(void) {
    return system("pgrep -f org.koreader.launcher > /dev/null 2>&1") == 0;
}

static void logf(FILE *log, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(log, fmt, ap);
    va_end(ap);
    fflush(log);
}

/* Wait until USB is disconnected. Returns 0 if killed while waiting. */
static int wait_for_usb_disconnect(FILE *log) {
    while (g_running && !stop_requested()) {
        if (!usb_connected()) return 1;
        sleep(2);
    }
    return 0;
}

/* Arm or re-arm the timerfd for one interval from now. */
static void arm_timer(int tfd) {
    struct itimerspec ts = {
        .it_interval = { .tv_sec = INTERVAL_SEC, .tv_nsec = 0 },
        .it_value    = { .tv_sec = INTERVAL_SEC, .tv_nsec = 0 },
    };
    timerfd_settime(tfd, 0, &ts, NULL);
}

/* Disarm the timerfd (stop it from firing). */
static void disarm_timer(int tfd) {
    struct itimerspec ts = { {0,0}, {0,0} };
    timerfd_settime(tfd, 0, &ts, NULL);
}

int main(void) {
    /* Fork into background so 'su 0 -c bdt_wakeup' returns immediately.
     * fork() preserves uid=0 and all capabilities in the child. */
    {
        pid_t pid = fork();
        if (pid < 0) { perror("fork"); return 1; }
        if (pid > 0) return 0;  /* parent exits — su shell returns to caller */
        setsid();               /* detach from terminal/session */
        /* Redirect stdin/stdout/stderr to /dev/null */
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) { dup2(devnull, 0); dup2(devnull, 1); dup2(devnull, 2); close(devnull); }
    }

    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);

    FILE *pf = fopen(PID_PATH, "w");
    if (pf) { fprintf(pf, "%d\n", getpid()); fclose(pf); }

    /* Sentinel: delete this file from the device to stop the binary. */
    FILE *sf = fopen(SENTINEL, "w");
    if (sf) fclose(sf);

    FILE *log = fopen(LOG_PATH, "a");
    if (!log) { perror("fopen log"); return 1; }

    int tfd = timerfd_create(CLOCK_BOOTTIME_ALARM, TFD_CLOEXEC);
    if (tfd < 0) {
        logf(log, "# ERROR: timerfd_create(CLOCK_BOOTTIME_ALARM): %s\n",
             strerror(errno));
        fclose(log);
        return 1;
    }

    /* --- Wait for initial USB disconnect --- */
    logf(log, "# bdt_external: pid=%d, waiting for USB disconnect...\n",
         getpid());
    if (!wait_for_usb_disconnect(log)) {
        logf(log, "# bdt_external: stopped before USB was removed\n");
        fclose(log);
        return 0;
    }

    /* Log session start */
    time_t now = time(NULL);
    long cap0 = read_sysfs("/sys/class/power_supply/battery/capacity");
    logf(log, "# bdt_external started=%s interval=%ds capacity=%ld%%\n",
         ctime(&now), INTERVAL_SEC, cap0);
    logf(log, "cycle\ttime\tcapacity%%\tvoltage_mv\tcurrent_ma\tcurrent_avg_ma\n");

    arm_timer(tfd);
    int cycle = 0;

    while (g_running) {
        /* Block here — device is free to enter KRP deep sleep. */
        uint64_t expirations;
        ssize_t r = read(tfd, &expirations, sizeof(expirations));
        if (r < 0) {
            if (errno == EINTR) continue;
            perror("read timerfd");
            break;
        }

        /* Kernel wakelock is held. Check stop conditions first. */
        if (stop_requested()) break;

        if (usb_connected()) {
            /* USB reconnected mid-test — pause until it's removed again. */
            disarm_timer(tfd);
            now = time(NULL);
            logf(log, "# paused (USB connected) at %s", ctime(&now));
            if (!wait_for_usb_disconnect(log)) break;
            now = time(NULL);
            logf(log, "# resumed (USB removed) at %s", ctime(&now));
            arm_timer(tfd);
            continue;  /* wait for next full interval before turning page */
        }

        cycle += (int)expirations;

        /*
         * Read battery before the key event. We are fully awake with the
         * kernel wakelock held. KRP will power down I2C ~1s AFTER the
         * key event, so these sysfs reads are safe.
         */
        long voltage  = read_sysfs("/sys/class/power_supply/battery/voltage_now");
        long current  = read_sysfs("/sys/class/power_supply/battery/current_now");
        long curr_avg = read_sysfs("/sys/class/power_supply/battery/current_avg");
        long cap      = read_sysfs("/sys/class/power_supply/battery/capacity");

        now = time(NULL);
        struct tm *t = localtime(&now);
        logf(log, "%d\t%02d:%02d:%02d\t%ld\t%ld\t%ld\t%ld\n",
             cycle,
             t->tm_hour, t->tm_min, t->tm_sec,
             cap,
             voltage  / 1000L,
             current  / 1000L,
             curr_avg / 1000L);

        /* Send page turn only while KOReader is the foreground app.
         * The touchscreen digitizer may not be ready the instant the alarm
         * fires, so we wake the input stack first, wait 1s, then tap. */
        if (koreader_running()) {
            system("input keyevent 224");  /* KEYCODE_WAKEUP — brings input stack online */
            sleep(1);
            system("input tap 1400 702");  /* right-center of 1872x1404 = next page */
            /*
             * KRP intercepts the tap, renders the next page, then schedules
             * power_enhance_enable=1 (mem suspend) ~1s later. We return to
             * read() well within that window so KRP can sleep undisturbed.
             */
        } else {
            logf(log, "# cycle %d: KOReader not running, skipping keyevent\n",
                 cycle);
        }
    }

    now = time(NULL);
    long cap_f = read_sysfs("/sys/class/power_supply/battery/capacity");
    logf(log, "# stopped  cycle=%d  capacity=%ld%%  time=%s",
         cycle, cap_f, ctime(&now));
    fclose(log);
    close(tfd);
    unlink(PID_PATH);
    unlink(SENTINEL);
    return 0;
}
