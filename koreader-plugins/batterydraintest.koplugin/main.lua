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

local FLUSH_EVERY = 5

local SYSFS = {
    capacity    = "/sys/class/power_supply/battery/capacity",
    voltage     = "/sys/class/power_supply/battery/voltage_now",
    current     = "/sys/class/power_supply/battery/current_now",
    current_avg = "/sys/class/power_supply/battery/current_avg",
    charging    = "/sys/class/power_supply/battery/charging",
}

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
}

-- ---------------------------------------------------------------------------
-- Sysfs
-- ---------------------------------------------------------------------------

local TMP = "/sdcard/koreader/.bdt_tmp"

local function read_int(path)
    -- SELinux blocks direct io.open on sysfs from the KOReader app process.
    -- Write via su to a sdcard tmp file, then read it back normally.
    os.execute("su -c 'cat " .. path .. " > " .. TMP .. " 2>/dev/null'")
    local f = io.open(TMP, "r")
    if not f then return nil end
    local v = f:read("*n")
    f:close()
    os.remove(TMP)
    return v
end

function BatteryDrainTest:_battery()
    local cap    = read_int(SYSFS.capacity)
    local uv     = read_int(SYSFS.voltage)
    local ua     = read_int(SYSFS.current)
    local ua_avg = read_int(SYSFS.current_avg)
    local chg    = read_int(SYSFS.charging)
    return {
        capacity       = cap,
        voltage_mv     = uv    and math.floor(uv    / 1000) or nil,
        current_ma     = ua    and math.floor(ua    / 1000) or nil,
        current_avg_ma = ua_avg and math.floor(ua_avg / 1000) or nil,
        charging       = chg == 1,
    }
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
-- Device control
-- ---------------------------------------------------------------------------

function BatteryDrainTest:_disableCharging()
    os.execute("su -c 'echo 0 > " .. SYSFS.charging .. "'")
    logger.info("BatteryDrainTest: charging disabled")
end

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

    -- Only turn the page if the reader is the topmost widget
    -- (guards against dialogs being open)
    local top = UIManager:getTopmostVisibleWidget() or {}
    if top.name == "ReaderUI" then
        self.ui:handleEvent(Event:new("GotoViewRel", 1))
    else
        logger.dbg("BatteryDrainTest: skipping page turn, top widget=" .. tostring(top.name))
    end

    local b  = self:_battery()
    local ts = os.date("%H:%M:%S")

    -- TSV: cycle, time, capacity%, voltage_mv, current_ma, current_avg_ma,
    --      sleeps_this_cycle, total_sleep_s_this_cycle
    local row = string.format(
        "%d\t%s\t%s\t%s\t%s\t%s\t%d\t%d",
        self.cycle, ts,
        b.capacity       ~= nil and tostring(b.capacity)       or "?",
        b.voltage_mv     ~= nil and tostring(b.voltage_mv)     or "?",
        b.current_ma     ~= nil and tostring(b.current_ma)     or "?",
        b.current_avg_ma ~= nil and tostring(b.current_avg_ma) or "?",
        self.sleep_count,
        math.floor(self.total_sleep_s)
    )
    self:_log(row)

    logger.info(string.format(
        "BatteryDrainTest: cycle %d  %s%%  %smV  avg=%smA  sleeps=%d  sleep_s=%d",
        self.cycle,
        tostring(b.capacity), tostring(b.voltage_mv),
        tostring(b.current_avg_ma),
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
    self.running       = true
    self.cycle         = 0
    self.sleep_count   = 0
    self.total_sleep_s = 0
    self.log_buffer    = {}

    self:_disableWifi()
    self:_disableCharging()

    -- Keep screen on between page turns so the sleep cover doesn't appear.
    -- android.timeout.set(-1) sets FLAG_KEEP_SCREEN_ON — no root needed, proper API.
    local android = require("android")
    android.timeout.set(-1)
    logger.info("BatteryDrainTest: FLAG_KEEP_SCREEN_ON set")

    local b = self:_battery()
    self:_log(string.format(
        "# Battery Drain Test  started=%s  interval=%ds  capacity=%s%%  voltage=%smV",
        os.date("%Y-%m-%d %H:%M:%S"), self.interval_s,
        tostring(b.capacity), tostring(b.voltage_mv)
    ))
    self:_log("cycle\ttime\tcapacity%\tvoltage_mv\tcurrent_ma\tcurrent_avg_ma\tsleeps\tsleep_s")
    self:_flush()

    self.last_page_time = os.time()
    UIManager:scheduleIn(self.interval_s, self.task)
    logger.info("BatteryDrainTest: started — log=" .. self.log_path)
end

function BatteryDrainTest:_stop()
    if not self.running then return end
    self.running = false
    UIManager:unschedule(self.task)

    local b = self:_battery()
    self:_log(string.format(
        "# Stopped  cycle=%d  capacity=%s%%  time=%s",
        self.cycle, tostring(b.capacity), os.date("%Y-%m-%d %H:%M:%S")
    ))
    self:_flush()
    local android = require("android")
    android.timeout.set(0)
    logger.info("BatteryDrainTest: FLAG_KEEP_SCREEN_ON cleared")
    logger.info("BatteryDrainTest: stopped at cycle " .. self.cycle)
end

-- ---------------------------------------------------------------------------
-- Suspend / resume (class-level, always registered, guard on self.running)
-- ---------------------------------------------------------------------------

function BatteryDrainTest:onSuspend()
    if not self.running then return end
    self.suspend_wall_time = os.time()
    UIManager:unschedule(self.task)
    logger.dbg("BatteryDrainTest: suspended")
end

function BatteryDrainTest:onResume()
    if not self.running then return end
    if self.suspend_wall_time then
        local slept = os.time() - self.suspend_wall_time
        self.sleep_count   = self.sleep_count + 1
        self.total_sleep_s = self.total_sleep_s + slept
        self.suspend_wall_time = nil
        logger.dbg("BatteryDrainTest: resumed after " .. slept .. "s")
    end
    self:_schedule()
end

-- ---------------------------------------------------------------------------
-- KOReader lifecycle
-- ---------------------------------------------------------------------------

function BatteryDrainTest:init()
    self.log_path = DataStorage:getDataDir() .. "/battery_drain_test.log"
    self.task = function() self:_schedule() end
    self.ui.menu:registerToMainMenu(self)
    logger.info("BatteryDrainTest: init, log=" .. self.log_path)
end

function BatteryDrainTest:onCloseWidget()
    self:_stop()
    self.task = nil
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
