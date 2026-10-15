require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "ISUI/ISWorldObjectContextMenu"

local SO = SacrificialOffering

-- The server stamps every player corpse with the owner's steam identity and
-- display name in modData (SO_PlayerLedger). body:setName() does not reliably
-- reach other clients, so each client applies the "<name>'s corpse" label
-- locally from that synced modData -- for the world body (hover / context menu)
-- and, if present, the draggable item.

local function ownerLabel(md)
    local playerName = md and md[SO.MOD_DATA.CORPSE_PLAYER_NAME]
    if type(playerName) ~= "string" then return nil end
    playerName = playerName:gsub("[%c]", "")
    if playerName == "" then return nil end
    return playerName .. "'s corpse"
end

local function applyCorpseLabel(object)
    if not object or not instanceof(object, "IsoDeadBody") then return end
    local animalOk, animal = pcall(function() return object:isAnimal() end)
    if animalOk and animal == true then return end
    local md = object.getModData and object:getModData()
    local label = ownerLabel(md)
    if not label then return end

    local nameOk, current = pcall(function() return object:getName() end)
    if not nameOk or current ~= label then
        pcall(function() object:setName(label) end)
    end
    local itemOk, item = pcall(function() return object:getItem() end)
    if itemOk and item then
        local customOk, custom = pcall(function() return item:isCustomName() end)
        local iNameOk, iName = pcall(function() return item:getName() end)
        if not customOk or custom ~= true or not iNameOk or iName ~= label then
            pcall(function()
                item:setName(label)
                item:setCustomName(true)
            end)
        end
    end
end

local function onLoadGridsquare(square)
    if not square then return end
    local bodies = square.getStaticMovingObjects and square:getStaticMovingObjects()
    if not bodies then return end
    for index = 0, bodies:size() - 1 do applyCorpseLabel(bodies:get(index)) end
end

-- A right-click is a natural re-check point: modData for a corpse first seen
-- before the server tagged it has certainly arrived by now.
local function onFillContextMenu(_playerIndex, _context, worldobjects)
    for _, object in ipairs(worldobjects or {}) do
        applyCorpseLabel(object)
        local square = object and object.getSquare and object:getSquare()
        if square then onLoadGridsquare(square) end
    end
end

-- Light periodic sweep of squares around the player: catches corpses that were
-- already visible when the server tagged them (so no OnObjectAdded fires) and
-- that the player never right-clicks or walks a chunk boundary near.
local SWEEP_RADIUS = 6
local SWEEP_INTERVAL_MS = 3000
local nextSweepAt = 0

local function sweepNearby(player)
    if not player then return end
    local now = SO.Util.NowMs()
    if now < nextSweepAt then return end
    nextSweepAt = now + SWEEP_INTERVAL_MS
    local cell = getCell()
    if not cell then return end
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    for dx = -SWEEP_RADIUS, SWEEP_RADIUS do
        for dy = -SWEEP_RADIUS, SWEEP_RADIUS do
            onLoadGridsquare(cell:getGridSquare(px + dx, py + dy, pz))
        end
    end
end

Events.OnObjectAdded.Add(applyCorpseLabel)
if Events.OnDeadBodySpawn then Events.OnDeadBodySpawn.Add(applyCorpseLabel) end
Events.LoadGridsquare.Add(onLoadGridsquare)
Events.OnFillWorldObjectContextMenu.Add(onFillContextMenu)
Events.OnPlayerUpdate.Add(sweepNearby)

return true
