--[[
Battery Drain Test plugin for KOReader.

Turns pages on a fixed interval and logs battery stats to a TSV file after
each cycle. Designed for measuring real-world e-ink reading drain with deep
sleep between page turns.

Key design decisions:
  - PluginShare.pause_auto_suspend is intentionally NOT set: we want the
    device to enter deep sleep between page turns.
  - os.time() (wall-clock) is used for interval tracking instead of
    UIManager:getElapsedTimeSinceBoot(). UIManager scheduleIn() uses
    monotonic time which does not advance during suspend, so a 60-second
    timer would never fire if the device sleeps the whole time.
  - onSuspend/onResume are defined at class level (always active) and
    guard on self.running internally. Dynamic assignment proved unreliable.
  - On resume, _schedule() re-evaluates elapsed wall-clock time and turns
    the page immediately if the interval has passed, or reschedules for
    the remaining time if not.
  - RTC wakeup alarm: _setRtcAlarm() writes to /sys/class/rtc/rtc0/wakealarm
    via root so the device wakes from KRP deep sleep at exactly the right time.
    This is the primary mechanism for autonomous unplugged operation.
    The UIManager timer (scheduleIn) is retained as a fallback for when USB
    is connected (KRP deep sleep doesn't actually suspend the CPU then).
  - Log is buffered and flushed every FLUSH_EVERY cycles.

Log location: <koreader data dir>/battery_drain_test.log  (TSV)
Deploy:       push this directory to /sdcard/koreader/plugins/ on device
Enable:       Reader menu → Tools → Battery Drain Test → Start
--]]

local DataStorage = require("datastorage")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local FLUSH_EVERY = 1

local SYSFS_VOLTAGE      = "/sys/class/power_supply/battery/voltage_now"
local SYSFS_CURRENT      = "/sys/class/power_supply/battery/current_now"
local SYSFS_CURRENT_AVG  = "/sys/class/power_supply/battery/current_avg"
local RTC_WAKEALARM      = "/sys/class/rtc/rtc0/wakealarm"

-- io.popen("su -c ...") does not capture output in KOReader's NativeActivity.
-- Pattern that works: os.execute() writes to a tmp file; io.open() reads it back.
local TMP_USB      = "/data/local/tmp/bdt_usb"
local TMP_READINGS = "/data/local/tmp/bdt_readings"

local BatteryDrainTest = WidgetContainer:extend{
    name        = "batterydraintest",
    is_doc_only = true,

    interval_s  = 60,   -- seconds between page turns

    running          = false,
    cycle            = 0,
    task             = nil,
    last_page_time   = 0,   -- os.time() of last page turn (wall-clock)

    -- sleep tracking, reset each cycle
    sleep_count          = 0,
    total_sleep_s        = 0,
    suspend_wall_time    = nil,   -- os.time() when onSuspend fired

    log_path   = nil,
    log_buffer = {},

    -- unplug-wait state (non-nil only while waiting for USB removal)
    _unplug_cancelled = false,
    _unplug_msg       = nil,

}

-- ---------------------------------------------------------------------------
-- Battery reading
-- ---------------------------------------------------------------------------

function BatteryDrainTest:_battery()
    -- Capacity and charging: Android broadcast cache — non-blocking, no root,
    -- safe at any time including during KRP deep sleep.
    local android = require("android")
    local b = {
        capacity      = android.getBatteryLevel(),
        charging      = android.isCharging(),
        voltage_mv    = nil,
        current_ma    = nil,
        current_avg_ma = nil,
    }

    -- Fuel gauge sysfs: requires root; safe only before GotoViewRel (CPU awake).
    -- KRP powers down I2C ~1s after a page turn.
    os.execute(
        "su -c 'cat " .. SYSFS_VOLTAGE .. " "
                      .. SYSFS_CURRENT .. " "
                      .. SYSFS_CURRENT_AVG .. " > " .. TMP_READINGS .. " 2>/dev/null'"
    )
    local f = io.open(TMP_READINGS, "r")
    if f then
        local v_raw   = tonumber(f:read("*l"))
        local i_raw   = tonumber(f:read("*l"))
        local ia_raw  = tonumber(f:read("*l"))
        f:close()
        -- sysfs reports microvolts / microamps; convert to mV / mA
        b.voltage_mv    = v_raw  and math.floor(v_raw  / 1000) or nil
        b.current_ma    = i_raw  and math.floor(i_raw  / 1000) or nil
        b.current_avg_ma = ia_raw and math.floor(ia_raw / 1000) or nil
    end

    return b
end

-- ---------------------------------------------------------------------------
-- RTC wakeup alarm
-- ---------------------------------------------------------------------------

function BatteryDrainTest:_setRtcAlarm()
    -- Write the target wake time to the RTC alarm register so the device
    -- will autonomously wake from KRP deep sleep (mem suspend) after interval_s.
    -- Requires root. The write must complete before KRP enters deep sleep
    -- (which it does ~1s after a page turn), so call this BEFORE GotoViewRel.
    local alarm_ts = os.time() + self.interval_s
    -- Clear existing alarm, then set new one. Both need root.
    os.execute("su -c 'echo 0 > " .. RTC_WAKEALARM .. "'")
    os.execute("su -c 'echo " .. tostring(alarm_ts) .. " > " .. RTC_WAKEALARM
        .. " && cat " .. RTC_WAKEALARM .. " > " .. TMP_READINGS .. "'")
    local f = io.open(TMP_READINGS, "r")
    local readback = f and f:read("*l") or "nil"
    if f then f:close() end
    logger.info("BatteryDrainTest: RTC alarm set=" .. tostring(alarm_ts)
        .. " readback=" .. readback
        .. " target=" .. os.date("%H:%M:%S", alarm_ts))
end

function BatteryDrainTest:_clearRtcAlarm()
    os.execute("su -c 'echo 0 > " .. RTC_WAKEALARM .. "'")
    logger.dbg("BatteryDrainTest: RTC alarm cleared")
end

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------

function BatteryDrainTest:_log(line)
    table.insert(self.log_buffer, line)
    if #self.log_buffer >= FLUSH_EVERY then
        self:_flush()
    end
end

function BatteryDrainTest:_flush()
    if #self.log_buffer == 0 then return end
    local f = io.open(self.log_path, "a")
    if f then
        for _, l in ipairs(self.log_buffer) do
            f:write(l .. "\n")
        end
        f:flush()
        f:close()
        self.log_buffer = {}
    else
        logger.warn("BatteryDrainTest: cannot open " .. self.log_path)
    end
end

-- ---------------------------------------------------------------------------
-- USB detection
-- ---------------------------------------------------------------------------

local function isUsbConnected()
    -- android.isCharging() returns false when FULL (status=5); io.popen doesn't
    -- capture output in KOReader's NativeActivity. Use os.execute() to write
    -- usb/online to a tmp file (root required; Magisk must grant org.koreader.launcher).
    os.execute("su -c 'cat /sys/class/power_supply/usb/online > " .. TMP_USB .. " 2>/dev/null'")
    local f = io.open(TMP_USB, "r")
    if not f then return false end
    local v = f:read("*l")
    f:close()
    return v == "1"
end

-- ---------------------------------------------------------------------------
-- Device control
-- ---------------------------------------------------------------------------

function BatteryDrainTest:_disableWifi()
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:isWifiOn() then
        NetworkMgr:turnOffWifi()
        logger.info("BatteryDrainTest: WiFi disabled")
    end
end

-- ---------------------------------------------------------------------------
-- Page turn cycle
-- ---------------------------------------------------------------------------

function BatteryDrainTest:_schedule()
    if not self.running then return end

    local now     = os.time()
    local elapsed = now - self.last_page_time
    local remaining = self.interval_s - elapsed

    if remaining <= 0 then
        self:_doPageTurn()
        UIManager:scheduleIn(self.interval_s, self.task)
    else
        UIManager:scheduleIn(remaining, self.task)
    end
end

function BatteryDrainTest:_doPageTurn()
    self.cycle = self.cycle + 1
    self.last_page_time = os.time()

    -- Read battery BEFORE the page turn. KRP sets power_enhance_enable=1
    -- ~1 second after a page turn; os.execute("su -c cat") blocks indefinitely
    -- if launched while the CPU is in deep sleep.
    local b  = self:_battery()
    local ts = os.date("%H:%M:%S")

    -- Set RTC alarm before the page turn so it completes before KRP sleeps.
    -- KRP intercepts GotoViewRel and sets deep sleep for 1s after; the su
    -- command here runs while the CPU is still awake.
    self:_setRtcAlarm()

    -- Only turn the page if the reader is the topmost widget
    -- (guards against dialogs being open)
    local top = UIManager:getTopmostVisibleWidget() or {}
    if top.name == "ReaderUI" then
        self.ui:handleEvent(Event:new("GotoViewRel", 1))
    else
        logger.dbg("BatteryDrainTest: skipping page turn, top widget=" .. tostring(top.name))
    end

    -- TSV: cycle, time, capacity%, voltage_mv, current_ma, current_avg_ma, charging, sleeps, sleep_s
    local function fmt(v) return v ~= nil and tostring(v) or "?" end
    local row = string.format(
        "%d\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d",
        self.cycle, ts,
        fmt(b.capacity), fmt(b.voltage_mv), fmt(b.current_ma), fmt(b.current_avg_ma),
        tostring(b.charging),
        self.sleep_count,
        math.floor(self.total_sleep_s)
    )
    self:_log(row)

    logger.info(string.format(
        "BatteryDrainTest: cycle %d  %s%%  %smV  %smA (avg %smA)  charging=%s  sleeps=%d  sleep_s=%d",
        self.cycle,
        fmt(b.capacity), fmt(b.voltage_mv), fmt(b.current_ma), fmt(b.current_avg_ma),
        tostring(b.charging),
        self.sleep_count, math.floor(self.total_sleep_s)
    ))

    self.sleep_count   = 0
    self.total_sleep_s = 0
end

-- ---------------------------------------------------------------------------
-- Start / stop
-- ---------------------------------------------------------------------------

function BatteryDrainTest:_start()
    if self.running then return end
    if isUsbConnected() then
        self:_showUnplugWait()
    else
        self:_beginTest()
    end
end

function BatteryDrainTest:_showUnplugWait()
    -- Cancel any previous pending wait.
    self._unplug_cancelled = true
    if self._unplug_msg then
        UIManager:close(self._unplug_msg)
        self._unplug_msg = nil
    end
    self._unplug_cancelled = false

    local InfoMessage = require("ui/widget/infomessage")
    local msg = InfoMessage:new{
        text = _("Battery Drain Test\n\nUnplug USB to begin. The test will start automatically when USB is removed."),
        dismiss_callback = function()
            -- User tapped to dismiss — treat as cancel.
            self._unplug_cancelled = true
            self._unplug_msg = nil
        end,
    }
    UIManager:show(msg)
    self._unplug_msg = msg

    local android = require("android")
    local function check()
        if self._unplug_cancelled then return end
        if not isUsbConnected() then
            -- USB removed: close dialog and start.
            if self._unplug_msg then
                UIManager:close(self._unplug_msg)
                self._unplug_msg = nil
            end
            self:_beginTest()
        else
            UIManager:scheduleIn(3, check)
        end
    end
    UIManager:scheduleIn(3, check)
end

function BatteryDrainTest:_beginTest()
    if self.running then return end
    self.running       = true
    self.cycle         = 0
    self.sleep_count   = 0
    self.total_sleep_s = 0
    self.log_buffer    = {}

    -- Set log path at test-start time so the date reflects the actual run date.
    self.log_path = DataStorage:getDataDir() .. "/battery_drain_test_" .. os.date("%Y-%m-%d") .. ".log"

    self:_disableWifi()

    -- Keep screen on so the e-ink image stays visible between page turns.
    local android = require("android")
    android.timeout.set(-1)

    local b = self:_battery()
    self:_log(string.format(
        "# Battery Drain Test  started=%s  interval=%ds  capacity=%s%%",
        os.date("%Y-%m-%d %H:%M:%S"), self.interval_s,
        tostring(b.capacity)
    ))
    self:_log("cycle\ttime\tcapacity%\tvoltage_mv\tcurrent_ma\tcurrent_avg_ma\tcharging\tsleeps\tsleep_s")
    self:_flush()

    self.last_page_time = os.time()
    self:_setRtcAlarm()
    UIManager:scheduleIn(self.interval_s, self.task)
    logger.info("BatteryDrainTest: started — log=" .. self.log_path)
end

function BatteryDrainTest:_stop()
    -- Cancel any pending unplug-wait.
    self._unplug_cancelled = true
    if self._unplug_msg then
        UIManager:close(self._unplug_msg)
        self._unplug_msg = nil
    end

    if not self.running then return end
    self.running = false
    UIManager:unschedule(self.task)
    self:_clearRtcAlarm()

    local b = self:_battery()
    self:_log(string.format(
        "# Stopped  cycle=%d  capacity=%s%%  time=%s",
        self.cycle, tostring(b.capacity), os.date("%Y-%m-%d %H:%M:%S")
    ))
    self:_flush()
    local android = require("android")
    android.timeout.set(0)
    logger.info("BatteryDrainTest: stopped at cycle " .. self.cycle)
end

-- ---------------------------------------------------------------------------
-- Suspend / resume (class-level, always registered, guard on self.running)
-- ---------------------------------------------------------------------------

function BatteryDrainTest:onSuspend()
    if not self.running then return end
    self.suspend_wall_time = os.time()
    UIManager:unschedule(self.task)
    logger.info("BatteryDrainTest: onSuspend wall=" .. tostring(self.suspend_wall_time))
end

function BatteryDrainTest:onResume()
    if not self.running then return end
    if self.suspend_wall_time then
        local slept = os.time() - self.suspend_wall_time
        self.sleep_count   = self.sleep_count + 1
        self.total_sleep_s = self.total_sleep_s + slept
        self.suspend_wall_time = nil
        logger.info("BatteryDrainTest: onResume slept=" .. slept .. "s")
    else
        logger.info("BatteryDrainTest: onResume (no suspend_wall_time)")
    end
    -- Re-arm RTC alarm for remaining time. AlarmManager may have overwritten
    -- our alarm while we slept; doing this on every resume fights that race.
    local remaining = self.interval_s - (os.time() - self.last_page_time)
    if remaining > 5 then
        local alarm_ts = os.time() + remaining
        os.execute("su -c 'echo 0 > " .. RTC_WAKEALARM .. "'")
        os.execute("su -c 'echo " .. tostring(alarm_ts) .. " > " .. RTC_WAKEALARM .. "'")
        logger.dbg("BatteryDrainTest: onResume re-armed RTC → " .. os.date("%H:%M:%S", alarm_ts))
    end
    self:_schedule()
end

-- ---------------------------------------------------------------------------
-- ADB flag-file control
-- ---------------------------------------------------------------------------
-- Create /sdcard/koreader/bdt_start (or bdt_stop) from ADB to trigger
-- start/stop without touching the device. Polled every 3s via UIManager.

function BatteryDrainTest:_pollFlags()
    if not self.poller then return end   -- widget closed

    -- When the test is running, ADB can't reach us (USB is out), and
    -- isUsbConnected() spawns a su process every poll — skip entirely.
    if self.running then
        UIManager:scheduleIn(3, self.poller)
        return
    end

    local function check(name, action)
        local path = DataStorage:getDataDir() .. "/" .. name
        local f = io.open(path, "r")
        if f then
            f:close()
            os.remove(path)
            action()
        end
    end

    check("bdt_start", function() self:_start() end)
    check("bdt_stop",  function() self:_stop()  end)

    UIManager:scheduleIn(3, self.poller)
end

-- ---------------------------------------------------------------------------
-- KOReader lifecycle
-- ---------------------------------------------------------------------------

function BatteryDrainTest:init()
    -- Placeholder shown in the menu before the first run; _beginTest() sets the real path.
    self.log_path = DataStorage:getDataDir() .. "/battery_drain_test_" .. os.date("%Y-%m-%d") .. ".log"
    self.task   = function() self:_schedule()   end
    self.poller = function() self:_pollFlags()  end
    self.ui.menu:registerToMainMenu(self)
    UIManager:scheduleIn(3, self.poller)
    logger.info("BatteryDrainTest: init, log=" .. self.log_path)
end

function BatteryDrainTest:onCloseWidget()
    self:_stop()   -- also cancels any pending unplug-wait
    UIManager:unschedule(self.poller)
    self.task   = nil
    self.poller = nil
end

function BatteryDrainTest:onCloseDocument()
    self:_stop()
end

function BatteryDrainTest:onFlushSettings()
    self:_flush()
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

function BatteryDrainTest:addToMainMenu(menu_items)
    menu_items.battery_drain_test = {
        sorting_hint = "tools",
        text_func = function()
            if self.running then
                return _("Battery Drain Test (running — cycle ") .. self.cycle .. ")"
            end
            return _("Battery Drain Test")
        end,
        sub_item_table = {
            {
                text = _("Start (60s page interval)"),
                enabled_func = function() return not self.running end,
                callback = function() self:_start() end,
            },
            {
                text = _("Stop"),
                enabled_func = function() return self.running end,
                callback = function() self:_stop() end,
            },
            {
                text_func = function()
                    return _("Log: ") .. self.log_path
                end,
                enabled_func = function() return false end,
                callback = function() end,
            },
        },
    }
end

return BatteryDrainTest
