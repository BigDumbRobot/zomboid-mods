-- KIPN_Preferences.lua
--
-- Per-player DISPLAY preferences and the shared formatters that
-- apply them: temperature (F/C), measurements (imperial/metric),
-- clock (12/24 hour) and date order (MM/DD vs DD/MM).
--
-- Every preference defaults to "auto", which follows the player's
-- own vanilla game options:
--
--   temperature  Options > Display "Temperature" (Celsius toggle)
--   clock        Options > Display "Clock" 12/24 hour
--   date         Options > Display "Clock format" month/day order
--   units        no vanilla option -- follows the RESOLVED
--                temperature choice (Fahrenheit -> imperial)
--
-- Players override them from the terminal's USER PREFERENCES
-- program (KIPN_UserPreferences.lua).
--
-- STORAGE:
--
-- These are personal display choices, not server configuration, so
-- they live in a small client-side file (Zomboid/Lua/
-- KIPN_Preferences.ini) and follow the player across characters,
-- saves and servers. They are never sent to the server.
--
-- Any screen -- including companion mods -- should format values
-- through these functions rather than hard-coding units:
--
--   local Prefs = KIPN.Client.Preferences
--   Prefs.FormatTemperature(celsius)          -- "68F" / "20C"
--   Prefs.FormatTemperature(celsius, true)    -- rounded to whole
--   Prefs.FormatDistance(meters)              -- "3.2 mi" / "5.2 km"
--   Prefs.FormatWeight(kg)                    -- "14.5 lb" / "6.6 kg"
--   Prefs.FormatTime(hour, minute)            -- "2:45 PM" / "14:45"
--   Prefs.FormatDate(year, month, day)        -- month is 1-12
--
-- File:
--   media/lua/client/KIPN_Preferences.lua

if not KIPN then
    error("[KIPN_Preferences] KIPN core is not initialized.")
end

KIPN.Client = KIPN.Client or {}

local Prefs = {}

KIPN.Client.Preferences = Prefs

Prefs.FILE = "KIPN_Preferences.ini"

--------------------------------------------------------------------
-- OPTIONS
--
-- Ordered choices per preference; the first is the default.
--------------------------------------------------------------------

Prefs.Choices = {
    temperature = { "auto", "fahrenheit", "celsius" },
    units = { "auto", "imperial", "metric" },
    clock = { "auto", "12", "24" },
    date = { "auto", "mdy", "dmy" },
}

Prefs.values = {
    temperature = "auto",
    units = "auto",
    clock = "auto",
    date = "auto",
}

-- Bumped on every change so cached, formatted text (e.g. the
-- terminal clock) knows to rebuild.
Prefs.version = 0

local loaded = false

local function isValid(key, value)

    local choices = Prefs.Choices[key]

    if not choices then
        return false
    end

    for _, choice in ipairs(choices) do
        if choice == value then
            return true
        end
    end

    return false
end

--------------------------------------------------------------------
-- LOAD / SAVE
--------------------------------------------------------------------

function Prefs.Load()

    loaded = true

    local ok, reader =
        pcall(getFileReader, Prefs.FILE, false)

    if not ok or not reader then
        return
    end

    while true do

        local line = reader:readLine()

        if line == nil then
            break
        end

        local key, value =
            string.match(line, "^%s*([%w_]+)%s*=%s*([%w_]+)%s*$")

        if key and isValid(key, value) then
            Prefs.values[key] = value
        end
    end

    reader:close()

    Prefs.version = Prefs.version + 1
end

function Prefs.Save()

    local ok, writer =
        pcall(getFileWriter, Prefs.FILE, true, false)

    if not ok or not writer then

        KIPN.Logger.Warn(
            "KIPN_Preferences: unable to write " .. Prefs.FILE
        )

        return
    end

    for _, key in ipairs({ "temperature", "units", "clock", "date" }) do
        writer:write(key .. "=" .. Prefs.values[key] .. "\n")
    end

    writer:close()
end

local function ensureLoaded()

    if not loaded then
        Prefs.Load()
    end
end

function Prefs.Get(key)

    ensureLoaded()

    return Prefs.values[key]
end

function Prefs.Set(key, value)

    ensureLoaded()

    if not isValid(key, value)
        or Prefs.values[key] == value then

        return false
    end

    Prefs.values[key] = value
    Prefs.version = Prefs.version + 1

    Prefs.Save()

    return true
end

--------------------------------------------------------------------
-- RESOLUTION
--
-- Turns "auto" into a concrete choice from the vanilla game
-- options. Every getter is pcall-guarded: a missing Core option
-- falls back to the vanilla default rather than breaking a screen.
--------------------------------------------------------------------

local function coreOption(read, fallback)

    local ok, result =
        pcall(
            function()
                return read(getCore())
            end
        )

    if ok and result ~= nil then
        return result
    end

    return fallback
end

-- What each "auto" choice resolves to, regardless of the player's
-- current override (used for the AUTO button labels).

function Prefs.AutoIsCelsius()
    return coreOption(function(core) return core:getOptionDisplayAsCelsius() end, true) == true
end

function Prefs.AutoIsMetric()
    -- No vanilla option: follows the RESOLVED temperature choice.
    return Prefs.IsCelsius()
end

function Prefs.AutoIs24Hour()
    return coreOption(function(core) return core:getOptionClock24Hour() end, true) == true
end

function Prefs.AutoIsDayFirst()
    -- Vanilla clockFormat: 1 = month/day, 2 = day/month.
    return coreOption(function(core) return core:getOptionClockFormat() end, 1) == 2
end

function Prefs.IsCelsius()

    local value = Prefs.Get("temperature")

    if value == "celsius" then
        return true
    elseif value == "fahrenheit" then
        return false
    end

    return Prefs.AutoIsCelsius()
end

function Prefs.IsMetric()

    local value = Prefs.Get("units")

    if value == "metric" then
        return true
    elseif value == "imperial" then
        return false
    end

    return Prefs.AutoIsMetric()
end

function Prefs.Is24Hour()

    local value = Prefs.Get("clock")

    if value == "24" then
        return true
    elseif value == "12" then
        return false
    end

    return Prefs.AutoIs24Hour()
end

function Prefs.IsDayFirst()

    local value = Prefs.Get("date")

    if value == "dmy" then
        return true
    elseif value == "mdy" then
        return false
    end

    return Prefs.AutoIsDayFirst()
end

-- Changes whenever any resolved choice changes -- including a
-- vanilla option flipping underneath an "auto" preference.
function Prefs.Signature()

    return table.concat({
        Prefs.IsCelsius() and "C" or "F",
        Prefs.IsMetric() and "M" or "I",
        Prefs.Is24Hour() and "24" or "12",
        Prefs.IsDayFirst() and "DMY" or "MDY",
    }, ":")
end

--------------------------------------------------------------------
-- FORMATTERS
--------------------------------------------------------------------

local function roundTo(value, places)

    local m = 10 ^ (places or 0)

    return math.floor(value * m + 0.5) / m
end

function Prefs.FormatTemperature(celsius, rounded)

    if type(celsius) ~= "number" then
        return "--"
    end

    local value = celsius
    local suffix = "C"

    if not Prefs.IsCelsius() then
        value = celsius * 9 / 5 + 32
        suffix = "F"
    end

    if rounded then
        return string.format("%d", roundTo(value)) .. suffix
    end

    return string.format("%.1f", roundTo(value, 1)) .. suffix
end

function Prefs.FormatDistance(meters)

    meters = tonumber(meters) or 0

    if Prefs.IsMetric() then

        if meters >= 1000 then
            return string.format("%.1f km", meters / 1000)
        end

        return string.format("%d m", roundTo(meters))
    end

    local miles = meters / 1609.344

    if miles >= 0.2 then
        return string.format("%.1f mi", miles)
    end

    return string.format("%d ft", roundTo(meters * 3.28084))
end

function Prefs.FormatWeight(kg)

    kg = tonumber(kg) or 0

    if Prefs.IsMetric() then
        return string.format("%.1f kg", kg)
    end

    return string.format("%.1f lb", kg * 2.20462)
end

function Prefs.FormatTime(hour, minute)

    hour = math.floor(tonumber(hour) or 0)
    minute = math.floor(tonumber(minute) or 0)

    if Prefs.Is24Hour() then
        return string.format("%02d:%02d", hour, minute)
    end

    local suffix = hour < 12 and "AM" or "PM"
    local h12 = hour % 12

    if h12 == 0 then
        h12 = 12
    end

    return string.format("%d:%02d %s", h12, minute, suffix)
end

-- month is 1-12 (NOT PZ's zero-based GameTime month).
function Prefs.FormatDate(year, month, day)

    year = math.floor(tonumber(year) or 0)
    month = math.floor(tonumber(month) or 0)
    day = math.floor(tonumber(day) or 0)

    if Prefs.IsDayFirst() then
        return string.format("%02d/%02d/%04d", day, month, year)
    end

    return string.format("%02d/%02d/%04d", month, day, year)
end

function Prefs.FormatDateTime(year, month, day, hour, minute)

    return Prefs.FormatDate(year, month, day)
        .. " "
        .. Prefs.FormatTime(hour, minute)
end

-- Overrides accepted by KIPN.Shared.StatsCatalog.FormatValue().
Prefs.StatsFormatters = {
    meters = function(value) return Prefs.FormatDistance(value) end,
    kg = function(value) return Prefs.FormatWeight(value) end,
}

--------------------------------------------------------------------
-- LABELS
--
-- Player-facing names for each choice, used by the preferences
-- screen.
--------------------------------------------------------------------

Prefs.Labels = {
    temperature = {
        fahrenheit = "FAHRENHEIT",
        celsius = "CELSIUS",
    },
    units = {
        imperial = "IMPERIAL",
        metric = "METRIC",
    },
    clock = {
        ["12"] = "12-HOUR",
        ["24"] = "24-HOUR",
    },
    date = {
        mdy = "MM/DD/YYYY",
        dmy = "DD/MM/YYYY",
    },
}

-- What "auto" resolves to right now, as a choice key.
function Prefs.AutoChoice(key)

    if key == "temperature" then
        return Prefs.AutoIsCelsius() and "celsius" or "fahrenheit"
    elseif key == "units" then
        return Prefs.AutoIsMetric() and "metric" or "imperial"
    elseif key == "clock" then
        return Prefs.AutoIs24Hour() and "24" or "12"
    elseif key == "date" then
        return Prefs.AutoIsDayFirst() and "dmy" or "mdy"
    end

    return nil
end

function Prefs.ChoiceLabel(key, choice)

    if choice == "auto" then

        local resolved =
            Prefs.Labels[key][Prefs.AutoChoice(key)] or "?"

        return "AUTO (" .. resolved .. ")"
    end

    return Prefs.Labels[key][choice] or string.upper(tostring(choice))
end

print("[KIPN] Preferences loaded")
