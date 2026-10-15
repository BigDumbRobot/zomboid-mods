require "SacrificialOffering/SO_Constants"

local SO = SacrificialOffering
SO.Util = SO.Util or {}
local Util = SO.Util

function Util.Trim(value)
    if value == nil then return "" end
    return tostring(value):match("^%s*(.-)%s*$") or ""
end

function Util.Clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

function Util.Round(value)
    value = tonumber(value) or 0
    if value >= 0 then return math.floor(value + 0.5) end
    return math.ceil(value - 0.5)
end

function Util.IsFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Util.SafeInteger(value)
    value = tonumber(value)
    if not Util.IsFiniteNumber(value) then return nil end
    return math.floor(value)
end

function Util.NormalizeRect(x1, y1, x2, y2)
    x1, y1, x2, y2 = Util.SafeInteger(x1), Util.SafeInteger(y1), Util.SafeInteger(x2), Util.SafeInteger(y2)
    if not x1 or not y1 or not x2 or not y2 then return nil end
    if x2 < x1 then x1, x2 = x2, x1 end
    if y2 < y1 then y1, y2 = y2, y1 end
    return { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
end

-- Rectangles use the same half-open edge semantics as the vanilla zone editor.
-- Touching edges are permitted; shared tiles are not.
function Util.RectsIntersect(a, b)
    if not a or not b then return false end
    return a.x1 < b.x2 and a.x2 > b.x1 and a.y1 < b.y2 and a.y2 > b.y1
end

function Util.RectContains(rect, x, y)
    return rect and x >= rect.x1 and x < rect.x2 and y >= rect.y1 and y < rect.y2
end

function Util.ShallowCopy(source)
    local result = {}
    if source then
        for key, value in pairs(source) do result[key] = value end
    end
    return result
end

function Util.DeepCopy(source, seen)
    if type(source) ~= "table" then return source end
    seen = seen or {}
    if seen[source] then return seen[source] end
    local result = {}
    seen[source] = result
    for key, value in pairs(source) do
        result[Util.DeepCopy(key, seen)] = Util.DeepCopy(value, seen)
    end
    return result
end

function Util.TableCount(value)
    local count = 0
    if value then
        for _ in pairs(value) do count = count + 1 end
    end
    return count
end

function Util.SanitizeName(value, fallback)
    local name = Util.Trim(value):gsub("[%c]", ""):sub(1, 64)
    if name == "" then return fallback or "Satanic Temple" end
    return name
end

function Util.NowMs()
    if getTimestampMs then return getTimestampMs() end
    return math.floor(os.clock() * 1000)
end

function Util.NewTransactionId(prefix, player)
    local onlineId = player and player.getOnlineID and player:getOnlineID() or -1
    local randomPart = ZombRand and ZombRand(100000, 999999) or math.random(100000, 999999)
    return string.format("%s-%s-%s-%s", prefix or "tx", tostring(onlineId), tostring(Util.NowMs()), tostring(randomPart))
end

function Util.DistanceSquared(player, x, y, z)
    if not player then return math.huge end
    if math.floor(player:getZ()) ~= math.floor(z or 0) then return math.huge end
    local dx = player:getX() - (x + 0.5)
    local dy = player:getY() - (y + 0.5)
    return dx * dx + dy * dy
end

function Util.ForEachJavaOrLuaList(list, callback)
    if not list or not callback then return end
    if type(list) == "table" then
        for _, value in pairs(list) do callback(value) end
        return
    end
    if list.size and list.get then
        for index = 0, list:size() - 1 do callback(list:get(index)) end
    end
end

return Util
