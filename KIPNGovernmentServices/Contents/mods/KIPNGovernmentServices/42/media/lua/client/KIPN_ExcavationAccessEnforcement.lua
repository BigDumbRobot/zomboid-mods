-- KIPN_ExcavationAccessEnforcement.lua
--
-- Client-side action gating for excavation claims. When the local
-- player is NOT the owner of an excavation plot and the matching
-- sandbox toggle is off, this stops:
--
--   * Loot   -> transferring items in/out of any container physically
--               on a claimed tile (ISInventoryTransferAction)
--   * Build  -> the world-object context-menu Disassemble / Dismantle /
--               Sledgehammer / Pick-Up-Moveable entries on a claimed tile
--
-- This is a CLIENT enforcement layer (the same layer PZ's own safehouse
-- protection largely uses). The server remains authoritative for
-- ownership itself. New construction placed through the build menu is
-- not intercepted here.

if isServer() then return end

require "KIPN_Shared"
require "TimedActions/ISBaseTimedAction"

KIPN_ExcavationAccessEnforcement = KIPN_ExcavationAccessEnforcement or {}

local areas = {}                 -- { {x1,y1,x2,y2,z,ownerSteamId}, ... }
local mySteamId = nil
local tickCounter = 0
local REQUEST_EVERY_TICKS = 900

local function log(m) print("[KIPN EXCAVATION ACCESS] " .. tostring(m)) end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, v = pcall(getTimestampMs)
        if ok and type(v) == "number" then return v end
    end
    return math.floor(os.clock() * 1000)
end

------------------------------------------------------------
-- IDENTITY
------------------------------------------------------------

-- The key claims are owned under: the server account (see
-- KIPN.Shared.GetPlayerId), which is what the synced areas carry in
-- ownerSteamId.
local function resolveMySteamId()
    local p = getPlayer and getPlayer()
    if not p then return nil end
    local ok, id = pcall(KIPN.Shared.GetPlayerId, p)
    if ok and type(id) == "string" and id ~= "" then
        return id
    end
    return nil
end

------------------------------------------------------------
-- CLAIM AREA SYNC
------------------------------------------------------------

local function requestAreas()
    if sendClientCommand then
        sendClientCommand("KIPN", "RequestExcavationAreas", {})
    end
end

local function onServerCommand(module, command, args)
    if module ~= "KIPN"
        or not KIPN.Shared or not KIPN.Shared.Commands
        or command ~= KIPN.Shared.Commands.SERVER_RESPONSE
        or type(args) ~= "table"
    then
        return
    end

    if args.event == "KIPN_ExcavationAreas" then
        local data = args.data
        areas = (type(data) == "table" and type(data.areas) == "table")
            and data.areas or {}
        return
    end

    if KIPN.Shared.ResponseEvents
        and args.event == KIPN.Shared.ResponseEvents.EXCAVATION_CLAIM_SUCCESSFUL
    then
        requestAreas()
    end
end

------------------------------------------------------------
-- BLOCKING QUERY
------------------------------------------------------------

-- kind: "Loot" | "Build" (excavate handled elsewhere)
local function isBlocked(x, y, z, kind)
    if not x or not y then return false end
    if #areas == 0 then return false end

    mySteamId = mySteamId or resolveMySteamId()

    local sv = SandboxVars and SandboxVars.KIPN
    local allow
    if kind == "Loot" then
        allow = not sv or sv.ExcavationAllowNonOwnerLoot ~= false
    elseif kind == "Build" then
        allow = not sv or sv.ExcavationAllowNonOwnerBuild ~= false
    else
        allow = true
    end
    if allow then return false end

    local fz = math.floor(z or 0)
    for _, a in ipairs(areas) do
        if (a.z == nil or math.floor(a.z) == fz)
            and x >= a.x1 and x <= a.x2
            and y >= a.y1 and y <= a.y2
        then
            -- inside a claimed plot; blocked only if it isn't ours
            if not mySteamId or tostring(a.ownerSteamId or "") ~= mySteamId then
                return true
            end
        end
    end
    return false
end

KIPN_ExcavationAccessEnforcement.IsBlocked = isBlocked

local function squareBlocked(square, kind)
    if not square then return false end
    return isBlocked(square:getX(), square:getY(), square:getZ(), kind)
end

------------------------------------------------------------
-- LOOT: wrap ISInventoryTransferAction:isValid
------------------------------------------------------------

-- The square of the WORLD object a container belongs to, or nil for a
-- carried inventory (player, bag) -- transfers within carried inventory
-- are never gated even if the player is standing on a claimed tile.
local function containerWorldSquare(container)
    if not container or type(container.getParent) ~= "function" then
        return nil
    end
    local parent = container:getParent()
    if not parent then return nil end
    if type(instanceof) == "function" and instanceof(parent, "IsoGameCharacter") then
        return nil
    end
    if type(parent.getSquare) == "function" then
        return parent:getSquare()
    end
    return nil
end

if ISInventoryTransferAction then
    local origIsValid = ISInventoryTransferAction.isValid
    function ISInventoryTransferAction:isValid()
        local ok = origIsValid(self)
        if not ok then return false end

        local srcSq = containerWorldSquare(self.srcContainer)
        local dstSq = containerWorldSquare(self.destContainer)

        if squareBlocked(srcSq, "Loot") or squareBlocked(dstSq, "Loot") then
            local p = self.character
            if p and type(p.Say) == "function"
                and (not self._kipnLootWarnAt or nowMs() - self._kipnLootWarnAt > 3000)
            then
                self._kipnLootWarnAt = nowMs()
                p:Say("This is a claimed excavation site. You can't take from here.")
            end
            return false
        end

        return true
    end
end

------------------------------------------------------------
-- BUILD / DESTROY: context-menu filter
------------------------------------------------------------

-- World-object context-menu options a non-owner must not get inside a
-- claimed plot: structure removal, moveable pickup, and terrain digging.
local DESTROY_OPTION_NAMES = {
    "Disassemble", "Dismantle", "Destroy", "Sledgehammer",
    "Pick Up", "Grab", "Take",
    "Dig", "Remove Grass", "Fill", "Shovel Ground", "Dig Furrow",
}

local function menuTargetSquare(worldobjects)
    if not worldobjects then return nil end
    -- worldobjects can be a Lua table or a Java ArrayList
    local first
    if worldobjects.get then
        first = worldobjects:size() > 0 and worldobjects:get(0) or nil
    else
        first = worldobjects[1]
    end
    if first and type(first.getSquare) == "function" then
        return first:getSquare()
    end
    return nil
end

local function onFillWorldObjectContextMenu(playerIndex, context, worldobjects, test)
    if test then return end

    local square = menuTargetSquare(worldobjects)
    if not squareBlocked(square, "Build") then return end

    for _, name in ipairs(DESTROY_OPTION_NAMES) do
        if type(context.removeOptionByName) == "function" then
            context:removeOptionByName(name)
        end
    end
end

------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------

local function onPlayerUpdate(player)
    if not player or player ~= getPlayer() then return end
    mySteamId = mySteamId or resolveMySteamId()
    tickCounter = tickCounter + 1
    if tickCounter >= REQUEST_EVERY_TICKS then
        tickCounter = 0
        requestAreas()
    end
end

local function onCreatePlayer()
    mySteamId = resolveMySteamId()
    requestAreas()
end

if Events.OnServerCommand then
    Events.OnServerCommand.Add(onServerCommand)
end
if Events.OnPlayerUpdate then
    Events.OnPlayerUpdate.Add(onPlayerUpdate)
end
if Events.OnCreatePlayer then
    Events.OnCreatePlayer.Add(onCreatePlayer)
end
if Events.OnFillWorldObjectContextMenu then
    Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
end

log("Excavation access enforcement loaded.")
