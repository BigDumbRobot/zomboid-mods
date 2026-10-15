require "KIPNCareers_Shared"

-- KIPNCareers_Host
--
-- The one place the framework and every career reach the KIPN host and the
-- game for the things that are the same in every career: the clock, who a
-- player is, sending to a client, the careers data root and saving it,
-- finding items in a container, and where a terminal stands. A career keeps
-- only what is its own.

local Shared = KIPNCareers.Shared
local Host = KIPNCareers.Host or {}
KIPNCareers.Host = Host

local function log(level, message)
    Shared.Log("Host", level, message)
end

function Host.NowHours()
    if type(getGameTime) == "function" and getGameTime() then
        return tonumber(getGameTime():getWorldAgeHours()) or 0
    end
    return 0
end

-- Whole number from minimum to maximum, both included.
function Host.RandomInteger(minimum, maximum)
    minimum = math.floor(tonumber(minimum) or 0)
    maximum = math.floor(tonumber(maximum) or minimum)
    if maximum < minimum then minimum, maximum = maximum, minimum end
    if type(ZombRand) == "function" then return ZombRand(minimum, maximum + 1) end
    return minimum
end

-- The key every career files a player's records under: the server account
-- ("user:<username>"; "SINGLEPLAYER" alone), from KIPN.Shared.GetPlayerId.
-- Records filed under the player's older Steam-based key are moved the first
-- time the player is seen (Host.AdoptLegacyIdentity).
local adopted = {}
function Host.Identity(player)
    if not player then return nil end
    local key
    if KIPN and KIPN.Shared and type(KIPN.Shared.GetPlayerId) == "function" then
        local ok, id = pcall(KIPN.Shared.GetPlayerId, player)
        if ok and id then key = tostring(id) end
    end
    if not key and type(player.getUsername) == "function" then
        local ok, name = pcall(player.getUsername, player)
        if ok and name then key = "user:" .. tostring(name) end
    end
    if key and not adopted[key] then
        adopted[key] = true
        Host.AdoptLegacyIdentity(player, key)
    end
    return key
end

-- Every career record names its owner or client by identity key, as a table
-- key or a field. Moves this player's records from their old keys to `key`.
function Host.AdoptLegacyIdentity(player, key)
    if not (KIPN and KIPN.Shared and KIPN.Shared.GetLegacyPlayerIds and KIPN.Server and type(KIPN.Server.GetData) == "function") then return 0 end
    local data = KIPN.Server.GetData()
    local careers = type(data) == "table" and data.careers
    if type(careers) ~= "table" then return 0 end
    local total = 0
    for _, legacy in ipairs(KIPN.Shared.GetLegacyPlayerIds(player)) do
        local moved, conflicts = KIPN.Shared.RekeyIdentity(careers, legacy, key)
        total = total + moved
        if moved > 0 or conflicts > 0 then
            log("Info", "identity " .. legacy .. " -> " .. key .. " moved=" .. moved .. " conflicts=" .. conflicts)
        end
    end
    if total > 0 then Host.Save() end
    return total
end

-- Raw KIPN identity string ("user:<username>" / "SINGLEPLAYER") for KIPN.Server.Permissions.
function Host.KipnPlayerId(player)
    if KIPN and KIPN.Shared and type(KIPN.Shared.GetPlayerId) == "function" then
        local ok, id = pcall(KIPN.Shared.GetPlayerId, player)
        if ok and id then return tostring(id) end
    end
    local key = Host.Identity(player)
    return key and key:gsub("^steam:", ""):gsub("^user:", "") or nil
end

function Host.Username(player)
    local ok, value = pcall(function() return player and player:getUsername() end)
    return ok and tostring(value or "Unknown") or "Unknown"
end

function Host.IsAdmin(player)
    if not player then return false end
    local ok, access = pcall(player.getAccessLevel, player)
    access = ok and string.lower(tostring(access or "")) or ""
    return access == "admin" or access == "moderator" or access == "overseer"
end

function Host.OnlinePlayerByIdentity(ownerKey)
    if type(getOnlinePlayers) ~= "function" then return nil end
    local players = getOnlinePlayers()
    if not players then return nil end
    for index = 0, players:size() - 1 do
        local player = players:get(index)
        if Host.Identity(player) == ownerKey then return player end
    end
    return nil
end

function Host.Send(player, event, payload)
    if not player or not KIPN or not KIPN.Server or type(KIPN.Server.SendToPlayer) ~= "function" then return false end
    local ok, res = pcall(KIPN.Server.SendToPlayer, player, event, payload or {})
    if not ok then log("Error", "SendToPlayer exception=" .. tostring(res)) return false end
    return res ~= false
end

-- GetData().careers: one slice per career, plus the shared inbox
-- (notifications) and the threats pacing.
function Host.Root()
    if not KIPN or not KIPN.Server or type(KIPN.Server.GetData) ~= "function" then return nil end
    local root = KIPN.Server.GetData()
    if type(root) ~= "table" then return nil end
    root.careers = type(root.careers) == "table" and root.careers or {}
    root.careers.notifications = type(root.careers.notifications) == "table" and root.careers.notifications or {}
    return root.careers
end

function Host.Save()
    if KIPN and KIPN.Server and type(KIPN.Server.Save) == "function" then
        local ok, res = pcall(KIPN.Server.Save)
        if ok and res == true then return true end
        log("Error", "KIPN.Server.Save failed result=" .. tostring(res))
    end
    return false
end

function Host.HasAuthenticatedSession(player)
    local auth = KIPN and KIPN.Server and KIPN.Server.AuthService
    if not auth or type(auth.GetPlayerSession) ~= "function" then return false end
    local ok, session = pcall(auth.GetPlayerSession, player)
    return ok and type(session) == "table" and session.authenticated == true and session.invalidated ~= true
end

-- Every item of `fullType` in the container and the bags inside it, as
-- { item = , container = } so a caller can take one out and put it back.
function Host.CollectItems(container, fullType, output)
    output = output or {}
    if not container or type(container.getItems) ~= "function" then return output end
    local items = container:getItems()
    if not items then return output end
    for index = 0, items:size() - 1 do
        local item = items:get(index)
        if item then
            if item:getFullType() == fullType then output[#output + 1] = { item = item, container = container } end
            local ok, nested = pcall(function() return type(item.getInventory) == "function" and item:getInventory() or nil end)
            if ok and nested then Host.CollectItems(nested, fullType, output) end
        end
    end
    return output
end

-- World position of a KIPN terminal: x, y, z, or nil when it is unknown.
function Host.ComputerCoords(computerId)
    if not computerId or not KIPN or not KIPN.Server then return nil end
    local computer = type(KIPN.Server.GetComputer) == "function" and KIPN.Server.GetComputer(computerId) or nil
    local x, y, z
    if computer then
        x, y, z = tonumber(computer.x), tonumber(computer.y), tonumber(computer.z)
        if (x == nil or y == nil) and type(computer.location) == "table" then
            x, y, z = tonumber(computer.location.x), tonumber(computer.location.y), tonumber(computer.location.z)
        end
    end
    if (x == nil or y == nil) and KIPN.Shared and type(KIPN.Shared.ParseComputerIdCoords) == "function" then
        x, y, z = KIPN.Shared.ParseComputerIdCoords((computer and computer.locationKey) or computerId)
    end
    if x == nil or y == nil then return nil end
    return x, y, z or 0
end

-- True when the player stands at the terminal (within 5 tiles, same floor).
function Host.AtComputer(computerId, player)
    if not player then return false end
    local x, y, z = Host.ComputerCoords(computerId)
    if not x then return false end
    local dx, dy = player:getX() - x, player:getY() - y
    return dx * dx + dy * dy <= 25 and math.abs(player:getZ() - (z or 0)) <= 1
end

return Host
