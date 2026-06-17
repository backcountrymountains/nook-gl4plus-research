# Magisk Module Installation Notes — Nook GL4 Plus

Installing a Magisk module manually on this device is not as simple as `adb push`
into `/data/adb/modules/`. This document explains why, and gives two paths for
getting a module installed.

---

## Why `adb push` into `/data/adb/` fails

ADB runs as the `shell` user. `/data/adb/` is owned by root and mode `700`, so the
shell user is rejected outright:

```
adb push myfile.sh /data/adb/modules/my_module/myfile.sh
# → adb: error: stat failed when trying to push: Permission denied
```

## Why `su -c cp` also fails

The natural next attempt is to push to a world-writable staging area and then copy
as root:

```sh
adb push myfile.sh /data/local/tmp/myfile.sh
adb shell su -c 'cp /data/local/tmp/myfile.sh /data/adb/modules/my_module/myfile.sh'
# → cp: /data/adb/modules/my_module/myfile.sh: Permission denied
```

This also fails, even though we are running as root. The reason is **SELinux**.

Files pushed via ADB land with the SELinux context `shell_data_file`:

```
adb shell ls -Z /data/local/tmp/myfile.sh
# u:object_r:shell_data_file:s0  /data/local/tmp/myfile.sh
```

`/data/adb/modules/` has the context `magisk_file`:

```
adb shell su -c 'ls -Z /data/adb/modules/'
# u:object_r:magisk_file:s0  /data/adb/modules/
```

The SELinux policy on this device does not permit writing a `shell_data_file` object
into a `magisk_file` directory, even as root. `cp` copies the file with the source's
context, which is then denied. The `mkdir` call succeeds (creating a `magisk_file`
directory), but the subsequent `cp` into it fails.

## The fix: use `cat` redirects instead of `cp`

Shell I/O redirection (`cat src > dst`) creates the destination file in the
destination directory's own context (`magisk_file`), rather than inheriting the
source's context. SELinux sees a write into a `magisk_file` directory by root
creating a new `magisk_file` object — which is permitted.

```sh
cat /data/local/tmp/myfile.sh > /data/adb/modules/my_module/myfile.sh
# works
```

The practical pattern: push all files to `/data/local/tmp/` via ADB, then push a
small root helper script that uses `cat` redirects to install them into the module
directory, and run it via `su -c "sh /data/local/tmp/install.sh"`.

See `../scripts/deploy_sleep_cover.sh` and `../scripts/sleep_cover_install.sh` for
a working implementation of this pattern.

---

## Manual install of the sleep_cover module

For a user installing the module for the first time (no deploy script).

**Prerequisites:** Magisk installed and working, ADB access.

### Step 1 — Push files to staging

```sh
adb push magisk/sleep_cover/module.prop       /data/local/tmp/sc_module.prop
adb push magisk/sleep_cover/service.sh        /data/local/tmp/sc_service.sh
adb push magisk/sleep_cover/cover_watcher.sh  /data/local/tmp/sc_cover_watcher.sh
adb push magisk/sleep_cover/cover_handler.sh  /data/local/tmp/sc_cover_handler.sh
```

### Step 2 — Install as root using cat redirects

```sh
adb shell su -c 'mkdir -p /data/adb/modules/sleep_cover'
adb shell su -c 'cat /data/local/tmp/sc_module.prop      > /data/adb/modules/sleep_cover/module.prop'
adb shell su -c 'cat /data/local/tmp/sc_service.sh       > /data/adb/modules/sleep_cover/service.sh'
adb shell su -c 'cat /data/local/tmp/sc_cover_watcher.sh > /data/adb/modules/sleep_cover/cover_watcher.sh'
adb shell su -c 'cat /data/local/tmp/sc_cover_handler.sh > /data/adb/modules/sleep_cover/cover_handler.sh'
adb shell su -c 'chmod 755 /data/adb/modules/sleep_cover/service.sh \
                            /data/adb/modules/sleep_cover/cover_watcher.sh \
                            /data/adb/modules/sleep_cover/cover_handler.sh'
```

### Step 3 — Clean up staging

```sh
adb shell rm /data/local/tmp/sc_*.sh /data/local/tmp/sc_module.prop
```

### Step 4 — Reboot

The module's `service.sh` is run by Magisk on boot. A reboot is required to
activate it:

```sh
adb reboot
```

After reboot, verify it is running:

```sh
adb shell su -c 'grep -rl KOReader /proc/*/cmdline 2>/dev/null'
# should print one or more /proc/<pid>/cmdline paths
```

`cover_watcher.sh` is a shell script so it appears as `sh` in `ps`, not by filename.
The reliable indicator is its child `logcat` process, which is always started with
`-s KOReader:I POWERHINT:I`. Grepping `/proc/*/cmdline` finds it by argument string.

To also see the PID:

```sh
adb shell su -c 'for p in /proc/[0-9]*/cmdline; do
    grep -q KOReader "$p" 2>/dev/null && echo "watcher logcat PID: $(basename $(dirname $p))"
done'
```

### Using the deploy script instead

If you have the research repo checked out locally, `scripts/deploy_sleep_cover.sh`
does all of the above and also restarts the watcher live without a reboot:

```sh
bash scripts/deploy_sleep_cover.sh
```

---

## Why not use a Magisk zip?

Magisk's own module installer (via the Magisk app or `magisk --install-module`) uses
a zip file with a specific layout. This would be the cleanest install path, but
generating and maintaining a zip adds build tooling for what is a small personal-use
module. The `cat`-redirect manual install above is a reasonable substitute for
modules of this size.

If the module grows (more files, system overlay patches), packaging it as a proper
Magisk zip would be worth revisiting.
