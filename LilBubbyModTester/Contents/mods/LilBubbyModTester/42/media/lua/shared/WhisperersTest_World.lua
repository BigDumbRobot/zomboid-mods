require "WhisperersTest_Checks"

-- World changes for The Whisperers suite. They run where the world is
-- authoritative: on the server in multiplayer (WhisperersTest_Server.lua), or
-- directly in single player. Every item and corpse created is tagged with
-- WhisperersTest.MARKER so cleanup removes only test objects.
WhisperersTest.World = WhisperersTest.World or {}
local World = WhisperersTest.World
local MARKER = WhisperersTest.MARKER

World.zombies = World.zombies or {}  -- by owner key: spawned test zombies

local function ownerKey(player)
    return isServer() and player:getUsername() or "local"
end

local function square(player, dx, dy)
    return getCell():getGridSquare(math.floor(player:getX()) + dx, math.floor(player:getY()) + dy, math.floor(player:getZ()))
end

local function give(player, fullType)
    local inventory = player:getInventory()
    local item = inventory:AddItem(fullType)
    if not item then return nil end
    item:getModData()[MARKER] = true
    if isServer() then sendAddItemToContainer(inventory, item) end
    return item
end

local function raise(player, perk, level)
    for _ = 1, 12 do
        if player:getPerkLevel(perk) >= level then break end
        local missing = perk:getTotalXpForLevel(level) - player:getXp():getXP(perk)
        addXpNoMultiplier(player, perk, math.max(1, missing + 1))
    end
    return player:getPerkLevel(perk)
end

-- Tools and materials, plus the skills a skin suit and a mask repair need.
function World.setup(player, args)
    local given = {}
    for _, fullType in ipairs({ "Base.HuntingKnife", "Base.Katana", "Base.Machete",
            "Base.Thread", "Base.Nails", "Base.LongStick" }) do
        if give(player, fullType) then given[#given + 1] = fullType end
    end
    return {
        given = #given,
        butchering = raise(player, Perks.Butchering, WhisperersTest.MIN_BUTCHERING),
        tailoring = raise(player, Perks.Tailoring, WhisperersTest.MIN_TAILORING),
    }
end

-- Items handed out mid-test. The needle comes after the nail-sewn mask, so
-- that recipe can only use the nail.
World.GIVABLE = { ["Base.Needle"] = true, ["Base.Tshirt_PoloTINT"] = true }

function World.give(player, args)
    if not World.GIVABLE[args.type] then return { error = "not a test item: " .. tostring(args.type) } end
    return give(player, args.type) and {} or { error = "could not create " .. args.type }
end

-- A fresh face mask and skin suit for the zombie mannerisms test.
function World.gaitKit(player, args)
    local G = Whisperers.Gear
    for _, fullType in ipairs({ G.Types.Mask, G.Types.Suit }) do
        local item = give(player, fullType)
        if not item then return { error = "could not create " .. fullType } end
        item:setCondition(item:getConditionMax())
        if isServer() then syncItemFields(player, item) end
    end
    return {}
end

-- Heads for the head stake test, one kind per round, each with a long stick.
-- Player heads carry the tester's own look, as beheading a player records it.
WhisperersTest.STAKE_KINDS = {
    { label = "zombie head" }, { label = "zombie head" }, { label = "zombie head" }, { label = "zombie head" },
    { label = "faceless zombie head", faceless = true }, { label = "faceless zombie head", faceless = true },
    { label = "your head", owner = true, look = true }, { label = "your head", owner = true, look = true },
    { label = "your faceless head", owner = true, look = true, faceless = true },
    { label = "an old player head (no look recorded)", owner = true },
}

function World.stakeKit(player, args)
    local W = Whisperers
    local kind = WhisperersTest.STAKE_KINDS[tonumber(args.kind) or 0]
    if not kind or not W.Stake then return { error = "no head stake kind " .. tostring(args.kind) } end
    local G = W.Gear
    local head = give(player, kind.faceless and G.Types.FacelessHead or G.Types.Head)
    if not head then return { error = "the head could not be created" } end
    local md = head:getModData()
    local owner = kind.owner and G.playerDisplayName(player) or nil
    md.WhispOwner = owner
    md.WhispFaceless = kind.faceless or nil
    if kind.look then md[W.Stake.LookKey] = W.Stake.captureLook(player) end
    G.setItemName(head, G.headName(owner))
    if isServer() then syncItemModData(player, head); syncItemFields(player, head) end
    if not give(player, "Base.LongStick") then return { error = "the stick could not be created" } end
    return { owner = owner }
end

-- Test only: places the listed stake items in a row two squares south of the
-- player, through the same moveables code as the Place menu. args.first is
-- the slot in the row for the first one, so stakes can be placed one at a time.
function World.placeStakes(player, args)
    local S = Whisperers.Stake
    local wanted = {}
    for _, id in ipairs(type(args.ids) == "table" and args.ids or {}) do wanted[tonumber(id)] = true end
    local inventory = player:getInventory()
    local items = inventory:getAllTypeRecurse(Whisperers.Gear.Types.Stake)
    local placed = {}
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if wanted[item:getID()] then
            local hadBytes = item:getByteData() ~= nil
            local sq = square(player, (tonumber(args.first) or 0) + #placed - 4, 2)
            if not sq then return { error = "no square for stake " .. (#placed + 1) } end
            local props = ISMoveableSpriteProps.new(S.Sprite)
            props:placeMoveableInternal(sq, item, S.Sprite)
            local container = item:getContainer() or inventory
            container:Remove(item)
            if isServer() then sendRemoveItemFromContainer(container, item) end
            local view
            local objects = sq:getObjects()
            for j = objects:size() - 1, 0, -1 do
                local obj = objects:get(j)
                if S.isStake(obj) then
                    obj:getModData()[MARKER] = true
                    if isServer() then obj:transmitModData() end
                    view = WhisperersTest.describeStake(obj)
                    break
                end
            end
            -- The server's own view, so each client can compare what it received.
            placed[#placed + 1] = { x = sq:getX(), y = sq:getY(), z = sq:getZ(), hadBytes = hadBytes, view = view }
        end
    end
    return { placed = placed }
end

-- A fresh corpse beside the player, optionally carrying a player's name
-- (as a real player corpse would, copied from the dead player's modData).
function World.corpse(player, args)
    local sq = square(player, args.dx or 1, args.dy or 0)
    if not sq then return { error = "no square beside you" } end
    local body = createRandomDeadBody(sq, 0)
    if not body then return { error = "the corpse could not be created" } end
    local md = body:getModData()
    md[MARKER] = true
    if type(args.owner) == "string" then md[Whisperers.Gear.NameKey] = args.owner end
    if isServer() then body:transmitModData() end
    return { x = sq:getX(), y = sq:getY(), z = sq:getZ() }
end

function World.zombie(player, args)
    local sq = square(player, args.dx or 7, args.dy or 0)
    if not sq then return { error = "no square for the zombie" } end
    local zeds = addZombiesInOutfit(sq:getX(), sq:getY(), sq:getZ(), 1, "Naked", 50)
    local zed = zeds and zeds:size() > 0 and zeds:get(0) or nil
    if not zed then return { error = "the zombie could not be spawned" } end
    local key = ownerKey(player)
    World.zombies[key] = World.zombies[key] or {}
    table.insert(World.zombies[key], zed)
    return { x = sq:getX(), y = sq:getY(), z = sq:getZ() }
end

function World.removeZombies(player, args)
    local removed = 0
    for _, zed in ipairs(World.zombies[ownerKey(player)] or {}) do
        if not zed:isDead() then
            zed:removeFromWorld()
            zed:removeFromSquare()
            removed = removed + 1
        end
    end
    World.zombies[ownerKey(player)] = nil
    return { removed = removed }
end

-- The same hit the engine reports for a weapon strike.
function World.hit(player, args)
    triggerEvent("OnPlayerGetDamage", player, "WEAPONHIT", tonumber(args.damage) or 25)
    return {}
end

-- Makes the player's test guts the given number of hours old.
function World.ageGuts(player, args)
    local G = Whisperers.Gear
    local list = player:getInventory():getAllTypeRecurse(G.Types.Guts)
    if list:size() == 0 then return { error = "no guts to age" } end
    local gut = list:get(0)
    gut:getModData().WhispBorn = G.hours() - (tonumber(args.hours) or 72)
    G.refreshGuts(gut)
    if isServer() then
        syncItemModData(player, gut)
        syncItemFields(player, gut)
    end
    return { weight = gut:getActualWeight(), name = gut:getName() }
end

-- Scrubs all blood off the player and their worn clothing, as washing does.
function World.wash(player, args)
    local hv = player:getHumanVisual()
    for i = 0, BloodBodyPartType.MAX:index() - 1 do
        local part = BloodBodyPartType.FromIndex(i)
        hv:setBlood(part, 0)
        hv:setDirt(part, 0)
    end
    local worn = player:getWornItems()
    for i = 0, worn:size() - 1 do
        local item = worn:get(i):getItem()
        if instanceof(item, "Clothing") then
            local covered = BloodClothingType.getCoveredParts(item:getBloodClothingType())
            for j = 0, (covered and covered:size() or 0) - 1 do item:setBlood(covered:get(j), 0) end
            if isServer() then syncItemFields(player, item) end
        end
    end
    if isServer() then
        sendHumanVisual(player)
        syncVisuals(player)
    end
    return {}
end

-- Removes every test item (worn or carried) and every test corpse nearby,
-- and any test zombies. Items the mod
-- itself made during the test (guts, heads, masks...) are named by ID in
-- args.ids, so the player's own corpse gear is never touched.
function World.cleanup(player, args)
    World.removeZombies(player, args)
    local made = {}
    for _, id in ipairs(type(args.ids) == "table" and args.ids or {}) do made[tonumber(id)] = true end
    local items = 0
    local function sweep(container)
        local list = container:getItems()
        for i = list:size() - 1, 0, -1 do
            local item = list:get(i)
            if (item:hasModData() and item:getModData()[MARKER]) or made[item:getID()] then
                if player:isEquipped(item) then player:removeWornItem(item) end
                if player:getPrimaryHandItem() == item then player:setPrimaryHandItem(nil) end
                if player:getSecondaryHandItem() == item then player:setSecondaryHandItem(nil) end
                container:Remove(item)
                if isServer() then sendRemoveItemFromContainer(container, item) end
                items = items + 1
            elseif item.getItemContainer and item:getItemContainer() then
                sweep(item:getItemContainer())
            end
        end
    end
    sweep(player:getInventory())
    if isServer() then sendEquip(player) end
    local corpses = 0
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    for x = px - 3, px + 3 do
        for y = py - 3, py + 3 do
            local sq = getCell():getGridSquare(x, y, pz)
            local bodies = sq and sq:getDeadBodys()
            for i = (bodies and bodies:size() or 0) - 1, 0, -1 do
                local body = bodies:get(i)
                if body:getModData()[MARKER] then
                    sq:removeCorpse(body, false)
                    corpses = corpses + 1
                end
            end
        end
    end
    local stakes = 0
    for x = px - 6, px + 6 do
        for y = py - 6, py + 6 do
            local sq = getCell():getGridSquare(x, y, pz)
            local objects = sq and sq:getObjects()
            for i = (objects and objects:size() or 0) - 1, 0, -1 do
                local obj = objects:get(i)
                if instanceof(obj, "IsoMannequin") and obj:getModData()[MARKER] then
                    sq:transmitRemoveItemFromSquare(obj)
                    stakes = stakes + 1
                end
            end
        end
    end
    player:getModData().WhispGutsPct = nil
    return { items = items, corpses = corpses, stakes = stakes }
end
