-- Bass Masters: what happens when you land a fish, catch and release, and hearing about the rest
-- of the server's catches. The server decides what you caught (BassMasters_Server.lua) and tells
-- you; your own record is kept on the player (getModData().BassMasters), so it saves with the
-- character.

require "BassMasters_Shared"

local BM = BassMasters

function BM.data(player)
    local md = player:getModData()
    md.BassMasters = md.BassMasters or {}
    local d = md.BassMasters
    d.species = d.species or {}
    d.releases = d.releases or 0
    d.trophyFish = d.trophyFish or 0
    d.bestBass = d.bestBass or 0
    d.bestBag = d.bestBag or 0
    d.goodDays = d.goodDays or 0
    d.today = d.today or { day = -1, kinds = {}, bag = {} }
    return d
end

local function say(player, text, good)
    if good ~= false then
        HaloTextHelper.addGoodText(player, text)
    else
        HaloTextHelper.addText(player, text)
    end
end

-- ---------------------------------------------------------------- the server's book

-- The shared record: trophy fish, species records and anglers. Empty until the server sends it.
function BM.serverBook()
    local b = ModData.exists("BassMasters") and ModData.get("BassMasters") or {}
    b.records = b.records or {}
    b.trophies = b.trophies or {}
    b.anglers = b.anglers or {}
    return b
end

-- The local player a message is about (split screen can have several), or the first one.
local function localPlayer(username)
    for i = 0, getNumActivePlayers() - 1 do
        local p = getSpecificPlayer(i)
        if p and p:getUsername() == username then return p end
    end
    return getPlayer()
end

-- News from the server: what you landed or let go, or somebody's trophy or record.
function BM.onServerCommand(command, args)
    if type(args) ~= "table" then return end
    local player = localPlayer(args.who)
    if not player then return end
    if command == "landed" then
        BM.onLanded(player, args)
        return
    elseif command == "released" then
        BM.onReleased(player, args)
        return
    end
    local mine = args.who == player:getUsername()
    local fish = BM.displayName(args.type or "")
    if command == "trophy" and not mine then
        say(player, string.format("%s landed a trophy %s: %.2f lb!", args.name, fish, args.lb))
    elseif command == "record" then
        if mine then
            say(player, string.format("New server record %s: %.2f lb", fish, args.lb))
        else
            say(player, string.format("%s took the server record %s from %s: %.2f lb", args.name, fish, args.was or "?", args.lb), false)
        end
    end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module == "BassMasters" then BM.onServerCommand(command, args) end
end)

Events.OnReceiveGlobalModData.Add(function(key, data)
    if key == "BassMasters" and type(data) == "table" then
        ModData.add(key, data)
        if BM.window and BM.window:isVisible() then BM.window:refresh() end
    end
end)

Events.OnGameStart.Add(function()
    if isClient() then ModData.request("BassMasters") end
end)

-- ---------------------------------------------------------------- landing a fish

-- Today's catches: the kinds you've landed and your three heaviest bass.
local function today(player, t, lb)
    local d = BM.data(player)
    local day = BM.dayNumber()
    if d.today.day ~= day then
        d.today = { day = day, kinds = {}, bag = {} }
    end
    if not d.today.kinds[t] then
        d.today.kinds[t] = true
        local n = 0
        for _ in pairs(d.today.kinds) do n = n + 1 end
        if n == 3 then
            d.goodDays = d.goodDays + 1
            say(player, "A good day's fishing: three kinds landed.")
        end
    end
    if BM.BASS[t] then
        table.insert(d.today.bag, lb)
        table.sort(d.today.bag, function(a, b) return a > b end)
        while #d.today.bag > 3 do table.remove(d.today.bag) end
        if #d.today.bag == 3 then
            local total = math.floor((d.today.bag[1] + d.today.bag[2] + d.today.bag[3]) * 100 + 0.5) / 100
            if total > d.bestBag then d.bestBag = total end
        end
    end
end

-- The server says you landed a fish: { type, lb, trophy }.
function BM.onLanded(player, args)
    local t = args.type
    local lb = tonumber(args.lb) or 0
    if type(t) ~= "string" or lb <= 0 then return end
    local d = BM.data(player)
    local s = d.species[t] or { count = 0, best = 0 }
    s.count = s.count + 1
    local pb = lb > s.best
    if pb then s.best = lb end
    d.species[t] = s
    if BM.BASS[t] and lb > d.bestBass then d.bestBass = lb end
    if args.trophy then
        d.trophyFish = d.trophyFish + 1
        say(player, string.format("TROPHY %s! %.2f lb", BM.displayName(t), lb))
    elseif pb and s.count > 1 then
        say(player, string.format("New personal best %s: %.2f lb", BM.displayName(t), lb))
    end
    today(player, t, lb)
    if BM.window and BM.window:isVisible() then BM.window:refresh() end
end

-- ---------------------------------------------------------------- catch and release

-- Ask the server to let the fish go; it does the work and says "released" back.
function BM.release(player, item)
    if not item or not BM.nearWater(player) then return end
    if isClient() then
        sendClientCommand(player, "BassMasters", "release", { id = item:getID() })
    elseif BM.Server then
        BM.Server.release(player, item)
    end
end

function BM.onReleased(player, args)
    local d = BM.data(player)
    d.releases = d.releases + 1
    say(player, "You let the " .. BM.displayName(args.type or "") .. " go. It doesn't look back.")
end

local function isRod(item)
    local t = item:getType()
    return t and (string.find(t, "FishingRod") ~= nil)
end

local function fillMenu(playerNum, context, items)
    local player = getSpecificPlayer(playerNum)
    for _, v in ipairs(items) do
        local item = v
        if not instanceof(v, "InventoryItem") then item = v.items[1] end
        if item and BM.isFish(item) and item:getFullType() ~= "Base.BaitFish" then
            local opt = context:addOption("Release (Bass Masters)", player, BM.release, item)
            if not BM.nearWater(player) then
                opt.notAvailable = true
                local tip = ISInventoryPaneContextMenu.addToolTip()
                tip.description = "Stand by the water to let it go."
                opt.toolTip = tip
            end
        end
        if item and (BM.isFish(item) or isRod(item)) then
            context:addOption("Bass Masters logbook", player, function(p) BM.openLogbook(p) end)
        end
        break
    end
end
Events.OnFillInventoryObjectContextMenu.Add(fillMenu)
