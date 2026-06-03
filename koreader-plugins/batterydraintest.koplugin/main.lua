--[[
Battery Drain Test plugin for KOReader.

Turns pages on a fixed interval and logs battery stats to a TSV file after
each cycle. Designed for measuring real-world e-ink reading drain with deep
sleep between page turns.

Key design decisions:
  - PluginShare.pause_auto_suspend is intentionally NOT set: we want the
    device to enter deep sleep between page turns.
  - UIManager:getElapsedTimeSinceBoot() uses boottime (includes sleep time)
    so the interval accounts correctly for time spent suspended.
  - onSuspend/onResume track sleep duration between page turns.
  - Log is buffered in memory and flushed every FLUSH_EVERY cycles to
    minimise flash writes without risking significant data loss.

Log location: /sdcard/koreader/battery_drain_test.log (TSV format)
Deploy:       push this directory to /sdcard/koreader/plugins/ on the device
Enable:       Reader menu → Tools → Battery Drain Test → Start
--]]

local DataStorage = require("datastorage")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")

-- How often to flush the in-memory log buffer to disk.
-- 5 cycles = at most 5 minutes of data at risk if KOReader crashes.
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

    -- configuration (seconds between page turns)
    interval_s  = 60,

    -- runtime state
    running         = false,
    cycle           = 0,
    task            = nil,
    last_page_time  = nil,   -- UIManager boottime of last page turn

    -- sleep tracking (reset each cycle)
    sleep_count          = 0,
    total_sleep_s        = 0,
    suspend_entered_time = nil,   -- boottime when onSuspend fired

    -- log buffering
    log_path   = nil,
    log_buffer = {},
}

-- ---------------------------------------------------------------------------
-- Sysfs helpers
-- ---------------------------------------------------------------------------

local function read_sysfs_int(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*n")
    f:close()
    return v
end

function BatteryDrainTest:_battery()
    local cap     = read_sysfs_int(SYSFS.capacity)
    local uv      = read_sysfs_int(SYSFS.voltage)
    local ua      = read_sysfs_int(SYSFS.current)
    local ua_avg  = read_sysfs_int(SYSFS.current_avg)
    local chg_raw = read_sysfs_int(SYSFS.charging)
    return {
        capacity       = cap,
        voltage_mv     = uv    and math.floor(uv   / 1000) or nil,
        current_ma     = ua    and math.floor(ua   / 1000) or nil,
        current_avg_ma = ua_avg and math.floor(ua_avg / 1000) or nil,
        charging       = chg_raw == 1,
    }
end

-- ---------------------------------------------------------------------------
-- Log helpers
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
        logger.warn("BatteryDrainTest: could not open log file " .. self.log_path)
    end
end

-- ---------------------------------------------------------------------------
-- Device control
-- ---------------------------------------------------------------------------

function BatteryDrainTest:_disableCharging()
    -- Requires root. Stops current flow to battery while USB stays connected.
    local ok = os.execute("su -c 'echo 0 > " .. SYSFS.charging .. "'")
    logger.info("BatteryDrainTest: disable charging rc=" .. tostring(ok))
end

function BatteryDrainTest:_disableWifi()
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:isWifiOn() then
        NetworkMgr:turnOffWifi()
        logger.info("BatteryDrainTest: WiFi disabled")
    end
end

-- ---------------------------------------------------------------------------
-- Core cycle
-- ---------------------------------------------------------------------------

function BatteryDrainTest:_schedule()
    if not self.running then return end

    local now   = UIManager:getElapsedTimeSinceBoot()
    local delay = self.last_page_time + time.s(self.interval_s) - now

    if delay <= 0 then
        self:_doPageTurn()
        UIManager:scheduleIn(self.interval_s, self.task)
    else
        UIManager:scheduleIn(time.to_number(delay), self.task)
    end
end

function BatteryDrainTest:_doPageTurn()
    self.cycle = self.cycle + 1

    -- Turn the page
    self.ui:handleEvent(Event:new("GotoViewRel", 1))
    self.last_page_time = UIManager:getElapsedTimeSinceBoot()

    -- Sample battery
    local b  = self:_battery()
    local ts = os.date("%H:%M:%S")

    -- Build TSV row
    -- columns: cycle, time, capacity%, voltage_mv, current_ma, current_avg_ma,
    --          sleeps_this_cycle, total_sleep_s_this_cycle
    local row = string.format(
        "%d\t%s\t%s\t%s\t%s\t%s\t%d\t%.0f",
        self.cycle,
        ts,
        b.capacity       ~= nil and tostring(b.capacity)       or "?",
        b.voltage_mv     ~= nil and tostring(b.voltage_mv)     or "?",
        b.current_ma     ~= nil and tostring(b.current_ma)     or "?",
        b.current_avg_ma ~= nil and tostring(b.current_avg_ma) or "?",
        self.sleep_count,
        self.total_sleep_s
    )
    self:_log(row)
    logger.info(string.format(
        "BatteryDrainTest cycle %d: %s%% %smV avg=%smA sleeps=%d sleep_s=%.0f",
        self.cycle,
        tostring(b.capacity), tostring(b.voltage_mv),
        tostring(b.current_avg_ma),
        self.sleep_count, self.total_sleep_s
    ))

    -- Reset per-cycle sleep counters
    self.sleep_count    = 0
    self.total_sleep_s  = 0
end

-- ---------------------------------------------------------------------------
-- Start / stop
-- ---------------------------------------------------------------------------

function BatteryDrainTest:_start()
    if self.running then return end
    self.running        = true
    self.cycle          = 0
    self.sleep_count    = 0
    self.total_sleep_s  = 0
    self.log_buffer     = {}

    self:_disableWifi()
    self:_disableCharging()

    local b = self:_battery()
    local header = string.format(
        "# Battery Drain Test  started=%s  interval=%ds  start_capacity=%s%%  start_voltage=%smV",
        os.date("%Y-%m-%d %H:%M:%S"),
        self.interval_s,
        tostring(b.capacity),
        tostring(b.voltage_mv)
    )
    local cols = "cycle\ttime\tcapacity%\tvoltage_mv\tcurrent_ma\tcurrent_avg_ma\tsleeps\tsleep_s"
    self:_log(header)
    self:_log(cols)
    self:_flush()

    -- Enable suspend/resume tracking now that we are running
    self.onSuspend = self._onSuspend
    self.onResume  = self._onResume

    self.last_page_time = UIManager:getElapsedTimeSinceBoot()
    UIManager:scheduleIn(self.interval_s, self.task)

    logger.info("BatteryDrainTest: started — log at " .. self.log_path)
end

function BatteryDrainTest:_stop()
    if not self.running then return end
    self.running = false
    UIManager:unschedule(self.task)
    self:_flush()

    -- Disable suspend/resume tracking
    self.onSuspend = nil
    self.onResume  = nil

    local b = self:_battery()
    self:_log(string.format(
        "# Stopped at cycle %d  capacity=%s%%  %s",
        self.cycle,
        tostring(b.capacity),
        os.date("%Y-%m-%d %H:%M:%S")
    ))
    self:_flush()
    logger.info("BatteryDrainTest: stopped at cycle " .. self.cycle)
end

-- ---------------------------------------------------------------------------
-- Suspend / resume tracking
-- ---------------------------------------------------------------------------

function BatteryDrainTest:_onSuspend()
    self.suspend_entered_time = UIManager:getElapsedTimeSinceBoot()
    -- Unschedule — timer is meaningless while suspended
    UIManager:unschedule(self.task)
end

function BatteryDrainTest:_onResume()
    if self.suspend_entered_time then
        local slept = UIManager:getElapsedTimeSinceBoot() - self.suspend_entered_time
        local slept_s = time.to_number(slept)
        self.sleep_count   = self.sleep_count + 1
        self.total_sleep_s = self.total_sleep_s + slept_s
        self.suspend_entered_time = nil
        logger.dbg("BatteryDrainTest: resumed after " .. string.format("%.1f", slept_s) .. "s sleep")
    end
    -- Reschedule — _schedule() will calculate remaining delay using boottime
    self:_schedule()
end

-- ---------------------------------------------------------------------------
-- KOReader plugin lifecycle
-- ---------------------------------------------------------------------------

function BatteryDrainTest:init()
    self.log_path = DataStorage:getDataDir() .. "/battery_drain_test.log"
    self.task = function() self:_schedule() end
    self.ui.menu:registerToMainMenu(self)
    logger.info("BatteryDrainTest: initialised, log path=" .. self.log_path)
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
