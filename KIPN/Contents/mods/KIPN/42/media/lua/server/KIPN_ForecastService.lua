-- KIPN_ForecastService.lua
-- Server-side forecast builder and authoritative forecast cache.
--
-- RESPONSIBILITY:
--   * Read authoritative Project Zomboid climate state.
--   * Build the KIPN forecast data contract.
--   * Maintain the authoritative persisted daily forecast cache.
--   * Return the current authoritative forecast.
--
-- THIS MODULE DOES NOT:
--   * receive client commands
--   * send server commands
--   * register network listeners
--   * access client UI
--   * own response routing
--   * broadcast network responses
--
-- Forecast architecture:
--
--   Client
--      |
--      | GET_FORECAST
--      v
--   KIPN server command router
--      |
--      | KIPNForecastService.GetCurrentForecast()
--      v
--   authoritative persisted forecast
--      |
--      | FORECAST_DATA
--      v
--   KIPN_Terminal
--      |
--      v
--   active child screen
--
-- Daily cache architecture:
--
--   GetCurrentForecast()
--          |
--          v
--   KIPN.Server.Data.forecast
--          |
--          +-- cached for current world day?
--          |       |
--          |       +-- YES --> return cached forecast
--          |
--          +-- NO --> buildForecast()
--                      |
--                      v
--                persist forecast
--                      |
--                      v
--                return new forecast
--
-- The command/response identifiers are defined in
-- KIPN.Shared.Commands and KIPN.Shared.ResponseEvents.

if isClient() and not isServer() then
    return
end

--------------------------------------------------------------------
-- SERVICE
--------------------------------------------------------------------

KIPNForecastService =
    KIPNForecastService or {}

--------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------

local TWO_PI = math.pi * 2

-- Maximum number of days ahead to pull from the game's own
-- ClimateForecaster. PZ's forecast horizon is finite; buildMultiDayForecast()
-- stops early the first time getForecast(offset) returns nil, so this is
-- just a safety cap.
local MAX_FORECAST_DAYS = 6

--------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------

local function toNumber(value, fallback)

    if type(value) == "number" then
        return value
    end

    if value ~= nil then

        local parsed =
            tonumber(
                tostring(value)
            )

        if parsed ~= nil then
            return parsed
        end
    end

    return fallback
end

--------------------------------------------------------------------

local function clamp(value, minimum, maximum)

    value =
        toNumber(
            value,
            minimum
        )

    if value < minimum then
        return minimum
    end

    if value > maximum then
        return maximum
    end

    return value
end

--------------------------------------------------------------------

local function safeCall(
    object,
    methodName,
    defaultValue,
    ...
)

    if not object then
        return defaultValue
    end

    local method =
        object[methodName]

    if not method then
        return defaultValue
    end

    local ok, result =
        pcall(
            method,
            object,
            ...
        )

    if not ok then


        return defaultValue
    end

    if result == nil then
        return defaultValue
    end

    return result
end

--------------------------------------------------------------------

local function normaliseIntensity(value)

    value =
        toNumber(
            value,
            0
        )

    if value > 1 then
        value = value / 100
    end

    return clamp(
        value,
        0,
        1
    )
end

--------------------------------------------------------------------

local function getForecastDay(
    forecaster,
    index
)

    if not forecaster then
        return nil
    end

    return safeCall(
        forecaster,
        "getForecast",
        nil,
        index
    )
end

--------------------------------------------------------------------
-- FORECASTVALUE HELPERS
--
-- DayForecast:getTemperature()/getHumidity()/getCloudiness()/
-- getWindPower() all return a ForecastValue object, not a plain
-- number. ForecastValue exposes getTotalMin()/getTotalMean()/
-- getTotalMax() (and day/night variants). These helpers unwrap that
-- object into plain numbers so the rest of this module can stay
-- number-only.
--------------------------------------------------------------------

local function getForecastValueRange(value, fallback)

    if type(value) == "number" then

        return value - 5, value, value + 5
    end

    if not value then

        return fallback - 5, fallback, fallback + 5
    end

    local mean =
        toNumber(
            safeCall(value, "getTotalMean", fallback),
            fallback
        )

    local minimum =
        toNumber(
            safeCall(value, "getTotalMin", mean - 5),
            mean - 5
        )

    local maximum =
        toNumber(
            safeCall(value, "getTotalMax", mean + 5),
            mean + 5
        )

    return minimum, mean, maximum
end

--------------------------------------------------------------------

local function getForecastValueMean(value, fallback)

    if type(value) == "number" then
        return value
    end

    if not value then
        return fallback
    end

    return toNumber(
        safeCall(value, "getTotalMean", fallback),
        fallback
    )
end

--------------------------------------------------------------------
-- WEATHER STAGE LABELS
--
-- Built once from WeatherPeriod's own STAGE_* class constants rather
-- than hardcoded magic numbers, so this keeps working even if a
-- future game version renumbers the stages.
--------------------------------------------------------------------

local WEATHER_STAGE_LABELS = {}

if WeatherPeriod then

    local stageNames = {
        { WeatherPeriod.STAGE_START,          "developing" },
        { WeatherPeriod.STAGE_DRIZZLE,        "drizzle" },
        { WeatherPeriod.STAGE_SHOWERS,        "showers" },
        { WeatherPeriod.STAGE_MODERATE,       "moderate precipitation" },
        { WeatherPeriod.STAGE_HEAVY_PRECIP,   "heavy precipitation" },
        { WeatherPeriod.STAGE_STORM,          "storm" },
        { WeatherPeriod.STAGE_TROPICAL_STORM, "tropical storm" },
        { WeatherPeriod.STAGE_BLIZZARD,       "blizzard" },
        { WeatherPeriod.STAGE_INTERMEZZO,     "lull" },
        { WeatherPeriod.STAGE_CLEARING,       "clearing" },
        { WeatherPeriod.STAGE_KATEBOB_STORM,  "storm" },
    }

    for _, entry in ipairs(stageNames) do

        local id, label =
            entry[1], entry[2]

        if id ~= nil then
            WEATHER_STAGE_LABELS[id] = label
        end
    end
end

local function getStageLabel(stageId)

    if stageId == nil then
        return nil
    end

    return WEATHER_STAGE_LABELS[stageId] or "unknown"
end

--------------------------------------------------------------------
-- WEATHER PERIOD DATA
--
-- Unwraps a WeatherPeriod (the game's own representation of an
-- in-progress or forecast weather event) into a plain data table.
--------------------------------------------------------------------

local function getWeatherPeriodData(period)

    if not period then
        return nil
    end

    return {
        stage =
            getStageLabel(
                safeCall(period, "getCurrentStageID", nil)
            ),

        stageStrength =
            normaliseIntensity(
                safeCall(period, "getTotalStrength", 0)
            ),

        stageProgress =
            normaliseIntensity(
                safeCall(period, "getStageProgress", 0)
            ),

        hasStorm =
            safeCall(period, "hasStorm", false) == true,

        hasHeavyRain =
            safeCall(period, "hasHeavyRain", false) == true,

        hasBlizzard =
            safeCall(period, "hasBlizzard", false) == true,

        hasTropical =
            safeCall(period, "hasTropical", false) == true,
    }
end

--------------------------------------------------------------------
-- AIR FRONT DATA
--
-- Unwraps a DayForecast's AirFront -- the underlying atmospheric
-- front driving that day's weather.
--------------------------------------------------------------------

local function getAirFrontData(dayForecast)

    local front =
        safeCall(dayForecast, "getAirFront", nil)

    if not front then
        return nil
    end

    return {
        days =
            toNumber(safeCall(front, "getDays", 0), 0),

        strength =
            toNumber(safeCall(front, "getStrength", 0), 0),

        type =
            safeCall(front, "getType", nil),

        angleDegrees =
            toNumber(safeCall(front, "getAngleDegrees", 0), 0),

        totalNoise =
            toNumber(safeCall(front, "getTotalNoise", 0), 0),

        label =
            safeCall(dayForecast, "getAirFrontString", nil),
    }
end

--------------------------------------------------------------------
-- WORLD DAY
--------------------------------------------------------------------
--
-- The forecast cache is keyed to the Project Zomboid world day.
--
-- This is preferable to os.date() because the KIPN forecast is based
-- on the in-game world clock, not the real-world server clock.
--
-- Example:
--
--   worldAgeHours = 1234.75
--
--   worldDay = floor(1234.75 / 24)
--
-- The forecast remains cached for that entire PZ world day.
--------------------------------------------------------------------

local function getCurrentWorldDay()

    if not getGameTime then


        return nil
    end

    local gameTime =
        getGameTime()

    if not gameTime then


        return nil
    end

    local worldAgeHours =
        safeCall(
            gameTime,
            "getWorldAgeHours",
            nil
        )

    worldAgeHours =
        toNumber(
            worldAgeHours,
            nil
        )

    if worldAgeHours == nil then


        return nil
    end

    return math.floor(
        worldAgeHours / 24
    )
end

--------------------------------------------------------------------
-- FORECAST CACHE
--------------------------------------------------------------------
--
-- The authoritative cache lives inside KIPN.Server.Data.forecast,
-- backed by its own ModData tag (SUBSYSTEM_TAGS.forecast in
-- KIPN_Server.lua). The service does NOT create a second ModData
-- namespace -- persistForecast() below calls KIPN.Server.Save()
-- with domain "forecast" so only this tag is transmitted, not
-- every subsystem.
--------------------------------------------------------------------

local function getForecastCache()

    if not KIPN.Server then

        KIPN.Logger.Error(
            "KIPNForecastService: "
            .. "KIPN.Server unavailable."
        )

        return nil
    end

    local data

    if type(KIPN.Server.GetData) == "function" then

        data =
            KIPN.Server.GetData()

    else

        data =
            KIPN.Server.Data
    end

    if type(data) ~= "table" then

        KIPN.Logger.Error(
            "KIPNForecastService: "
            .. "server data unavailable."
        )

        return nil
    end

    if type(data.forecast) ~= "table" then

        data.forecast = {}

    end

    return data.forecast
end

--------------------------------------------------------------------
-- FORECAST DAY NORMALIZATION
--
-- buildDayEntry() is the single authoritative reader of a PZ
-- DayForecast object. It feeds both the short-range 24h/4h-step
-- "periods" builder below (day0/day1) and the richer multi-day
-- "days" array (buildMultiDayForecast()) -- both consume the same
-- field names, so fixing/enriching this in one place fixes both.
--------------------------------------------------------------------

local DAY_LABELS = {
    [0] = "TODAY",
    [1] = "TOMORROW",
}

local function dayLabel(offsetDays)

    local fixed =
        DAY_LABELS[offsetDays]

    if fixed then
        return fixed
    end

    return "+" .. offsetDays .. "d"
end

--------------------------------------------------------------------

local function buildDayEntry(
    dayForecast,
    offsetDays,
    fallbackTemperature
)

    if not dayForecast then

        return {
            available = false,

            offsetDays = offsetDays,
            label = dayLabel(offsetDays),

            temperatureMean =
                fallbackTemperature,

            temperatureMin =
                fallbackTemperature - 5,

            temperatureMax =
                fallbackTemperature + 5,

            humidity = 0.5,
            cloud = 0.4,
            wind = 0.25,
            windAngleLabel = nil,
            fog = 0,

            weatherStart = -1,
            weatherEnd = -1,

            hasStorm = false,
            hasHeavyRain = false,
            hasBlizzard = false,
            hasTropical = false,
            hasFog = false,
            chanceOfSnow = false,

            condition = "clear",

            weatherPeriod = nil,
            airFront = nil,
        }
    end

    ----------------------------------------------------------------
    -- TEMPERATURE / HUMIDITY / CLOUD / WIND
    --
    -- These all come back as ForecastValue objects, not plain
    -- numbers -- see getForecastValueRange()/getForecastValueMean().
    ----------------------------------------------------------------

    local tempMin,
        tempMean,
        tempMax =
        getForecastValueRange(
            safeCall(dayForecast, "getTemperature", nil),
            fallbackTemperature
        )

    local humidity =
        normaliseIntensity(
            getForecastValueMean(
                safeCall(dayForecast, "getHumidity", nil),
                0.5
            )
        )

    local cloud =
        normaliseIntensity(
            getForecastValueMean(
                safeCall(dayForecast, "getCloudiness", nil),
                0.4
            )
        )

    local wind =
        normaliseIntensity(
            getForecastValueMean(
                safeCall(dayForecast, "getWindPower", nil),
                0.25
            )
        )

    local fog =
        normaliseIntensity(
            safeCall(
                dayForecast,
                "getFogStrength",
                0
            )
        )

    ----------------------------------------------------------------
    -- AUTHORITATIVE WEATHER FLAGS
    ----------------------------------------------------------------

    local hasStorm =
        safeCall(dayForecast, "isHasStorm", false) == true

    local hasHeavyRain =
        safeCall(dayForecast, "isHasHeavyRain", false) == true

    local hasBlizzard =
        safeCall(dayForecast, "isHasBlizzard", false) == true

    local hasTropical =
        safeCall(dayForecast, "isHasTropicalStorm", false) == true

    local hasFog =
        safeCall(dayForecast, "isHasFog", false) == true

    local chanceOfSnow =
        safeCall(dayForecast, "isChanceOnSnow", false) == true

    ----------------------------------------------------------------
    -- TOP-LEVEL CONDITION
    --
    -- Authoritative flags first (drives the client icon), cloud
    -- heuristic only as a last resort for an otherwise clear day.
    ----------------------------------------------------------------

    local condition

    if hasBlizzard then
        condition = "blizzard"
    elseif hasTropical then
        condition = "tropical_storm"
    elseif hasStorm then
        condition = "storm"
    elseif hasHeavyRain then
        condition = "heavy_rain"
    elseif hasFog then
        condition = "fog"
    elseif chanceOfSnow then
        condition = "snow"
    elseif cloud >= 0.70 then
        condition = "cloudy"
    elseif cloud >= 0.30 then
        condition = "partly_cloudy"
    else
        condition = "clear"
    end

    return {
        available = true,

        offsetDays = offsetDays,
        label = dayLabel(offsetDays),

        temperatureMean = tempMean,
        temperatureMin = tempMin,
        temperatureMax = tempMax,

        humidity = humidity,
        cloud = cloud,
        wind = wind,

        windAngleLabel =
            safeCall(dayForecast, "getMeanWindAngleString", nil),

        fog = fog,

        weatherStart =
            toNumber(
                safeCall(
                    dayForecast,
                    "getWeatherStartTime",
                    -1
                ),
                -1
            ),

        weatherEnd =
            toNumber(
                safeCall(
                    dayForecast,
                    "getWeatherEndTime",
                    -1
                ),
                -1
            ),

        hasStorm = hasStorm,
        hasHeavyRain = hasHeavyRain,
        hasBlizzard = hasBlizzard,
        hasTropical = hasTropical,
        hasFog = hasFog,
        chanceOfSnow = chanceOfSnow,

        condition = condition,

        weatherPeriod =
            getWeatherPeriodData(
                safeCall(dayForecast, "getWeatherPeriod", nil)
            ),

        airFront =
            getAirFrontData(dayForecast),
    }
end

--------------------------------------------------------------------
-- MULTI-DAY FORECAST
--
-- Pulls consecutive days straight from the game's own
-- ClimateForecaster (forecaster:getForecast(offset)) rather than
-- synthesizing days beyond what PZ itself forecasts. Stops at the
-- first day the forecaster can't provide.
--------------------------------------------------------------------

local function buildMultiDayForecast(
    forecaster,
    fallbackTemperature
)

    local days = {}

    for offset = 0, MAX_FORECAST_DAYS do

        local dayForecast =
            getForecastDay(
                forecaster,
                offset
            )

        if not dayForecast then
            break
        end

        days[#days + 1] =
            buildDayEntry(
                dayForecast,
                offset,
                fallbackTemperature
            )
    end

    return days
end

--------------------------------------------------------------------
-- CURRENT CONDITIONS
--
-- Merges the live "Now" period (already computed by the 24h/4h-step
-- builder below, from instantaneous climate:isRaining()/isSnowing()/
-- etc.) with the actual in-progress WeatherPeriod, when one is
-- running, for its stage/strength/hasX flags.
--------------------------------------------------------------------

local function resolveCurrentConditions(
    climate,
    nowPeriod
)

    local current = {
        condition =
            nowPeriod and nowPeriod.condition,

        temperature =
            nowPeriod and nowPeriod.temperature,

        wind =
            nowPeriod and nowPeriod.wind,

        precipitation =
            nowPeriod and nowPeriod.precipitation,

        fog =
            nowPeriod and nowPeriod.fog,

        cloud =
            nowPeriod and nowPeriod.cloud,

        confidence =
            nowPeriod and nowPeriod.confidence,

        hasStorm = false,
        hasHeavyRain = false,
        hasBlizzard = false,
        hasTropical = false,

        stage = nil,
        stageStrength = 0,
    }

    local periodData =
        getWeatherPeriodData(
            safeCall(climate, "getWeatherPeriod", nil)
        )

    if periodData then

        current.hasStorm = periodData.hasStorm
        current.hasHeavyRain = periodData.hasHeavyRain
        current.hasBlizzard = periodData.hasBlizzard
        current.hasTropical = periodData.hasTropical
        current.stage = periodData.stage
        current.stageStrength = periodData.stageStrength
    end

    return current
end

--------------------------------------------------------------------
-- WEATHER WINDOW
--------------------------------------------------------------------

local function getWeatherWindowStatus(
    hour,
    dayData
)

    if dayData.weatherStart < 0
        or dayData.weatherEnd < 0 then

        return false, false
    end

    local startHour =
        dayData.weatherStart % 24

    local endHour =
        dayData.weatherEnd % 24

    if startHour <= endHour then

        return
            hour >= startHour
            and hour <= endHour,
            true
    end

    return
        hour >= startHour
        or hour <= endHour,
        true
end

--------------------------------------------------------------------
-- TEMPERATURE MODEL
--------------------------------------------------------------------

local function temperatureAtHour(
    dayData,
    hour
)

    local amplitude =
        math.max(
            1,
            (
                dayData.temperatureMax
                - dayData.temperatureMin
            ) * 0.5
        )

    local value =
        dayData.temperatureMean
        + amplitude
        * math.cos(
            (
                (hour - 15) / 24
            ) * TWO_PI
        )

    return clamp(
        value,
        dayData.temperatureMin - 1,
        dayData.temperatureMax + 1
    )
end

--------------------------------------------------------------------
-- CONDITION MODEL
--------------------------------------------------------------------

local function conditionForFuture(
    dayData,
    hour,
    temperature
)

    local inWindow =
        getWeatherWindowStatus(
            hour,
            dayData
        )

    if inWindow then

        if dayData.hasBlizzard
            or temperature <= 0.5 then

            return "snow", 0.85
        end

        if dayData.hasStorm then
            return "storm", 0.90
        end

        if dayData.hasHeavyRain then
            return "heavy_rain", 0.85
        end

        return "rain", 0.75
    end

    if dayData.cloud >= 0.70 then
        return "cloudy", 0.30
    end

    if dayData.cloud >= 0.30 then
        return "partly_cloudy", 0.15
    end

    return "clear", 0.05
end

--------------------------------------------------------------------
-- CLOCK DATA
--------------------------------------------------------------------

local function getClockData(
    offsetHours
)

    local gameTime =
        getGameTime()

    if not gameTime then
        return 0, 0, "--:--"
    end

    local nowHour =
        toNumber(
            gameTime:getHour(),
            0
        )

    local nowMinutes =
        toNumber(
            gameTime:getMinutes(),
            0
        )

    local totalHours =
        nowHour
        + (nowMinutes / 60)
        + offsetHours

    local dayIndex =
        math.floor(
            totalHours / 24
        )

    local hourOfDay =
        totalHours % 24

    local displayHour =
        math.floor(
            hourOfDay
        )

    local displayMinute =
        math.floor(
            (
                (
                    hourOfDay
                    - displayHour
                ) * 60
            ) + 0.5
        )

    if displayMinute >= 60 then

        displayMinute =
            displayMinute - 60

        displayHour =
            (
                displayHour + 1
            ) % 24
    end

    return
        dayIndex,
        hourOfDay,
        string.format(
            "%02d:%02d",
            displayHour,
            displayMinute
        )
end

--------------------------------------------------------------------
-- BUILD FORECAST
--------------------------------------------------------------------
--
-- IMPORTANT:
--
-- This function ALWAYS builds a new forecast.
--
-- Call GetCurrentForecast() when you want the authoritative cached
-- forecast.
--------------------------------------------------------------------

function KIPNForecastService.buildForecast()


    local climate =
        getClimateManager()

    if not climate then

        KIPN.Logger.Error(
            "KIPNForecastService: "
            .. "climate manager unavailable"
        )

        return nil
    end

    local gameTime =
        getGameTime()

    if not gameTime then

        KIPN.Logger.Error(
            "KIPNForecastService: "
            .. "game time unavailable"
        )

        return nil
    end

    local forecaster =
        safeCall(
            climate,
            "getClimateForecaster",
            nil
        )

    if not forecaster then


        return {
            source =
                "Current Conditions Only",

            limited = true,

            periods = {},

            warnings = {},

            current = nil,
            days = {},
            daysTillFirstWeather = nil,
        }
    end

    local currentTemperature =
        toNumber(
            climate:getTemperature(),
            20
        )

    local day0 =
        buildDayEntry(
            getForecastDay(
                forecaster,
                0
            ),
            0,
            currentTemperature
        )

    local day1 =
        buildDayEntry(
            getForecastDay(
                forecaster,
                1
            ),
            1,
            currentTemperature
        )

    local periods = {}
    local warnings = {}

    local FORECAST_HOURS = 24
    local FORECAST_STEP = 4

    ---------------------------------------------------------------
    -- BUILD 24-HOUR FORECAST
    ---------------------------------------------------------------

    for offset = 0,
        FORECAST_HOURS,
        FORECAST_STEP do

        local dayIndex
        local hourOfDay
        local clock

        dayIndex,
        hourOfDay,
        clock =
            getClockData(
                offset
            )

        local dayData

        if dayIndex <= 0 then
            dayData = day0
        else
            dayData = day1
        end

        local temperature
        local condition
        local precipitation
        local wind
        local confidence

        -----------------------------------------------------------
        -- CURRENT CONDITIONS
        -----------------------------------------------------------

        if offset == 0 then

            temperature =
                currentTemperature

            local isRaining =
                climate:isRaining()
                or false

            local isSnowing =
                climate:isSnowing()
                or false

            local fog =
                toNumber(
                    climate:getFogIntensity(),
                    0
                )

            -------------------------------------------------------
            -- CURRENT WIND
            --
            -- Prefer the live climate value. Fall back to the
            -- normalized forecast wind if unavailable.
            -------------------------------------------------------

            local currentWind =
                safeCall(
                    climate,
                    "getWindPower",
                    nil
                )

            if currentWind == nil then

                currentWind =
                    dayData.wind

            else

                currentWind =
                    normaliseIntensity(
                        currentWind
                    )
            end

            wind =
                math.floor(
                    clamp(
                        currentWind,
                        0,
                        1
                    ) * 100
                    + 0.5
                )

            if isSnowing then

                condition = "snow"
                precipitation = 1

            elseif isRaining then

                condition = "rain"
                precipitation = 1

            elseif fog >= 0.35 then

                condition = "fog"
                precipitation = 0

            elseif dayData.cloud >= 0.70 then

                condition = "cloudy"
                precipitation = 0

            elseif dayData.cloud >= 0.30 then

                condition = "partly_cloudy"
                precipitation = 0

            else

                condition = "clear"
                precipitation = 0
            end

            confidence = 1

        -----------------------------------------------------------
        -- FUTURE CONDITIONS
        -----------------------------------------------------------

        else

            temperature =
                temperatureAtHour(
                    dayData,
                    hourOfDay
                )

            local futureCondition
            local futureRain

            futureCondition,
            futureRain =
                conditionForFuture(
                    dayData,
                    hourOfDay,
                    temperature
                )

            condition =
                futureCondition

            precipitation =
                futureRain

            wind =
                math.floor(
                    clamp(
                        dayData.wind,
                        0,
                        1
                    ) * 100
                    + 0.5
                )

            confidence =
                clamp(
                    0.90
                    - (
                        offset
                        / FORECAST_HOURS
                    ) * 0.25,
                    0.50,
                    0.90
                )
        end

        -----------------------------------------------------------
        -- FORECAST PERIOD
        -----------------------------------------------------------

        periods[#periods + 1] = {

            offsetHours =
                offset,

            label =
                offset == 0
                and "Now"
                or ("+" .. offset .. "h"),

            clock =
                clock,

            condition =
                condition,

            temperature =
                math.floor(
                    temperature * 10
                    + 0.5
                ) / 10,

            precipitation =
                math.floor(
                    clamp(
                        precipitation,
                        0,
                        1
                    ) * 100
                    + 0.5
                ),

            fog =
                math.floor(
                    dayData.fog * 100
                    + 0.5
                ),

            wind =
                wind,

            cloud =
                math.floor(
                    dayData.cloud * 100
                    + 0.5
                ),

            confidence =
                math.floor(
                    clamp(
                        confidence,
                        0,
                        1
                    ) * 100
                    + 0.5
                )
        }

        -----------------------------------------------------------
        -- WARNINGS
        -----------------------------------------------------------

        if condition == "storm"
            and #warnings == 0 then

            warnings[#warnings + 1] =
                "Thunderstorm conditions possible in the next 24 hours."

        elseif condition == "heavy_rain"
            and #warnings == 0 then

            warnings[#warnings + 1] =
                "Heavy rain possible in the next 24 hours."

        elseif condition == "snow"
            and #warnings == 0 then

            warnings[#warnings + 1] =
                "Snow or freezing precipitation possible."
        end
    end

    ---------------------------------------------------------------
    -- MULTI-DAY FORECAST
    --
    -- Pulled directly from the game's own ClimateForecaster rather
    -- than synthesized -- see buildMultiDayForecast().
    ---------------------------------------------------------------

    local days =
        buildMultiDayForecast(
            forecaster,
            currentTemperature
        )

    ---------------------------------------------------------------
    -- CURRENT CONDITIONS
    --
    -- The "Now" period from the loop above, merged with the actual
    -- in-progress WeatherPeriod (if any) -- see
    -- resolveCurrentConditions().
    ---------------------------------------------------------------

    local current =
        resolveCurrentConditions(
            climate,
            periods[1]
        )

    local daysTillFirstWeather =
        toNumber(
            safeCall(
                forecaster,
                "getDaysTillFirstWeather",
                nil
            ),
            nil
        )

    ---------------------------------------------------------------
    -- RESPONSE DATA
    ---------------------------------------------------------------

    local result = {

        source =
            "Knox Climate Forecast",

        limited =
            not day0.available
            and not day1.available,

        periods =
            periods,

        warnings =
            warnings,

        current =
            current,

        days =
            days,

        daysTillFirstWeather =
            daysTillFirstWeather,
    }


    return result
end

--------------------------------------------------------------------
-- PERSIST FORECAST
--------------------------------------------------------------------
--
-- The forecast cache is stored under:
--
--     KIPN.Server.Data.forecast
--
-- backed by its own ModData tag (SUBSYSTEM_TAGS.forecast).
--
-- Persistence is owned by KIPN.Server.Save("forecast") below, which
-- transmits only the forecast tag, not every subsystem. This
-- service does not directly transmit ModData.
--------------------------------------------------------------------

local function persistForecast(
    worldDay,
    forecast
)


    local cache =
        getForecastCache()

    if not cache then

        KIPN.Logger.Error(
            "KIPNForecastService: "
            .. "unable to obtain forecast cache."
        )

        return false
    end

    ---------------------------------------------------------------
    -- UPDATE AUTHORITATIVE FORECAST CACHE
    ---------------------------------------------------------------

    cache.worldDay =
        worldDay

    cache.data =
        forecast

    ---------------------------------------------------------------
    -- AUTHORITATIVE PERSISTENCE
    ---------------------------------------------------------------
    --
    -- KIPN.Server.Save("forecast") owns persistence, transmitting
    -- only the forecast subsystem tag.
    --
    -- The forecast service must not directly access ModData
    -- transmission. This keeps persistence ownership inside
    -- KIPN_Server.lua.
    ---------------------------------------------------------------

    if not KIPN.Server then

        KIPN.Logger.Error(
            "KIPNForecastService: "
            .. "KIPN.Server unavailable while persisting forecast."
        )

        return false
    end

    if type(KIPN.Server.Save) ~= "function" then

        KIPN.Logger.Error(
            "KIPNForecastService: "
            .. "KIPN.Server.Save() unavailable. "
            .. "Forecast cannot be persisted."
        )

        return false
    end

    local ok, result =
        pcall(
            KIPN.Server.Save,
            "forecast"
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPNForecastService: "
            .. "KIPN.Server.Save() failed: "
            .. tostring(result)
        )

        return false
    end

    if result == false then

        KIPN.Logger.Error(
            "KIPNForecastService: "
            .. "KIPN.Server.Save() returned false."
        )

        return false
    end


    return true
end

--------------------------------------------------------------------
-- GET CURRENT FORECAST
--------------------------------------------------------------------
--
-- THIS IS THE PRIMARY PUBLIC FORECAST FUNCTION.
--
-- Call this from:
--
--     GET_FORECAST
--     GET_LOGIN_FORECAST
--
-- It does NOT rebuild the forecast every time.
--
-- Behaviour:
--
--   1. Resolve current PZ world day.
--   2. Read persisted KIPN forecast cache.
--   3. If cache belongs to today:
--          return cached forecast.
--   4. If cache is missing or belongs to an old day:
--          build a new forecast.
--   5. Persist the new forecast.
--   6. Return the new forecast.
--
-- The second player opening a computer on the same day therefore
-- receives the exact same forecast object that the first player
-- caused to be generated.
--------------------------------------------------------------------

function KIPNForecastService.GetCurrentForecast()


    local worldDay =
        getCurrentWorldDay()

    if worldDay == nil then

        KIPN.Logger.Error(
            "KIPNForecastService: "
            .. "unable to determine current world day."
        )

        return nil, false
    end

    local cache =
        getForecastCache()

    if not cache then

        return nil, false
    end

    ---------------------------------------------------------------
    -- VALID CURRENT CACHE
    ---------------------------------------------------------------

    if cache.worldDay == worldDay
        and type(cache.data) == "table" then


        return cache.data, false
    end

    ---------------------------------------------------------------
    -- CACHE MISS / NEW WORLD DAY
    ---------------------------------------------------------------

    if cache.worldDay == nil then


    else

    end

    ---------------------------------------------------------------
    -- BUILD NEW AUTHORITATIVE FORECAST
    ---------------------------------------------------------------

    local forecast =
        KIPNForecastService.buildForecast()

    if not forecast then

        KIPN.Logger.Error(
            "KIPNForecastService: "
            .. "failed to build new forecast."
        )

        return nil, false
    end

    ---------------------------------------------------------------
    -- UPDATE CACHE
    ---------------------------------------------------------------

    local persisted =
        persistForecast(
            worldDay,
            forecast
        )

    if not persisted then


        -----------------------------------------------------------
        -- IMPORTANT:
        --
        -- We still return the newly generated forecast.
        --
        -- The current request can succeed even if persistence
        -- fails. The next request will attempt generation again.
        -----------------------------------------------------------

        return forecast, true
    end


    ---------------------------------------------------------------
    -- SECOND RETURN VALUE
    --
    -- true means this call generated a NEW forecast.
    --
    -- The command layer can use this to determine whether it
    -- should broadcast the forecast to all connected clients.
    ---------------------------------------------------------------

    return forecast, true
end

--------------------------------------------------------------------
-- CACHE STATUS
--------------------------------------------------------------------
--
-- Useful for diagnostics and server-side debugging.
--------------------------------------------------------------------

function KIPNForecastService.GetCacheStatus()

    local worldDay =
        getCurrentWorldDay()

    local cache =
        getForecastCache()

    if not cache then

        return {
            available = false,
            currentWorldDay = worldDay,
            cachedWorldDay = nil
        }
    end

    local valid =
        worldDay ~= nil
        and cache.worldDay == worldDay
        and type(cache.data) == "table"

    return {
        available =
            type(cache.data) == "table",

        valid =
            valid,

        currentWorldDay =
            worldDay,

        cachedWorldDay =
            cache.worldDay
    }
end

--------------------------------------------------------------------
-- CACHE INVALIDATION
--------------------------------------------------------------------

function KIPNForecastService.InvalidateCache()

    local cache =
        getForecastCache()

    if not cache then
        return false
    end

    cache.worldDay = nil

    return true
end

--------------------------------------------------------------------
-- EVENT-DRIVEN REFRESH
--
-- OnWeatherPeriodStart/Stage/Complete/Stop are server-only PZ events
-- that fire when the ACTUAL weather period changes -- not on a
-- timer, and not something KIPN needs to poll for. Invalidating the
-- cache here means the next GetCurrentForecast() call (from any
-- player's regular daily request, or the next tick) rebuilds
-- immediately instead of waiting for the world-day rollover.
--------------------------------------------------------------------

local function onWeatherPeriodChanged()

    KIPNForecastService.InvalidateCache()
end

if Events
    and Events.OnWeatherPeriodStart then

    Events.OnWeatherPeriodStart.Add(
        onWeatherPeriodChanged
    )

    Events.OnWeatherPeriodStage.Add(
        onWeatherPeriodChanged
    )

    Events.OnWeatherPeriodComplete.Add(
        onWeatherPeriodChanged
    )

    Events.OnWeatherPeriodStop.Add(
        onWeatherPeriodChanged
    )
end

--------------------------------------------------------------------
-- END SERVICE
--------------------------------------------------------------------

return KIPNForecastService