-- KIPN_EventLoadoutService.lua
--
-- Starting loadouts (KIPN.Shared.EventLoadouts): what a participant
-- wakes up wearing and holding, as in Pillow's Random Scenarios -- the
-- soldier's rifle, the prisoner's jumpsuit and one tool, the patient's
-- gown and splint.
--
-- On joining (KIPN_EventParticipationService.BringIn):
--   1. Unless the loadout keeps gear, the player's own inventory goes
--      into escrow (the same escrow Naked and Afraid uses), returned
--      when the event ends.
--   2. The loadout's items are created in their inventory, each tagged
--      with the event instance so they can be taken back at the end.
--      Bags are filled; "thrown clear" items land beside the player.
--   3. The player's own game is told to put the clothes on, take the
--      weapon in hand and apply the loadout's condition and injuries
--      (client/KIPN_EventLoadoutClient.lua) -- worn state, stats and
--      body damage belong to the player's game in multiplayer.
--
-- On release, every tagged item is removed before the escrow is
-- restored.

if isClient() then return end

require "KIPN_Shared"
require "DynamicEvents_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventLoadoutService = KIPN.Server.EventLoadoutService or {}

local Loadout = KIPN.Server.EventLoadoutService
Loadout.TAG = "DE_LoadoutItem"

local function log(message)
    print("[DYNAMIC EVENTS LOADOUT] " .. tostring(message))
end

-- The loadout an event gives: its own, or NAKED for Naked and Afraid.
function Loadout.For(definition)
    local id = definition and definition.loadout
    if id and id ~= "NONE" and (KIPN.Shared.EventLoadouts or {})[id] then return id end
    if definition and definition.modifiers and definition.modifiers.NAKED_AND_AFRAID then return "NAKED" end
    return nil
end

-- Whether joining this event strips the player's own gear to escrow.
function Loadout.StripsGear(definition)
    local id = Loadout.For(definition)
    if not id then return false end
    return not KIPN.Shared.EventLoadouts[id].keepGear
end

local function tag(item, value)
    pcall(function() item:getModData()[Loadout.TAG] = value end)
end

local function create(runtime, fullType)
    local item = KIPN.Server.CreateItem(fullType)
    if not item then
        log("unknown item " .. tostring(fullType))
        return nil
    end
    tag(item, runtime.instanceId)
    return item
end

local function give(runtime, inventory, fullType)
    local item = create(runtime, fullType)
    if not item then return nil end
    inventory:AddItem(item)
    if type(sendAddItemToContainer) == "function" then pcall(sendAddItemToContainer, inventory, item) end
    return item
end

local function fill(runtime, container, list)
    for _, fullType in ipairs(list or {}) do
        local item = create(runtime, fullType)
        if item then pcall(function() container:AddItem(item) end) end
    end
end

local function pick(list, count)
    local pool, out = {}, {}
    for _, value in ipairs(list or {}) do pool[#pool + 1] = value end
    for _ = 1, math.min(count or 0, #pool) do
        out[#out + 1] = table.remove(pool, ZombRand(1, #pool + 1))
    end
    return out
end

local function bagContainer(bag)
    local ok, container = pcall(function() return bag:getItemContainer() end)
    if ok and container then return container end
    ok, container = pcall(function() return bag:getInventory() end)
    return ok and container or nil
end

-- Gives one player the event's loadout. Returns the loadout id given.
function Loadout.Apply(player, definition, runtime)
    local id = Loadout.For(definition)
    if not id then return nil end
    local spec = KIPN.Shared.EventLoadouts[id]
    local inventory = player:getInventory()
    local wear, hands = {}, nil

    for _, fullType in ipairs(spec.wear or {}) do
        if give(runtime, inventory, fullType) then wear[#wear + 1] = fullType end
    end

    if spec.hands then hands = spec.hands end
    if spec.handsOneOf then
        hands = (spec.rareHands and ZombRand(1, (spec.rareChance or 100) + 1) == 1) and spec.rareHands
            or spec.handsOneOf[ZombRand(1, #spec.handsOneOf + 1)]
    end
    if hands then give(runtime, inventory, hands) end

    for _, fullType in ipairs(spec.items or {}) do give(runtime, inventory, fullType) end
    if spec.oneOf and #spec.oneOf > 0 then give(runtime, inventory, spec.oneOf[ZombRand(1, #spec.oneOf + 1)]) end

    local bagType
    if spec.bag then
        local bag = give(runtime, inventory, spec.bag)
        local container = bag and bagContainer(bag)
        if container then
            fill(runtime, container, spec.bagItems)
            fill(runtime, container, pick(spec.randomBag, spec.randomPicks))
            bagType = spec.bag
        end
    end

    -- Thrown clear: a few tiles away, where the player has to go and get it.
    for index, drop in ipairs(spec.dropNearby or {}) do
        local item = create(runtime, drop.item)
        if item then
            local container = bagContainer(item)
            if container then fill(runtime, container, drop.contents) end
            pcall(function()
                local square = getCell():getGridSquare(math.floor(player:getX()) + 2 + index, math.floor(player:getY()) - 2, player:getZ())
                square:AddWorldInventoryItem(item, 0.5, 0.5, 0)
            end)
        end
    end

    local event = KIPN.Shared.ResponseEvents.EVENT_APPLY_LOADOUT
    KIPN.Server.SendToPlayer(player, event, {
        loadout = id,
        difficulty = runtime.difficulty or "NORMAL",
        wear = wear,
        hands = hands,
        twoHanded = spec.twoHanded == true,
        bag = bagType,
        stats = spec.stats,
        injuries = spec.injuries,
    })
    log("Apply() -> " .. tostring(player:getUsername()) .. " as " .. id)
    return id
end

-- Takes back everything the loadout handed out, worn or carried.
function Loadout.Remove(player, runtime)
    local removed = 0
    local function sweep(container)
        local ok, items = pcall(function() return container:getItems() end)
        if not ok or not items then return end
        for i = items:size() - 1, 0, -1 do
            local item = items:get(i)
            local tagOk, value = pcall(function() return item:getModData()[Loadout.TAG] end)
            if tagOk and value == runtime.instanceId then
                pcall(function()
                    if player.removeFromHands then player:removeFromHands(item) end
                    if player.removeWornItem and player:isEquipped(item) then player:removeWornItem(item) end
                end)
                pcall(function()
                    container:Remove(item)
                    if type(sendRemoveItemFromContainer) == "function" then sendRemoveItemFromContainer(container, item) end
                end)
                removed = removed + 1
            else
                local nestedOk, nested = pcall(function() return item:getItemContainer() end)
                if nestedOk and nested then sweep(nested) end
            end
        end
    end
    sweep(player:getInventory())
    return removed
end

function Loadout.Initialize()
    log("Initialize()")
    return true
end

log("module loaded")
