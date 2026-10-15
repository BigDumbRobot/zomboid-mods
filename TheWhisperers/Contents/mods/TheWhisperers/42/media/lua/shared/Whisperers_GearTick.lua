-- The Whisperers: everything that happens to a player over time because of
-- corpse material. Runs where player state is authoritative: the server in
-- MP, the game itself in SP.
--
-- Discomfort and sickness are applied every tick through W.applyHolds so the
-- moodles stay steady against vanilla's own per-frame changes.
--
--   guts          lose half their weight/capacity every GutsHalfLifeHours;
--                 carrying a lot of them is uncomfortable and sickening
--   smeared guts  corpse sickness, scaled by how much of you is covered
--   masks, suits  dry out over time (brain tan stops it for a while), wear
--                 down while worn and can tear apart at any time;
--                 taking them on or off costs WearToggleDamage; a suit
--                 strips other clothing and can be destroyed by a big hit
require "Whisperers_Gear"
require "TimedActions/ISWearClothing"
require "TimedActions/ISUnequipAction"

local W = Whisperers
local G = W.Gear

local GUTS_ROT_AWAY = 0.05

local function eachPlayer(fn)
    if isServer() then
        local players = getOnlinePlayers()
        for i = 0, players:size() - 1 do fn(players:get(i)) end
    else
        for i = 0, getNumActivePlayers() - 1 do
            local p = getSpecificPlayer(i)
            if p then fn(p) end
        end
    end
end

-- Guts ---------------------------------------------------------------------

-- Refreshes every gut the player carries; drops rotted ones. Returns total kg.
local function tickGuts(player)
    local items = player:getInventory():getAllTypeRecurse(G.Types.Guts)
    local total, rotten = 0, {}
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        local cap = G.refreshGuts(it)
        if cap < GUTS_ROT_AWAY then
            rotten[#rotten + 1] = it
        else
            total = total + it:getActualWeight()
            if isServer() then syncItemFields(player, it) end
        end
    end
    for _, it in ipairs(rotten) do G.removeItem(player, it) end
    if #rotten > 0 then G.announce(player, "IGUI_Whisp_GutsRotted", false) end
    return total
end

-- Corpse sickness ------------------------------------------------------------

local function sicknessDefense(player)
    local ok, d = pcall(function() return player:getCorpseSicknessDefense() end)
    if not ok or not d then return 0 end
    if d > 1 then d = d / 100 end
    return W.clamp(d, 0, 1)
end

-- Per in-game minute.
local function tickSickness(player, carriedKg, changed)
    local stats = player:getStats()
    local md = player:getModData()

    -- Smeared guts wash off with the blood they left behind.
    local guts = math.min(md.WhispGutsPct or 0, G.smearedPct(player))
    md.WhispGutsPct = guts > 0.5 and guts or nil

    local perHour = W.Get("CorpseSicknessPerHour") * guts / 100
    local over = carriedKg - W.Get("GutsCarryThresholdKg")
    if over > 0 then
        perHour = perHour + W.Get("GutsCarrySicknessPerHour") * math.min(1, over / 10)
    end
    G.holdGutsDiscomfort(player, carriedKg)

    -- Applied every tick by W.applyHolds, as vanilla corpse sickness is.
    perHour = perHour * (1 - sicknessDefense(player))
    W.setHold(player, "sickRate", perHour > 0 and perHour or nil)
    W.setHold(player, "sickCap", W.Get("CorpseSicknessCap"))
    if perHour > 0 then changed[#changed + 1] = CharacterStat.FOOD_SICKNESS end

    -- Older versions raised SICKNESS, which nothing in vanilla ever lowers.
    local md = player:getModData()
    if not md.WhispSicknessReset then
        md.WhispSicknessReset = true
        if stats:get(CharacterStat.SICKNESS) > 0 then
            stats:set(CharacterStat.SICKNESS, 0)
            changed[#changed + 1] = CharacterStat.SICKNESS
        end
    end
end

-- Worn gear ------------------------------------------------------------------

local function tickGear(player)
    -- Every mask and suit carried dries out, worn or not.
    local carried = player:getInventory():getAllEvalRecurse(function(it) return G.isGear(it) end)
    for i = 0, carried:size() - 1 do
        local it = carried:get(i)
        if G.dryGear(player, it) then G.onBroken(player, it, true) end
    end

    local worn = player:getWornItems()
    local wearing = {}
    for i = 0, worn:size() - 1 do
        local it = worn:get(i):getItem()
        if G.isGear(it) then wearing[#wearing + 1] = it end
    end
    for _, it in ipairs(wearing) do
        -- Catch gear put on some other way (spawned worn, loaded worn).
        if not it:getModData().WhispWorn then it:getModData().WhispWorn = true end
        if G.isWorking(it) then
            local broke = G.damageGear(player, it, W.Get("WearDamagePerHour") / 60)
            -- Dead skin can tear at any time; the more worn, the likelier.
            if not broke then
                local wornness = 1 - it:getCondition() / it:getConditionMax()
                local chance = W.Get("BreakChancePerHour") / 100 / 60 * (0.25 + wornness * 3)
                if ZombRandFloat(0, 1) < chance then
                    broke = G.damageGear(player, it, 100)
                end
            end
            if broke then G.onBroken(player, it) end
        end
    end
end

local function everyMinute()
    if not G.authoritative() or not W.Get("Enabled") then return end
    eachPlayer(function(player)
        if player:isDead() then return end
        G.stampPlayerName(player)
        G.removeStumps(player)
        local changed = {}
        local kg = tickGuts(player)
        pcall(tickSickness, player, kg, changed)
        tickGear(player)
        W.syncStats(player, changed)
    end)
end

-- Every tick: keep discomfort and corpse sickness steady (see W.applyHolds).
local function everyTick()
    if not W.Get("Enabled") then return end
    local authoritative = G.authoritative()
    eachPlayer(function(player)
        local changed = W.applyHolds(player, authoritative)
        if authoritative and changed then W.syncStats(player, changed) end
    end)
end

Events.EveryOneMinute.Add(everyMinute)
Events.OnTick.Add(everyTick)

-- Wearing and removing -------------------------------------------------------

local origWearIsValid = ISWearClothing.isValid
function ISWearClothing:isValid()
    if not origWearIsValid(self) then return false end
    if G.isVisualOnly(self.item) then return false end
    -- Nothing goes on over a skin suit except head gear, shoes, socks and bags.
    if self.item and G.wornSuit(self.character) and not G.allowedWithSuit(self.item) then
        return false
    end
    return true
end

local origWearComplete = ISWearClothing.complete
function ISWearClothing:complete()
    local result = origWearComplete(self)
    if result ~= false and self.item and G.isGear(self.item) then
        G.onWearToggle(self.character, self.item, true)
        if self.item:getFullType() == G.Types.Suit then G.stripForSuit(self.character) end
    end
    return result
end

local origUnequipComplete = ISUnequipAction.complete
function ISUnequipAction:complete()
    local result = origUnequipComplete(self)
    if result ~= false and self.item and G.isGear(self.item) then
        G.onWearToggle(self.character, self.item, false)
    end
    return result
end

-- A hard enough hit tears the suit apart; lesser hits wear it down.
local HIT_TYPES = { WEAPONHIT = true, CARHITDAMAGE = true, CARCRASHDAMAGE = true }

local function onPlayerGetDamage(character, damageType, damage)
    if not G.authoritative() or not instanceof(character, "IsoPlayer") then return end
    if not HIT_TYPES[tostring(damageType)] or not damage or damage <= 0 then return end
    local suit = G.wornSuit(character)
    if not suit or not G.isWorking(suit) then return end
    local broke
    if damage >= W.Get("SuitHitDestroyDamage") then
        broke = G.damageGear(character, suit, 100)
    else
        broke = G.damageGear(character, suit, damage * W.Get("SuitHitConditionLoss"))
    end
    if broke then G.onBroken(character, suit) end
end

Events.OnPlayerGetDamage.Add(onPlayerGetDamage)
