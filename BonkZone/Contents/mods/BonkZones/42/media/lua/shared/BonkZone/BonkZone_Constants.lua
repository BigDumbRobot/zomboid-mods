BonkZone = BonkZone or {}
BonkZone.Constants = BonkZone.Constants or {}

local Constants = BonkZone.Constants

Constants.MOD_ID = "BonkZone"
Constants.MODULE = "BonkZone"
Constants.MODDATA_KEY = "BonkZone.WorldData.v1"
Constants.DATA_VERSION = 1
Constants.MAX_NAME_LENGTH = 64
Constants.MAX_COORDINATE = 1000000
Constants.MAX_ZONE_EDGE = 100000
Constants.MIN_ZONE_EDGE = 1
Constants.ALL_FLOORS_MIN = -32
Constants.ALL_FLOORS_MAX = 31
Constants.DEFAULT_ZONE_NAME = "Bonk Zone"
Constants.MESSAGE_COOLDOWN_MS = 2000
Constants.ENTRY_CHECK_INTERVAL_MS = 400
Constants.AUDIT_RATE_LIMIT_MS = 250
Constants.REPORT_COOLDOWN_MS = 1500
Constants.MAP_COLOR = { r = 0.85, g = 0.10, b = 0.16, a = 0.90 }
Constants.MAP_FILL_COLOR = { r = 0.85, g = 0.10, b = 0.16, a = 0.12 }

Constants.Commands = {
    REQUEST_SYNC = "REQUEST_SYNC",
    SYNC = "SYNC",
    ADD_ZONE = "ADD_ZONE",
    UPDATE_ZONE = "UPDATE_ZONE",
    RENAME_ZONE = "RENAME_ZONE",
    REMOVE_ZONE = "REMOVE_ZONE",
    OPERATION_RESULT = "OPERATION_RESULT",
    SHOW_BLOCKED = "SHOW_BLOCKED",
}

function Constants.NowMs()
    if getTimestampMs then
        return getTimestampMs()
    end
    return math.floor((os.clock() or 0) * 1000)
end

function Constants.Clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

function Constants.Trim(value)
    value = tostring(value or "")
    return value:match("^%s*(.-)%s*$") or ""
end

function Constants.NormalizeName(value)
    local valueTrimmed = Constants.Trim(value)
    valueTrimmed = valueTrimmed:gsub("[%c]", " ")
    valueTrimmed = valueTrimmed:gsub("%s+", " ")
    if #valueTrimmed > Constants.MAX_NAME_LENGTH then
        valueTrimmed = valueTrimmed:sub(1, Constants.MAX_NAME_LENGTH)
    end
    return valueTrimmed
end

function Constants.NormalizeBounds(x1, y1, x2, y2)
    local nx1 = math.floor(tonumber(x1) or 0)
    local ny1 = math.floor(tonumber(y1) or 0)
    local nx2 = math.ceil(tonumber(x2) or 0)
    local ny2 = math.ceil(tonumber(y2) or 0)
    if nx1 > nx2 then nx1, nx2 = nx2, nx1 end
    if ny1 > ny2 then ny1, ny2 = ny2, ny1 end
    return nx1, ny1, nx2, ny2
end

function Constants.IsBoundsValid(x1, y1, x2, y2)
    local nx1, ny1, nx2, ny2 = Constants.NormalizeBounds(x1, y1, x2, y2)
    if nx1 < -Constants.MAX_COORDINATE or ny1 < -Constants.MAX_COORDINATE then return false end
    if nx2 > Constants.MAX_COORDINATE or ny2 > Constants.MAX_COORDINATE then return false end
    local width = nx2 - nx1
    local height = ny2 - ny1
    if width < Constants.MIN_ZONE_EDGE or height < Constants.MIN_ZONE_EDGE then return false end
    if width > Constants.MAX_ZONE_EDGE or height > Constants.MAX_ZONE_EDGE then return false end
    return true
end

function Constants.IsPlayerObject(value)
    return value ~= nil and instanceof ~= nil and instanceof(value, "IsoPlayer")
end

function Constants.IsZombieObject(value)
    return value ~= nil and instanceof ~= nil and instanceof(value, "IsoZombie")
end

return Constants

