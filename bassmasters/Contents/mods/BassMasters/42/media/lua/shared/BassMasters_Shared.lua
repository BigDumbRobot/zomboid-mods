-- Bass Masters: the data. Species notes, trophy fish, and the template for the Bass Master trait.
-- Loaded on both sides: the trophy roll happens wherever vanilla makes the fish.

require "Fishing/Fish"

BassMasters = BassMasters or {}
local BM = BassMasters

BM.VERSION = 2

function BM.sandbox(key, default)
    local opts = SandboxVars and SandboxVars.BassMasters
    if opts and opts[key] ~= nil then return opts[key] end
    return default
end

-- The black basses and their cousins.
BM.BASS = {
    ["Base.LargemouthBass"] = true, ["Base.SmallmouthBass"] = true, ["Base.SpottedBass"] = true,
    ["Base.WhiteBass"] = true, ["Base.StripedBass"] = true,
}

-- Something true about each fish, for the logbook.
BM.NOTES = {
    ["Base.LargemouthBass"] = "The big one. Its jaw reaches back past its eye. Likes weeds, logs and still water.",
    ["Base.SmallmouthBass"] = "Bronze, with a jaw that stops short of the eye. Likes rocks and current, and fights like it's twice the size.",
    ["Base.SpottedBass"] = "The Kentucky bass: Kentucky's own state fish. Rows of dark spots below the stripe give it away.",
    ["Base.WhiteBass"] = "Silver, with thin dark stripes. Runs up the rivers in big schools every spring.",
    ["Base.StripedBass"] = "Born to swim from the sea up rivers. The ones in Kentucky's lakes were stocked there.",
    ["Base.Bluegill"] = "A dark spot on the gill flap, and a dinner-plate shape. Most people's first fish.",
    ["Base.WhiteCrappie"] = "Count the spines on its back fin: a white crappie has five or six.",
    ["Base.BlackCrappie"] = "Count the spines on its back fin: a black crappie has seven or eight.",
    ["Base.RedearSunfish"] = "The shellcracker: it crunches up snails with teeth in its throat.",
    ["Base.YellowPerch"] = "Yellow with dark bars. Travels in schools: catch one, and stay put.",
    ["Base.Sauger"] = "Walleye's smaller cousin. Black spots on its back fin; no white tip on its tail.",
    ["Base.GreenSunfish"] = "Big mouth for a sunfish, and it'll bite anything.",
    ["Base.Walleye"] = "Glassy eyes that see in the dark, so it feeds at dusk and dawn. A white tip on the bottom of its tail.",
    ["Base.FreshwaterDrum"] = "It grunts. Its ear stones were kept as lucky charms.",
    ["Base.BlueCatfish"] = "The biggest catfish in North America. Blue-grey, with a straight-edged back fin.",
    ["Base.ChannelCatfish"] = "Forked tail, and spots when it's young. Finds food by taste: its whole skin can taste.",
    ["Base.FlatheadCatfish"] = "A flat head and a square tail. Eats live fish, mostly at night.",
    ["Base.Muskellunge"] = "The fish of ten thousand casts. Anglers say that's about how many it takes to catch one.",
    ["Base.AligatorGar"] = "Two rows of teeth in its upper jaw, and fish like it were swimming when the dinosaurs were.",
    ["Base.Paddlefish"] = "The spoonbill. No teeth: it swims with its mouth open and filters out tiny animals.",
    ["Base.BaitFish"] = "Bait. Somebody has to be.",
}

-- ---------------------------------------------------------------- the Bass Master trait

-- The trait itself is registered in media/registries.lua and defined in
-- media/scripts/BassMasters_Traits.txt. It is a profession trait, so nobody can pick it at
-- character creation: it can only be earned, and only Adaptive Traits hands it out.
BM.TRAIT = BassMastersRegistry and BassMastersRegistry.BassMaster

-- What it takes to be a Bass Master. Each entry reads the player's Bass Masters record and says
-- how far along they are; when every count reaches its goal, the trait is earned. Progress is
-- kept whether or not Adaptive Traits is installed, so adding it later picks up where you are.
BM.MASTER = {
    { id = "all_bass", name = "The Full Bass Set", text = "Land all five kinds of bass", goal = 5,
      count = function(d)
          local n = 0
          for t, _ in pairs(d.species) do
              if BM.BASS[t] then n = n + 1 end
          end
          return n
      end },
    { id = "ten_species", name = "Ten Kinds of Fish", text = "Land ten different species", goal = 10,
      count = function(d)
          local n = 0
          for _ in pairs(d.species) do n = n + 1 end
          return n
      end },
    { id = "record_book", name = "The Record Book", text = "Land a bass of 10 lb or more", goal = 10, unit = "lb",
      count = function(d) return d.bestBass or 0 end },
    { id = "classic_bag", name = "A Classic Bag", text = "Land three bass in one day that weigh 15 lb together", goal = 15, unit = "lb",
      count = function(d) return d.bestBag or 0 end },
    { id = "good_days", name = "Ten Good Days", text = "Land three different kinds of fish in a day, on ten days", goal = 10,
      count = function(d) return d.goodDays or 0 end },
    { id = "release", name = "Catch and Release", text = "Let ten fish go", goal = 10,
      count = function(d) return d.releases or 0 end },
    { id = "trophy", name = "Tall Tale", text = "Land a trophy fish", goal = 1,
      count = function(d) return d.trophyFish or 0 end },
}

-- Each requirement with its progress, and whether all of them are met.
function BM.masterProgress(d)
    local rows, all = {}, true
    for _, r in ipairs(BM.MASTER) do
        local n = r.count(d)
        local done = n >= r.goal
        if not done then all = false end
        table.insert(rows, { req = r, count = n, done = done })
    end
    return rows, all
end

-- ---------------------------------------------------------------- fish

function BM.config(fullType)
    if not Fishing or not Fishing.fishes then return nil end
    for _, f in ipairs(Fishing.fishes) do
        if f.itemType == fullType then return f end
    end
    return nil
end

-- Fish weights in pounds, from a fish item.
function BM.pounds(item)
    if not item then return 0 end
    return math.floor(item:getActualWeight() * 100 + 0.5) / 100
end

function BM.isFish(item)
    return item ~= nil and BM.config(item:getFullType()) ~= nil
end

function BM.displayName(fullType)
    local s = getScriptManager():FindItem(fullType)
    return s and s:getDisplayName() or fullType
end

-- The best three things to put on the hook for a species, from vanilla's own lure table.
function BM.bestLures(fullType, n)
    local f = BM.config(fullType)
    if not f or not f.lure then return {} end
    local list = {}
    for lure, chance in pairs(f.lure) do
        if chance and chance > 0 then table.insert(list, { lure, chance }) end
    end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local out = {}
    for i = 1, math.min(n or 3, #list) do
        table.insert(out, BM.displayName(list[i][1]))
    end
    return out
end

-- Standing by the water (or on it).
function BM.nearWater(player)
    local sq = player:getCurrentSquare()
    if not sq then return false end
    for dx = -3, 3 do
        for dy = -3, 3 do
            local s = getCell():getGridSquare(sq:getX() + dx, sq:getY() + dy, sq:getZ())
            if s and s:getProperties():has(IsoFlagType.water) then return true end
        end
    end
    return false
end

-- The in-game day number, counting from the start of the world.
function BM.dayNumber()
    return math.floor(getGameTime():getWorldAgeHours() / 24)
end

-- ---------------------------------------------------------------- trophy fish

-- The heaviest a trophy of this species can be, in kg.
local function trophyTopKg(cfg)
    return math.max(cfg.trophyWeight or 0, cfg.maxWeight * 1.25)
end

-- Heavier than anything this species could be, in pounds: used by the server to throw out
-- reports that can't be true.
function BM.plausibleLb(fullType)
    local cfg = BM.config(fullType)
    if not cfg then return 0 end
    return trophyTopKg(cfg) * 2.2 * 1.05
end

-- A trophy is one Bass Masters rolled, or one of vanilla's "Legendary" fish (heavier than the
-- species' normal maximum, which vanilla only allows at Fishing 8 and up).
function BM.isTrophy(item)
    if not item then return false end
    if item:getModData().BassMasters_Trophy then return true end
    local cfg = BM.config(item:getFullType())
    return cfg ~= nil and cfg.maxWeight ~= nil and item:getActualWeight() > cfg.maxWeight * 2.2 * 1.01
end

-- Turn a freshly made fish into a trophy: past the species' normal maximum, up toward vanilla's
-- trophy size. Food values scale with it, the same way vanilla scales them for size.
function BM.makeTrophy(fish, item, cfg)
    local oldLb = item:getActualWeight()
    if not oldLb or oldLb <= 0 then return end
    local kg = cfg.maxWeight + ZombRandFloat(0.1, 1.0) * (trophyTopKg(cfg) - cfg.maxWeight)
    local topCm = math.max(cfg.trophyLength or 0, math.floor(cfg.maxLength * 1.1))
    local cm = cfg.maxLength + 1 + ZombRand(math.max(1, topCm - cfg.maxLength))
    local f = kg * 2.2 / oldLb
    item:setCalories(item:getCalories() * f)
    item:setLipids(item:getLipids() * f)
    item:setCarbohydrates(item:getCarbohydrates() * f)
    item:setProteins(item:getProteins() * f)
    item:setBaseHunger(item:getBaseHunger() * f)
    item:setHungChange(item:getBaseHunger())
    item:setActualWeight(kg * 2.2)
    item:setCustomWeight(true)
    item:setWorldScale(cm / 100.0)
    if item:getScriptItem():getTooltip() then
        item:setTooltip(item:getScriptItem():getTooltip())
    else
        item:setTooltip(nil)
    end
    local md = item:getModData()
    md.BassMasters_Trophy = true
    md.fishing_FishSize = cm
    md.fishing_FishHandItem = (cfg.itemType:match("%.(.+)$") or cfg.itemType) .. "_Hand_Big"
    -- The fish on the line grows too, so the trophy looks and fights its size underwater.
    fish.fishSize = cm / 20.0
    fish.fishSizeLen = cm
    item:setName("Trophy " .. BM.displayName(cfg.itemType) .. " - " .. cm .. "cm")
end

-- Other mods can make trophies likelier for an angler: each function here takes the character
-- and returns a multiplier (2 = twice as likely). Bass Boat uses this for anglers out on a boat.
-- Called wherever the fish is made, which is the server in multiplayer.
BM.trophyOddsModifiers = BM.trophyOddsModifiers or {}

local function trophyOdds(character)
    local odds = BM.sandbox("TrophyOdds", 100)
    if odds <= 0 then return 0 end
    local mult = 1
    for _, f in ipairs(BM.trophyOddsModifiers) do
        local ok, m = pcall(f, character)
        if ok and type(m) == "number" and m > 0 then mult = mult * m end
    end
    return math.max(1, math.floor(odds / mult + 0.5))
end

-- Every fish vanilla makes gets a small chance to be a trophy, whatever your Fishing level.
local vanillaCreateFish = Fishing.Fish.createFish
function Fishing.Fish:createFish(fishConfig)
    local item = vanillaCreateFish(self, fishConfig)
    if item and fishConfig and fishConfig.itemType ~= "Base.BaitFish" and fishConfig.maxWeight then
        if BM.isTrophy(item) then
            item:getModData().BassMasters_Trophy = true
        else
            local odds = trophyOdds(self.character)
            if odds > 0 and ZombRand(odds) == 0 then
                BM.makeTrophy(self, item, fishConfig)
            end
        end
    end
    return item
end
