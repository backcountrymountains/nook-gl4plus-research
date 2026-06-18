# Nook GL4+ — HWC HAL Reverse Engineering
## Goal: per-layer waveform control without root

The existing GC16 implementation writes directly to the sysfs node
`/sys/devices/virtual/disp/disp/waveform/force_update_mode`, which requires a
Magisk module to chmod 666 the node and add SELinux rules. The goal of this
investigation was to find an unprivileged path to waveform control — and
specifically to discover whether GLR16 (REAGL, ghost-cancellation) is reachable
without root, since the sysfs node silently ignores `0x40`.

The investigation confirmed that B&N's Android 8.1 framework exposes
`android.view.SurfaceControl.setRefreshMode(int)` — a per-layer waveform setter
that routes through SurfaceFlinger and HWC without any permission gate.

---

## Tool setup

Blobs pulled from live device over ADB:

```sh
# HAL blobs are in /vendor, not /system/lib/hw (Android 8.1 / Treble partition layout)
adb pull /vendor/lib/hw/hwcomposer.virgo.so   hal-blobs/
adb pull /vendor/lib/hw/gralloc.virgo.so      hal-blobs/
adb pull /vendor/lib/hw/gralloc.default.so    hal-blobs/
adb pull /vendor/bin/epd_ctrl                 hal-blobs/
adb pull /system/lib/libsurfaceflinger.so     hal-blobs/
adb pull /system/lib/libgui.so                hal-blobs/
adb pull /system/framework/arm/boot-framework.vdex  hal-blobs/
```

Note: The suffix is `.virgo`, not `.sunxi` — virgo is the AllWinner board codename
for the GL4+ hardware.

Tools used:
- `strings` — initial string extraction
- `nm -D` — dynamic symbol table
- `readelf --syms` — full symbol table with sizes
- `arm-linux-gnueabihf-objdump -d` — ARM Thumb-2 disassembly (`sudo apt install binutils-arm-linux-gnueabihf`)
- `c++filt` — C++ name demangling
- `jadx` — DEX decompilation (boot-framework.vdex, indirectly)
- `adb shell strings /system/framework/arm/boot-framework.vdex` — framework class method names

---

## Binary inventory

| File | Size | Notes |
|---|---|---|
| `hwcomposer.virgo.so` | 106 KB | AllWinner HWC2 with B&N EPD extensions |
| `gralloc.virgo.so` | 29 KB | Board-specific gralloc |
| `gralloc.default.so` | 21 KB | Generic gralloc (no EPD relevance) |
| `epd_ctrl` | 958 KB | NTX (Netronix) EPD control binary — multi-platform tool |
| `libsurfaceflinger.so` | 1.0 MB | B&N-patched SurfaceFlinger |
| `libgui.so` | 460 KB | B&N-patched libgui with EPDC extensions |

---

## Key finding 1: `hwcomposer.virgo.so` — `hwc_set_layer_refresh_mode`

Strings search (`grep -iE "eink|epd|refresh|waveform|mode|gc16"`) found:

```
_Z26hwc_set_layer_refresh_modeP11hwc2_deviceyyi
layer->refreshMode:%x
%s:Multiple layers set a custom refresh mode!
Layer:%x fd=%d refreshMode is %s
persist.mode.quick / persist.mode.sleep / persist.mode.global
GC16_MODE / GLR16_MODE / GU16_MODE / DU_MODE / A2_MODE / GL16_MODE / GLD16_MODE
DISP_EINK_SET_GC_CNT
eink.display.update.stop
```

Symbol table entry (from `nm -D`):
```
000089f9  T  _Z26hwc_set_layer_refresh_modeP11hwc2_deviceyyi
```

Demangled: `hwc_set_layer_refresh_mode(hwc2_device_t*, uint64_t display, uint64_t layer, int32_t mode)`

This is a proper exported HWC2 symbol — the direct hook from SurfaceFlinger into
the EPD waveform pipeline.

### Disassembly of `hwc_set_layer_refresh_mode` (annotated)

```
000089f8:   push    {r4, r5, r6, r7, lr}
            sub     sp, #4

; ip = layer struct pointer (hwc2_layer_t IS a direct pointer on this implementation)
; lr = mode integer (int32_t, 4th argument, on stack after 64-bit display + 64-bit layer)
            ldr.w   ip, [sp, #24]     ← layer struct pointer (original sp+0)
            ldr.w   lr, [sp, #32]     ← mode (original sp+8)

; Loop: validate that the layer belongs to the specified display (r2:r3 = display_id)
            ldr     r0, [r0, #0]      ← dereference global display list
            ldr     r1, [r0, #0]      ← display count
            cmp     r1, #1
            blt     <error>           ← no displays
loop:
            ldr.w   r5, [r0, r4<<2]  ← layer_array[i]
            ldrd    r6, r7, [r5, #8] ← load display_id stored in layer struct at offset +8
            eors    r7, r3            ← compare high 32-bits
            eors    r6, r2            ← compare low 32-bits
            orrs    r6, r7            ← zero only if both match
            beq     <found>
            adds    r4, #1
            cmp     r4, r1
            blt     loop
            b       <error>           ← layer not found in this display

found:
            cbz     r5, <error>       ← null layer pointer
            movs    r0, #0            ← return HWC2_ERROR_NONE
            str.w   lr, [ip, #36]    ← layer->refreshMode = mode  (offset 0x24 = 36)
            b       <exit>

error:
            blx     __android_log_print
            movs    r0, #2            ← return HWC2_ERROR_BAD_LAYER
exit:
            add     sp, #4
            pop     {r4, r5, r6, r7, pc}
```

**Critical conclusion:** `hwc_set_layer_refresh_mode` is a **pure struct setter**.
It does not write to sysfs or issue any ioctl. It only stores the mode integer at
offset `0x24` in the Layer struct. The actual EPD waveform write happens later in
the composition thread (`submitThreadLoop`), which reads `layer->refreshMode` when
committing the buffer to the display.

### Layer struct field offsets (from comparison across HWC2 setter functions)

| Function | Offset written | Field |
|---|---|---|
| `hwc_set_layer_composition_type` | `[ip, #4]`  = 0x04 | compositionType |
| `hwc_set_layer_blend_mode`       | `[ip, #28]` = 0x1c | blendMode |
| `hwc_set_layer_refresh_mode`     | `[ip, #36]` = 0x24 | **refreshMode** |

All three follow the identical loop-validate-then-store pattern.

---

## Key finding 2: `epd_ctrl` — NTX heritage and `/dev/disp`

`epd_ctrl` is a **Netronix (NTX)** EPD control binary — the developer path leaked in
the binary: `/home/yplin/Project/tools/epd_ctrl`. NTX supplies EPD controller boards
to multiple e-reader OEMs; this binary supports both AllWinner and i.MX (Freescale)
platforms (`gEPDC_IMX_IFA`).

Relevant strings:
```
/dev/disp          ← primary EPD interface (world-readable: crw-rw-rw-)
/dev/sunxi-eink    ← referenced but does NOT exist on GL4+
DISP_EINK_WAIT_FRAME_SYNC_COMPLETE
DISP_EINK_SET_NTX_HANDWRITE_ONOFF
waveform mode ntx %d(0x%x) -> aw %d(0x%x)   ← NTX→AllWinner mode translation
epd ctrl v3.8.20
```

`/dev/sunxi-eink` is not present on the GL4+. All EPD control goes through `/dev/disp`
ioctls. The `epd_ctrl` binary provides direct evidence that the system-level EPD path
uses ioctls, not just sysfs — HWC's composition thread has full ioctl access, which
is why GLR16 (REAGL) works through HWC but not through the sysfs node alone.

---

## Key finding 3: `libgui.so` — complete EPDC call chain

Strings search found these C++ symbols (all exported from `libgui.so`):

```
android::GLConsumer::getEpdc()
android::GLConsumer::getEpdcWithOutClean()
android::Surface::freeEpdcList()
android::Surface::addEpdc(hwc_epdc_llist*)
android::SurfaceControl::setRefreshMode(unsigned int)
android::SurfaceComposerClient::setRefreshMode(sp<IBinder> const&, unsigned int)
android::SurfaceComposerClient::einkChangeUpdateMode(unsigned int)
android::SurfaceComposerClient::einkChangeUpdateQuickMode(unsigned int)
android::Composer::setRefreshMode(sp<SurfaceComposerClient> const&, sp<IBinder> const&, unsigned int)
```

### The `hwc_epdc_llist` per-buffer mechanism

`Surface::addEpdc(hwc_epdc_llist*)` and `GLConsumer::getEpdc()` implement per-buffer
EPDC mode queuing:
- **Producer side (app):** `Surface::addEpdc` attaches a waveform mode to a buffer in
  a linked list on the Surface object. Called before `ANativeWindow_unlockAndPost`.
- **Consumer side (SurfaceFlinger):** `GLConsumer::getEpdc` dequeues the mode when
  compositing that buffer.

Confirmed: libsurfaceflinger.so imports `GLConsumer::getEpdc` (marked `U` — undefined,
resolved from libgui.so). SurfaceFlinger calls `getEpdc()` during composition for ALL
layer types — not just View-rendered ones.

### Why `einkChangeQuickUpdateMode` failed

`einkChangeUpdateMode(uint)` and `einkChangeUpdateQuickMode(uint)` take **no IBinder
argument** — they are global signals to SurfaceFlinger, not per-layer. From
libsurfaceflinger strings: `einkChangeUpdateQuickMode-----------------------(Double Entry)`
— this is a re-entry guard indicating the function triggers an immediate EPD action
(forcing GC16 of the currently-displayed buffer), not a mode flag for the next buffer.

This is the root cause of the "old page flashes" bug described in eink.md. These
methods are architecturally the same as the broadcast intent — they are not what we
want. They were tried as `Surface.einkChangeQuickUpdateMode` in KOReader; the
`SurfaceControl` static equivalent was not separately tried but has the same behavior.

---

## Key finding 4: `libsurfaceflinger.so` — no permission gate on setRefreshMode

Permission-related strings present in libsurfaceflinger:
```
android.permission.ACCESS_SURFACE_FLINGER
android.permission.READ_FRAME_BUFFER
Permission Denial: can't openGlobalTransaction pid=%d, uid<=%d
Permission Denial: can't read framebuffer pid=%d, uid=%d
Permission Denial: can't access SurfaceFlinger pid=%d, uid=%d
  RefreshMode
```

`RefreshMode` appears only in the layer state dump path — not in a permission denial
context. There is **no** `"Permission Denial: can't setRefreshMode"` string, contrasting
with `openGlobalTransaction`, `readFramebuffer`, and `accessSurfaceFlinger` which all
have explicit denial strings.

### Disassembly of `SurfaceComposerClient::setRefreshMode` (from libgui.so)

```
5ca48:  push    {r4, r5, r6, lr}
        sub     sp, #8

; r5 = IBinder sp<>, r4 = mode, r6 = Composer* (from SurfaceComposerClient+20)
        mov     r5, r1      ← sp<IBinder>
        mov     r4, r2      ← mode
        ldr     r6, [r0, #20]  ← SurfaceComposerClient::mComposer

; NO permission check — straight to Composer::setRefreshMode
        mov     r1, sp      ← wrap SurfaceComposerClient in sp<>
        mov     r0, r6
        mov     r2, r5
        mov     r3, r4
        blx     Composer::setRefreshMode   ← Binder IPC to SurfaceFlinger

; stack canary check, return
```

**No `checkCallingPermission`, no UID check, no `ACCESS_SURFACE_FLINGER` guard.**
The client-side call goes straight to `Composer::setRefreshMode` which issues the
Binder IPC to SurfaceFlinger.

---

## Key finding 5: framework VDEX — Java API confirmed

Strings from `adb shell strings /system/framework/arm/boot-framework.vdex`:

```
TRANSACTION_setRefreshMode       ← Binder transaction in ISurfaceComposer
nativeSetRefreshMode             ← JNI bridge method name
setRefreshMode                   ← Java method on SurfaceControl
nativeAddEpdc                    ← JNI for Surface::addEpdc
nativeEinkChangeQuickUpdateMode  ← JNI for einkChangeUpdateQuickMode (global)
nativeEinkChangeUpdateMode       ← JNI for einkChangeUpdateMode (global)
Landroid/view/SurfaceControl;    ← class descriptor
```

The Java class is `android.view.SurfaceControl`. The method `setRefreshMode(int)` is
a non-static (`@hide`) instance method on `SurfaceControl` — it uses `this` object's
IBinder handle, making it **per-layer**. It is accessible via reflection on Android
8.1 (API 27) since the hidden API greylist was not enforced until Android 9.

---

## Complete call chain

```
[Java] android.view.SurfaceControl.setRefreshMode(int mode)
  │  JNI → nativeSetRefreshMode
  ↓
[C++/libgui] android::SurfaceControl::setRefreshMode(uint mode)
  │  calls mClient->setRefreshMode(mHandle, mode)  where mHandle = layer IBinder
  ↓
[C++/libgui] android::SurfaceComposerClient::setRefreshMode(sp<IBinder>, uint)
  │  no permission check
  ↓
[C++/libgui] android::Composer::setRefreshMode(sp<SurfaceComposerClient>, sp<IBinder>, uint)
  │  Binder IPC  (TRANSACTION_setRefreshMode)
  ↓
[libsurfaceflinger] SurfaceFlinger handles transaction
  │  no permission denial string found
  ↓
[hwcomposer.virgo.so] hwc_set_layer_refresh_mode(device, display_id, layer_ptr, mode)
  │  loop validates layer belongs to display
  │  layer->refreshMode = mode   [Layer struct offset 0x24]
  ↓
[submitThreadLoop] composition thread wakes, reads layer->refreshMode
  │  issues /dev/disp ioctl with full frame context (GLR16/REAGL capable)
  ↓
[kernel] EPD driver applies waveform to next committed buffer
```

### Why the timing is correct

`setEpdMode` is called **before** `ANativeWindow_unlockAndPost` (the Lua side
controls this ordering). `hwc_set_layer_refresh_mode` stores the mode in the Layer
struct. HWC's `submitThreadLoop` reads `layer->refreshMode` when the next buffer is
composited — which is after the buffer post. This mirrors exactly how the sysfs path
works: `force_update_mode` is also a persistent register read at buffer-commit time.

### Why the sysfs path still supports GC16 but not GLR16

The sysfs `force_update_mode` node accepts only raw waveform indices. Writing `0x40`
(GLR16) is silently accepted but ignored by the kernel driver — GLR16 requires the
driver to run the REAGL ghost-cancellation algorithm with frame history, which is
only accessible through the full `/dev/disp` ioctl path that HWC uses. The sysfs
node is a simplified interface that bypasses REAGL entirely.

---

## Implementation

**File changed:** `platform/android/luajit-launcher/app/src/main/java/org/koreader/launcher/device/epd/NookEmperorEPDController.kt`

**No other files changed.** Still gated behind `DeviceInfo.Id.NOOK_GL4PLUS` in
`EPDFactory.kt`.

### Reflection chain

```kotlin
// One-time init (lazy, first setEpdMode call)
getViewRootImplFn = View::class.java.getMethod("getViewRootImpl")
val vriClass = Class.forName("android.view.ViewRootImpl")
surfaceControlField = vriClass.getDeclaredField("mSurfaceControl")   // @SuppressLint("BlockedPrivateApi")
surfaceControlField.isAccessible = true
val scClass = Class.forName("android.view.SurfaceControl")
setRefreshModeFn = scClass.getMethod("setRefreshMode", Int::class.javaPrimitiveType)

// Per-call
val vri = getViewRootImplFn.invoke(targetView.rootView)
val sc  = surfaceControlField.get(vri)
setRefreshModeFn.invoke(sc, mode)
```

`ViewRootImpl.mSurfaceControl` exists in AOSP Android 10+. B&N's Android 8.1 may
have backported it (they use SurfaceControl internally for handwriting:
`HandwrittenView$SurfaceControlWithBackgroundForHandwritten`). Whether the field
exists is discovered at runtime — the log line confirms it.

### Mode mapping

| KOReader waveform | SurfaceControl mode | Sysfs mode |
|---|---|---|
| `getWaveformFull()` → GC16 | `0x04` | `0x04` |
| `getWaveformFullUi()` → GLR16 | `0x40` (REAGL, **new**) | `0` (sysfs ignores 0x40) |
| everything else | `0` (GU16 default) | `0` |

### Fallback behavior

If `ViewRootImpl.mSurfaceControl` does not exist on this firmware, `initReflection()`
catches the `NoSuchFieldException` and logs a warning. All subsequent `setEpdMode`
calls fall through to the existing sysfs path unchanged. The Magisk `epd_gc16` module
continues to be required in that case.

---

## What was ruled out

| Approach | Reason discarded |
|---|---|
| `Surface.einkChangeQuickUpdateMode` | Fires GC16 on currently-displayed buffer (wrong frame). Tested and confirmed broken in eink.md |
| `SurfaceControl.einkChangeUpdateMode` (static) | Same behavior — global, no IBinder, triggers immediate refresh not per-buffer mode setting |
| `force_update_mode` sysfs for GLR16 | Silently ignored — REAGL needs ioctl frame context |
| `/dev/disp` ioctls directly from app | World-accessible (`crw-rw-rw-`) but has no EPD ioctls — LCD/HDMI only. Explicitly deprecated upstream |
| Companion transparent View overlay | View and ANativeWindow on separate HWC layers; no guarantee waveform applies to KOReader's layer |
| Gralloc buffer metadata channel | AllWinner gralloc has no documented EPD metadata extension |
