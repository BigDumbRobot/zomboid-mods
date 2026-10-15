require "SVSBT_Registry"

if type(isClient) == "function" and isClient() and not isServer() then return end

local Shared, Registry = SVSBT.Shared, SVSBT.Server.Registry
local Creatures = { Held = {}, Escaped = {} }
SVSBT.Server.Creatures = Creatures

local function sync(target)
    if type(target.sendExtraUpdateToClients) == "function" then target:sendExtraUpdateToClients() end
end

local function matches(record, target)
    if not target or not record.occupant then return false end
    local kind = record.occupant.creatureKind or record.occupant.kind
    if not (kind == "animal" and instanceof(target, "IsoAnimal")
        or kind == "zombie" and instanceof(target, "IsoZombie")) then return false end
    return target:getModData().SVSBT_CreatureTrapId == record.id
end

function Creatures.Find(record)
    local target = Creatures.Held[record.id]
    if matches(record, target) then return target end
    local occupant = record.occupant
    if not occupant then return nil end
    if occupant.creatureKind == "animal" and occupant.onlineId and type(getAnimal) == "function" then
        target = getAnimal(occupant.onlineId)
        if matches(record, target) then Creatures.Held[record.id] = target; return target end
    end
    local square = getCell():getGridSquare(record.x, record.y, record.z)
    local movers = square and square:getMovingObjects()
    if movers then
        for i = 0, movers:size() - 1 do
            target = movers:get(i)
            if matches(record, target) then Creatures.Held[record.id] = target; return target end
        end
    end
    return nil
end

function Creatures.Capture(record, target, kind)
    local data = target:getModData()
    data.SVSBT_CreatureTrapId = record.id
    record.occupant = {
        kind = target:isDead() and "corpse" or kind, creatureKind = kind,
        onlineId = type(target.getOnlineID) == "function" and target:getOnlineID() or nil,
        couldWalk = type(target.isCanWalk) == "function" and target:isCanWalk() or false,
        wasUseless = type(target.isUseless) == "function" and target:isUseless() or false,
    }
    Creatures.Held[record.id] = target
    if not target:isDead() then
        if kind == "zombie" then
            if type(target.setCanWalk) == "function" then target:setCanWalk(false) end
            if type(target.setUseless) == "function" then target:setUseless(true) end
        else
            if type(target.stopAllMovementNow) == "function" then target:stopAllMovementNow() end
            if type(target.setBlockMovement) == "function" then target:setBlockMovement(true) end
        end
    end
    sync(target)
end

function Creatures.Release(record)
    local target = Creatures.Find(record)
    local occupant = record.occupant
    if target then
        if occupant.creatureKind == "zombie" then
            if type(target.setCanWalk) == "function" then target:setCanWalk(occupant.couldWalk) end
            if type(target.setUseless) == "function" then target:setUseless(occupant.wasUseless) end
        elseif type(target.setBlockMovement) == "function" then target:setBlockMovement(false) end
        target:getModData().SVSBT_CreatureTrapId = nil
        sync(target)
    end
    Creatures.Held[record.id] = nil
    return target
end

function Creatures.ReconcileLegacy(record)
    local occupant = record.occupant
    if not occupant or occupant.creatureKind or record.legacyCreatureChecked then return end
    local cell = getCell()
    local square = cell and cell:getGridSquare(record.x, record.y, record.z)
    if not square then return end
    local target, kind
    -- Older versions classified IsoAnimal as IsoPlayer. Its old held-trap tag
    -- identifies it even after it has run away from the original square.
    local animals = type(cell.getAnimals) == "function" and cell:getAnimals() or nil
    if animals then
        for i = 0, animals:size() - 1 do
            local animal = animals:get(i)
            if animal:getModData().SVSBT_BearTrapHeldId == record.id then target, kind = animal, "animal"; break end
        end
    end
    if not target and (occupant.kind == "animal" or occupant.kind == "zombie") then
        local movers = square:getMovingObjects()
        for i = 0, movers:size() - 1 do
            local mover = movers:get(i)
            if (occupant.kind == "animal" and instanceof(mover, "IsoAnimal"))
                or (occupant.kind == "zombie" and instanceof(mover, "IsoZombie")) then
                target, kind = mover, occupant.kind
                break
            end
        end
        if not target then record.occupant = nil end
    end
    if target then
        target:getModData().SVSBT_BearTrapHeldId = nil
        if record.heldUsername then SVSBT.Server.Service.HeldPlayers[record.heldUsername] = nil end
        record.heldUsername = nil
        Creatures.Capture(record, target, kind)
        if kind == "zombie" then record.occupant.couldWalk = true end
    end
    record.legacyCreatureChecked = true
    Registry.MarkDirty("legacy creature restraint migrated")
end

function Creatures.TickHeld(record, square)
    local target = Creatures.Find(record)
    if not target then
        -- Never keep a release action for an animal/zombie that is no longer here.
        record.occupant = nil
        Registry.MarkDirty("bear trap occupant absent")
        return true
    end
    if target:isDead() then
        record.occupant.kind = "corpse"
        Registry.MarkDirty("bear trap occupant died")
        return true
    end
    local onTile = square:getMovingObjects():contains(target)
    local sprinting = type(target.isSprinting) == "function" and target:isSprinting()
        or type(target.isRunning) == "function" and target:isRunning()
    if not onTile or (record.occupant.creatureKind == "animal" and sprinting) then
        local animal = record.occupant.creatureKind == "animal"
        local onlineId = record.occupant.onlineId
        Creatures.Release(record)
        record.occupant = nil
        if animal then
            -- Escaping tears the wound open: fatal blood loss over three seconds.
            local bleed = { onlineId = onlineId, remaining = 3, rate = target:getHealth() / 3 }
            Registry.Data.bleedingCreatures[record.id] = bleed
            target:getModData().SVSBT_BleedingTrapId = record.id
            Creatures.Escaped[record.id] = { target = target, lastMs = getTimestampMs() }
        end
        Registry.Persist("bear trap creature escaped")
        return true
    end
    if record.occupant.creatureKind == "zombie" and type(target.setUseless) == "function" then target:setUseless(true) end
    local damage = SVSBT.Config.Get("BearTrapHoldDamagePerTick") * SVSBT.Config.Get("DamageMultiplier")
    target:setHealth(math.max(0, target:getHealth() - damage))
    if target:isDead() then record.occupant.kind = "corpse" end
    sync(target)
    Registry.MarkDirty("bear trap occupant wounded")
    return true
end

function Creatures.TickEscaped()
    local now = getTimestampMs()
    for trapId, bleed in pairs(Registry.Data.bleedingCreatures) do
        local runtime = Creatures.Escaped[trapId]
        local target = runtime and runtime.target
            or (bleed.onlineId and type(getAnimal) == "function" and getAnimal(bleed.onlineId))
        if target and target:getModData().SVSBT_BleedingTrapId == trapId then
            local elapsed = runtime and math.max(0, (now - runtime.lastMs) / 1000) or 0
            bleed.remaining = bleed.remaining - elapsed
            target:setHealth(bleed.remaining <= 0 and 0 or math.max(0, target:getHealth() - bleed.rate * elapsed))
            sync(target)
            if target:isDead() then
                if type(target.Kill) == "function" then target:Kill(nil) end
                target:getModData().SVSBT_BleedingTrapId = nil
                Registry.Data.bleedingCreatures[trapId] = nil
                Creatures.Escaped[trapId] = nil
            else Creatures.Escaped[trapId] = { target = target, lastMs = now } end
            Registry.MarkDirty("escaped animal bleeding")
        elseif target then
            Registry.Data.bleedingCreatures[trapId] = nil -- ID belongs to a different animal now.
            Creatures.Escaped[trapId] = nil
            Registry.MarkDirty("escaped animal no longer exists")
        else
            Creatures.Escaped[trapId] = nil -- Pause while the animal is unloaded.
        end
    end
end

return Creatures
