require "SVSBT_Registry"

if type(isClient) == "function" and isClient() and not isServer() then return end

local Shared, Registry, Logger = SVSBT.Shared, SVSBT.Server.Registry, SVSBT.Logger
local Combat = {}
SVSBT.Server.Combat = Combat

local function findPlayer(username)
    for _, player in ipairs(Shared.Players()) do
        if Shared.Username(player) == username then return player end
    end
end

local function isPlayer(target)
    return target and instanceof(target, "IsoPlayer") and not instanceof(target, "IsoAnimal")
end

local function lifeToken(player)
    local data = player:getModData()
    if not data.SVSBT_LifeToken then
        local serial = Registry.Data.nextSerial
        Registry.Data.nextSerial = serial + 1
        data.SVSBT_LifeToken = tostring(serial) .. ":" .. tostring(Shared.WorldAgeHours())
        Registry.MarkDirty("player life token")
    end
    return data.SVSBT_LifeToken
end

local function injuries(player)
    local body = player:getBodyDamage()
    local health = body and body:getOverallBodyHealth() or player:getHealth()
    local wounds = 0
    local parts = body and type(body.getBodyParts) == "function" and body:getBodyParts() or nil
    if parts then
        for i = 0, parts:size() - 1 do
            local part = parts:get(i)
            wounds = wounds + math.max(0, 100 - part:getHealth()) + math.max(0, part:getBleedingTime())
        end
    end
    return health, wounds
end

local function remember(record, target)
    if not record or not record.owner then return nil end
    local entry = {
        owner = record.owner, trapId = record.id, kind = record.kind,
        life = lifeToken(target), atHours = Shared.WorldAgeHours(),
    }
    Registry.Data.trapInjuries[Shared.Username(target)] = entry
    local owner = findPlayer(record.owner)
    if type(target.setAttackedBy) == "function" then target:setAttackedBy(owner) end
    Registry.MarkDirty("trap injury attribution")
    return entry
end

function Combat.IsDead(target)
    if not isPlayer(target) then return false end
    local health = injuries(target)
    return target:isDead() or health <= 0
end

-- The private injury record outlives the physical device. Never write arbitrary
-- fields onto Java player objects, and never rely on OnPlayerDeath alone: B42
-- raises that Lua event only for local players, not on a dedicated server.
function Combat.PlayerDied(target)
    if not isPlayer(target) or not Combat.IsDead(target) then return false end
    local entry = Registry.Data.trapInjuries[Shared.Username(target)]
    if not entry or entry.life ~= lifeToken(target) or entry.credited then return false end
    local attacker = type(target.getAttackedBy) == "function" and target:getAttackedBy() or nil
    if attacker and (not isPlayer(attacker) or Shared.Username(attacker) ~= entry.owner) then
        Registry.Data.trapInjuries[Shared.Username(target)] = nil
        Registry.MarkDirty("superseded trap injury")
        return false
    end

    entry.credited = true -- Set before Kill(), which can invoke death callbacks.
    Registry.Data.pendingTrapKills[entry.owner] = (Registry.Data.pendingTrapKills[entry.owner] or 0) + 1
    local owner = findPlayer(entry.owner)
    if owner and type(target.Kill) == "function"
        and (type(target.isOnKillDone) ~= "function" or not target:isOnKillDone()) then
        target:Kill(owner)
    end
    Registry.Persist("trap kill credited")
    Logger.Audit("TRAP_KILL", entry.owner,
        "victim=" .. Shared.Username(target) .. " | trap=" .. tostring(entry.trapId) .. " | kind=" .. tostring(entry.kind))
    return true
end

function Combat.Apply(record, target, effect, ...)
    if not isPlayer(target) then return effect(target, ...) end
    if Combat.IsDead(target) then return false end
    local beforeHealth, beforeWounds = injuries(target)
    local username = Shared.Username(target)
    local previous = Registry.Data.trapInjuries[username]
    local attacker = type(target.getAttackedBy) == "function" and target:getAttackedBy() or nil
    local entry = remember(record, target)
    local result = effect(target, ...)
    local health, wounds = injuries(target)
    if entry and health >= beforeHealth and wounds <= beforeWounds then
        Registry.Data.trapInjuries[username] = previous
        if type(target.setAttackedBy) == "function" then target:setAttackedBy(attacker) end
    else
        Combat.PlayerDied(target)
    end
    return result
end

function Combat.TrackFire(record, square)
    if not record or not record.owner or not square then return end
    local key = square:getX() .. ":" .. square:getY() .. ":" .. square:getZ()
    Registry.Data.trapFires[key] = {
        owner = record.owner, id = record.id, kind = record.kind,
        x = square:getX(), y = square:getY(), z = square:getZ(),
    }
    Registry.MarkDirty("trap fire attribution")
end

local function updateFires()
    local spread = {}
    for key, source in pairs(Registry.Data.trapFires) do
        local square = getCell():getGridSquare(source.x, source.y, source.z)
        if square and type(square.haveFire) == "function" then
            if not square:haveFire() then
                Registry.Data.trapFires[key] = nil
                Registry.MarkDirty("trap fire extinguished")
            else
                for dx = -1, 1 do
                    for dy = -1, 1 do
                        local neighbor = getCell():getGridSquare(source.x + dx, source.y + dy, source.z)
                        local nextKey = (source.x + dx) .. ":" .. (source.y + dy) .. ":" .. source.z
                        if neighbor and neighbor:haveFire() and not Registry.Data.trapFires[nextKey] then
                            spread[#spread + 1] = { source, neighbor }
                        end
                    end
                end
            end
        end
    end
    for _, entry in ipairs(spread) do Combat.TrackFire(entry[1], entry[2]) end
end

function Combat.Tick()
    updateFires()
    for _, player in ipairs(Shared.Players()) do
        local username = Shared.Username(player)
        local source = Registry.Data.trapInjuries[username]
        if type(player.isOnFire) == "function" and player:isOnFire() then
            local key = math.floor(player:getX()) .. ":" .. math.floor(player:getY()) .. ":" .. math.floor(player:getZ())
            local fire = Registry.Data.trapFires[key]
            if fire and not Combat.IsDead(player) then source = remember(fire, player) end
        end
        if source and source.life == lifeToken(player) then
            if Combat.IsDead(player) then Combat.PlayerDied(player)
            elseif not source.credited then
                local health, wounds = injuries(player)
                local attacker = type(player.getAttackedBy) == "function" and player:getAttackedBy() or nil
                local otherAttacker = attacker and (not isPlayer(attacker) or Shared.Username(attacker) ~= source.owner)
                if otherAttacker or (health >= 100 and wounds <= 0
                    and not (type(player.isOnFire) == "function" and player:isOnFire())) then
                    Registry.Data.trapInjuries[username] = nil
                    if not otherAttacker and type(player.setAttackedBy) == "function" then player:setAttackedBy(nil) end
                    Registry.MarkDirty("trap injury resolved")
                end
            end
        elseif source then
            Registry.Data.trapInjuries[username] = nil -- New character, not the old victim.
            Registry.MarkDirty("old character injury removed")
        end
    end
    -- Process awards after observing every victim, regardless of online-list order.
    for _, player in ipairs(Shared.Players()) do
        local username = Shared.Username(player)
        local pending = Registry.Data.pendingTrapKills[username] or 0
        if pending > 0 then
            local total = player:getSurvivorKills() + pending
            player:setSurvivorKills(total)
            if type(isServer) == "function" and isServer() then
                sendServerCommand(player, Shared.Module, "TRAP_KILL_CREDIT", { username = username, total = total })
            end
            Registry.Data.pendingTrapKills[username] = nil
            Registry.Persist("trap kill count applied")
        end
    end
end

return Combat
