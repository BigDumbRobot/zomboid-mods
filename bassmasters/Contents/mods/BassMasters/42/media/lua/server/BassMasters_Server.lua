-- Bass Masters: the server's book. Every angler on the server shares one record of trophy fish,
-- the heaviest of each species, and who holds them. It lives in global ModData ("BassMasters"),
-- so it saves with the world. In single player the same code runs on the one machine.
--
-- The server is the authority on every catch: it reads the type, weight and trophy flag off its
-- own copy of the fish (vanilla makes fish on the server in multiplayer), then tells the angler
-- what they landed. Clients never report a weight.

if isClient() then return end

require "BassMasters_Shared"
require "TimedActions/Fishing/TimedActions/ISPickupFishAction"

local BM = BassMasters
BM.Server = {}

local KEY = "BassMasters"
local MAX_TROPHIES = 30

local function book()
    local b = ModData.getOrCreate(KEY)
    b.records = b.records or {}
    b.trophies = b.trophies or {}
    b.anglers = b.anglers or {}
    return b
end

Events.OnInitGlobalModData.Add(book)

-- Tell everyone. In single player there's nobody to send to, so the client hears it directly.
local function announce(command, args)
    if isServer() then
        sendServerCommand(KEY, command, args)
    elseif BM.onServerCommand then
        BM.onServerCommand(command, args)
    end
end

-- Tell one player.
local function tell(player, command, args)
    if isServer() then
        sendServerCommand(player, KEY, command, args)
    elseif BM.onServerCommand then
        BM.onServerCommand(command, args)
    end
end

-- A fish has come off the line. Everything about it is read from the server's item.
function BM.Server.landed(player, item)
    if not player or not BM.isFish(item) then return end
    local t = item:getFullType()
    if t == "Base.BaitFish" then return end
    local lb = BM.pounds(item)
    if lb <= 0 then return end
    local trophy = BM.isTrophy(item)

    local b = book()
    local who = player:getUsername() or "?"
    local name = tostring(player:getDisplayName() or who):sub(1, 40)
    local master = BM.TRAIT ~= nil and player:hasTrait(BM.TRAIT)
    local day = BM.dayNumber()
    local changed = false

    local a = b.anglers[who] or { name = name, trophies = 0, bestBass = 0 }
    b.anglers[who] = a
    if a.name ~= name or a.master ~= master then
        a.name = name
        a.master = master
        changed = true
    end

    -- The heaviest of each species, server-wide.
    local rec = b.records[t]
    if not rec or lb > rec.lb then
        b.records[t] = { lb = lb, who = who, name = name, day = day }
        changed = true
        if rec and BM.sandbox("AnnounceRecords", true) then
            announce("record", { who = who, name = name, type = t, lb = lb, was = rec.name })
        end
    end

    if BM.BASS[t] and lb > (a.bestBass or 0) then
        a.bestBass = lb
        changed = true
    end

    if trophy then
        a.trophies = (a.trophies or 0) + 1
        table.insert(b.trophies, 1, { who = who, name = name, type = t, lb = lb, day = day })
        while #b.trophies > MAX_TROPHIES do table.remove(b.trophies) end
        changed = true
        if BM.sandbox("AnnounceTrophies", true) then
            announce("trophy", { who = who, name = name, type = t, lb = lb })
        end
    end

    if changed and isServer() then
        ModData.transmit(KEY)
    end

    tell(player, "landed", { who = who, type = t, lb = lb, trophy = trophy })
end

-- In multiplayer the server runs serverStart with its own copy of the fish; in single player
-- start() is the only place the catch happens.
local vanillaServerStart = ISPickupFishAction.serverStart
function ISPickupFishAction:serverStart()
    vanillaServerStart(self)
    BM.Server.landed(self.character, self.item)
end

local vanillaStart = ISPickupFishAction.start
function ISPickupFishAction:start()
    vanillaStart(self)
    if not isServer() and not isClient() then
        BM.Server.landed(self.character, self.item)
    end
end

-- ---------------------------------------------------------------- catch and release

function BM.Server.release(player, item)
    if not player or not item or not BM.isFish(item) or item:getFullType() == "Base.BaitFish" then return end
    if not BM.nearWater(player) then return end
    local container = item:getContainer()
    if not container or container ~= player:getInventory() then return end
    local t = item:getFullType()
    local lb = BM.pounds(item)
    container:DoRemoveItem(item)
    if isServer() then sendRemoveItemFromContainer(container, item) end
    addXp(player, Perks.Fishing, 4 + math.floor(lb))
    player:getStats():remove(CharacterStat.BOREDOM, 8)
    player:getStats():remove(CharacterStat.UNHAPPINESS, 6)
    player:getStats():remove(CharacterStat.STRESS, 4)
    tell(player, "released", { who = player:getUsername(), type = t })
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= KEY then return end
    if command == "release" and type(args) == "table" and type(args.id) == "number" then
        BM.Server.release(player, player:getInventory():getItemWithID(args.id))
    end
end)
