if isClient() then return end

require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"
require "SacrificialOffering/SO_Storage"
require "Moveables/ISMoveablesAction"
require "TimedActions/ISDestroyStuffAction"
require "Camping/TimedActions/ISRemoveCampfireAction"
require "Camping/SCampfireSystem"
-- Vanilla's ISInventoryTransferAction.lua is a client file and is deliberately
-- NOT required here: it touches the client-only ISInventoryPage global at load,
-- so on a dedicated server the require throws (and logs a stack trace even
-- under pcall). Where the client files exist they are already loaded before
-- this one -- the hook below is guarded on the class being present.

local SO = SacrificialOffering
SO.ServerProtection = SO.ServerProtection or {}
local Protection = SO.ServerProtection

local pendingFires = {}
local pendingFixtureRepairs = {}
local COLD_CAMPFIRE_CHECK_MS = 2000
local nextColdCampfireCheckAt = 0

local function isProtectedObject(object, kind)
    local md = object and object.getModData and object:getModData()
    if not md or md[SO.MOD_DATA.PROTECTED] ~= true then return false end
    return kind == nil or md[SO.MOD_DATA.FIXTURE_KIND] == kind
end

function Protection.FindTempleAt(x, y, z)
    z = math.floor(tonumber(z) or 0)
    for _, zone in ipairs(SO.Storage.Get().zones) do
        if math.floor(tonumber(zone.z) or 0) == z and SO.Util.RectContains(zone, x, y) then
            return zone
        end
    end
    return nil
end

local function isProtectedMannequinContainer(container)
    local parent = container and container:getParent()
    return isProtectedObject(parent, SO.FIXTURE.MANNEQUIN)
end

local function isAltarContainer(container)
    local parent = container and container:getParent()
    return isProtectedObject(parent, SO.FIXTURE.ALTAR)
        or isProtectedObject(parent, SO.FIXTURE.ALTAR_BACK)
end

local function isHumanCorpse(item)
    if not item then return false end
    local fullType = item:getFullType()
    return fullType == "Base.CorpseMale" or fullType == "Base.CorpseFemale"
end

-- Client guards provide immediate feedback. Mirror every destructive timed
-- action on the authority so modified clients cannot bypass fixture protection.
if not Protection.ActionGuardsInstalled then
    local originalMoveIsValid = ISMoveablesAction.isValid
    function ISMoveablesAction:isValid()
        local object = self.moveProps and self.moveProps.object or self.object
        if isProtectedObject(object) then return false end
        return originalMoveIsValid(self)
    end

    local originalDestroyIsValid = ISDestroyStuffAction.isValid
    function ISDestroyStuffAction:isValid()
        if isProtectedObject(self.item) then return false end
        return originalDestroyIsValid(self)
    end

    local originalRemoveCampfireIsValid = ISRemoveCampfireAction.isValid
    function ISRemoveCampfireAction:isValid()
        local object = self.campfire and self.campfire:getObject()
        if isProtectedObject(object, SO.FIXTURE.CAMPFIRE) then return false end
        return originalRemoveCampfireIsValid(self)
    end

    -- Only present where the client Lua files share this state (single player).
    -- On a dedicated server this action never validates server-side anyway.
    if ISInventoryTransferAction and ISInventoryTransferAction.isValid then
        local originalTransferIsValid = ISInventoryTransferAction.isValid
        function ISInventoryTransferAction:isValid()
            -- Single-player / co-op host: the client guard shares this Lua state
            -- and sits underneath; let it refuse so it can also report a relic
            -- theft attempt to the server.
            if SO.Protection and SO.Protection.Patched then return originalTransferIsValid(self) end
            if isProtectedMannequinContainer(self.srcContainer)
                or isProtectedMannequinContainer(self.destContainer)
                or (SO.Fixtures and SO.Fixtures.IsLanternItem and SO.Fixtures.IsLanternItem(self.item)) then
                return false
            end
            -- A carried human corpse is over-weight on purpose. Let it into an
            -- altar half regardless of the capacity check -- the altar consumes it.
            if isHumanCorpse(self.item) and isAltarContainer(self.destContainer)
                and self.srcContainer and self.srcContainer:contains(self.item) then
                return true
            end
            return originalTransferIsValid(self)
        end
    end
    Protection.ActionGuardsInstalled = true
end

local function suppressFire(fire, zoneId)
    if not fire then return end
    -- OnNewFire is raised from the constructor, just before the engine adds and
    -- broadcasts the fire. Make it inert immediately, then remove it next tick.
    fire:setLife(0)
    fire:setLifeStage(5)
    fire:setSpreadDelay(2147483647)
    pendingFires[fire] = zoneId
end

local function onNewFire(fire)
    local square = fire and fire:getSquare()
    -- Vanilla marks the visual IsoFire attached to a manually lit campfire as
    -- "permanent" because it does not spread like a world fire. This does not
    -- make the campfire permanently lit: its normal fuel timer still governs it.
    if not square or fire:isPermanent() then return end
    local zone = Protection.FindTempleAt(square:getX(), square:getY(), square:getZ())
    if zone then suppressFire(fire, zone.id) end
end

local function removeFire(fire, zoneId)
    local square = fire and fire:getSquare()
    if not square or fire:isPermanent() then return false end
    if fire:getObjectIndex() ~= -1 then
        square:transmitRemoveItemFromSquare(fire)
    else
        fire:removeFromWorld()
    end
    local properties = square:getProperties()
    if properties then
        properties:unset(IsoFlagType.burning)
        properties:unset(IsoFlagType.smoke)
    end
    SO.Logger.Debug("Suppressed world fire inside Satanic Temple", {
        zoneId = zoneId,
        x = square:getX(), y = square:getY(), z = square:getZ(),
    })
    return true
end

function Protection.ClearAllZoneFires()
    local stack = IsoFireManager and IsoFireManager.FireStack
    if not stack then return 0 end
    local removed = 0
    for index = stack:size() - 1, 0, -1 do
        local fire = stack:get(index)
        local square = fire and fire:getSquare()
        local zone = square and Protection.FindTempleAt(square:getX(), square:getY(), square:getZ())
        -- Preserve only the visual fire belonging to an actively lit campfire.
        -- Normal fuel exhaustion removes that visual through the campfire system.
        if zone and not fire:isPermanent() and removeFire(fire, zone.id) then
            removed = removed + 1
        end
    end
    return removed
end

local function onProtectedObjectRemoving(object)
    local md = object and object.getModData and object:getModData()
    if not md or md[SO.MOD_DATA.PROTECTED] ~= true or md[SO.MOD_DATA.ZONE_ID] == nil then return end
    -- A campfire swaps its object/sprite through its normal lit<->unlit and
    -- fuel lifecycle; that is not fixture damage. The every-minute integrity
    -- pass still re-creates a genuinely destroyed one.
    if md[SO.MOD_DATA.FIXTURE_KIND] == SO.FIXTURE.CAMPFIRE then return end
    pendingFixtureRepairs[tostring(md[SO.MOD_DATA.ZONE_ID])] = true
end

-- The campfire system does not always clear the visual IsoFire on a temple
-- campfire when its fuel runs out (the flame animation lingers). Once an
-- assigned campfire has read as not-lit for a few seconds -- long enough that a
-- fire the player just lit has already registered isLit -- strip any fire left
-- on its square.
Protection.coldCampfireSince = Protection.coldCampfireSince or {}
local COLD_CAMPFIRE_GRACE_MS = 4000

function Protection.ExtinguishColdCampfires()
    if not SCampfireSystem or not SCampfireSystem.instance then return end
    local now = SO.Util.NowMs()
    local seen = {}
    for _, zone in ipairs(SO.Storage.Get().zones) do
        local position = zone.fixtures and zone.fixtures.campfire
        if position then
            local key = tostring(zone.id)
            seen[key] = true
            local campfire = SCampfireSystem.instance:getLuaObjectAt(position.x, position.y, position.z)
            if campfire ~= nil and campfire.isLit == true then
                Protection.coldCampfireSince[key] = nil
            else
                Protection.coldCampfireSince[key] = Protection.coldCampfireSince[key] or now
                if now - Protection.coldCampfireSince[key] >= COLD_CAMPFIRE_GRACE_MS then
                    local square = getCell():getGridSquare(position.x, position.y, position.z)
                    if square then
                        local objects = square:getObjects()
                        local removed = false
                        for index = objects:size() - 1, 0, -1 do
                            local object = objects:get(index)
                            if object and instanceof(object, "IsoFire") then
                                square:transmitRemoveItemFromSquare(object)
                                removed = true
                            end
                        end
                        if removed then
                            pcall(function()
                                local properties = square:getProperties()
                                if properties then
                                    properties:unset(IsoFlagType.burning)
                                    properties:unset(IsoFlagType.smoke)
                                end
                                square:RecalcProperties()
                            end)
                            SO.Logger.Debug("Cleared a lingering flame on a burnt-out temple campfire", {
                                zoneId = zone.id, x = position.x, y = position.y, z = position.z,
                            })
                        end
                    end
                end
            end
        end
    end
    for key in pairs(Protection.coldCampfireSince) do
        if not seen[key] then Protection.coldCampfireSince[key] = nil end
    end
end

local function processPendingProtection()
    for fire, zoneId in pairs(pendingFires) do
        pendingFires[fire] = nil
        local ok, err = pcall(removeFire, fire, zoneId)
        if not ok then SO.Logger.Error("Could not suppress temple fire", { error = tostring(err), zoneId = zoneId }) end
    end

    local now = SO.Util.NowMs()
    if now >= nextColdCampfireCheckAt then
        nextColdCampfireCheckAt = now + COLD_CAMPFIRE_CHECK_MS
        pcall(Protection.ExtinguishColdCampfires)
    end

    for zoneId in pairs(pendingFixtureRepairs) do
        pendingFixtureRepairs[zoneId] = nil
        local zone = SO.Storage.FindZone(zoneId)
        if zone and SO.Fixtures and SO.Fixtures.Provision then
            local ok, err = pcall(SO.Fixtures.Provision, zone)
            if not ok then
                SO.Logger.Error("Could not restore protected temple fixtures", {
                    error = tostring(err), zoneId = zoneId,
                })
            end
        end
    end
end

Events.OnNewFire.Add(onNewFire)
Events.OnObjectAboutToBeRemoved.Add(onProtectedObjectRemoving)
Events.OnTick.Add(processPendingProtection)
Events.EveryOneMinute.Add(Protection.ClearAllZoneFires)

return Protection
