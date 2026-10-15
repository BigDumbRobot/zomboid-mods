-- KIPN_LORDGame.lua
--
-- Server-authoritative game logic for KIPN: Legend of the Red Dragon.
--
-- A full LORD loop, tuned for casual multiplayer play:
--   * Town Square hub  -> Forest, Weapons, Armour, Healer, Bank, Inn,
--     Turgon's Warrior Training, and (at level 12) the Red Dragon.
--   * Forest: turn-limited random encounters -- monsters, gold, gems,
--     springs, the fairy, the old man of the woods, a thief, and
--     (rarely) Death itself.
--   * Warrior Training: each level has a named master you must defeat
--     before Turgon will advance you.
--   * Weapons / Armour: the 12 classic tiers, bought one step at a
--     time with a trade-in on your old gear.
--   * Rest Until Dawn: refill forest turns + full heal, on demand
--     (optionally rate-limited by a sandbox cooldown).
--   * Slay the Dragon -> Hall of Honours, a permanent bonus, and a
--     fresh character that keeps its bank, gems and dragon-kill tally.
--
-- Registration (data domain, command handlers, menu entry) lives in
-- KIPN_LORDInit.lua. This file only defines KIPN.LORD.Server.*.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_LORDShared"

KIPN.LORD = KIPN.LORD or {}
KIPN.LORD.Server = KIPN.LORD.Server or {}

local Server    = KIPN.LORD.Server
local Actions   = KIPN.LORD.Actions
local WEAPONS   = KIPN.LORD.WEAPONS
local ARMOUR    = KIPN.LORD.ARMOUR
local EXP_NEEDED    = KIPN.LORD.EXP_NEEDED
local MAX_HP_BY_LEVEL = KIPN.LORD.MAX_HP_BY_LEVEL
local MASTER_NAMES = KIPN.LORD.MASTER_NAMES
local MAX_LEVEL  = KIPN.LORD.MAX_LEVEL

local DATA_DOMAIN = "lordDragon"
local LOG_LINES   = 16

local function log(m) print("[KIPN LORD] " .. tostring(m)) end

--------------------------------------------------------------------
-- DATA DOMAIN  (registered at module load -- see sec 2.2)
--------------------------------------------------------------------

if type(KIPN.Server.RegisterDataDomain) == "function" then
    KIPN.Server.RegisterDataDomain(DATA_DOMAIN, { chars = {}, hall = {} })
else
    log("ERROR: KIPN.Server.RegisterDataDomain unavailable; LORD cannot persist.")
end

local function store()
    local data = KIPN.Server.GetData()
    if type(data) ~= "table" then return nil end
    data[DATA_DOMAIN] = data[DATA_DOMAIN] or { chars = {}, hall = {} }
    data[DATA_DOMAIN].chars = data[DATA_DOMAIN].chars or {}
    data[DATA_DOMAIN].hall  = data[DATA_DOMAIN].hall  or {}
    return data[DATA_DOMAIN]
end

local function persist()
    if type(KIPN.Server.Save) == "function" then
        pcall(KIPN.Server.Save, DATA_DOMAIN)
    end
end

--------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------

local function rnd(a, b)
    a, b = math.floor(a), math.floor(b)
    if b < a then a, b = b, a end
    if type(ZombRand) == "function" then return ZombRand(a, b + 1) end
    return math.random(a, b)
end

local function chance(pct) return rnd(1, 100) <= pct end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, v = pcall(getTimestampMs)
        if ok and type(v) == "number" then return v end
    end
    return 0
end

local function currentDay()
    local ok, gt = pcall(getGameTime)
    if ok and gt and type(gt.getWorldAgeHours) == "function" then
        local h = gt:getWorldAgeHours()
        if type(h) == "number" then return math.floor(h / 24) end
    end
    return 0
end

local function commas(n)
    n = math.floor(tonumber(n) or 0)
    local s, neg = tostring(math.abs(n)), n < 0
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (neg and "-" or "") .. out
end

local function cfg()
    local sv = (SandboxVars and SandboxVars.KIPN) or {}
    local perDay = tonumber(sv.LORDForestFightsPerDay); if not perDay or perDay < 1 then perDay = 20 end
    local xpMul = tonumber(sv.LORDExpMultiplier);  if not xpMul or xpMul <= 0 then xpMul = 1.5 end
    local goldMul = tonumber(sv.LORDGoldMultiplier); if not goldMul or goldMul <= 0 then goldMul = 2 end
    local restCd = tonumber(sv.LORDRestCooldownMinutes); if not restCd or restCd < 0 then restCd = 0 end
    local deathPct = tonumber(sv.LORDDeathGoldPenalty); if not deathPct or deathPct < 0 then deathPct = 25 end
    return {
        enabled = sv.LORDEnabled ~= false,
        forestFightsPerDay = perDay,
        xpMul = xpMul,
        goldMul = goldMul,
        restCooldownMs = restCd * 60 * 1000,
        deathGoldPenalty = math.min(100, deathPct) / 100,
        pvpEnabled = sv.LORDPvPEnabled == true,   -- reserved for a future release
    }
end

local function identity(player)
    local steamId = KIPN.Shared.GetPlayerId(player)
    if not steamId then return nil end
    return steamId, KIPN.Shared.GetPlayerName(player) or "Adventurer"
end

--------------------------------------------------------------------
-- MONSTERS
--------------------------------------------------------------------

local MONSTERS = {
    -- band 1 (levels 1-3)
    "a Scavenging Rat", "a Wild Dog", "a Feral Hog", "a Bandit Scout", "a Giant Wasp",
    -- band 2 (levels 4-6)
    "a Rabid Wolf", "a Skeleton Archer", "a Bog Zombie", "a Masked Highwayman", "a Cave Bat Swarm",
    -- band 3 (levels 7-9)
    "a Dire Bear", "a Cursed Knight", "a Venom Drake Hatchling", "a Marauder Captain", "a Stone Golem",
    -- band 4 (levels 10-12)
    "a Grave Wraith", "a Chimera", "a Lesser Demon", "a Dragon Cultist", "a Basilisk",
}

local function pickMonster(level)
    local band = math.min(4, math.max(1, math.ceil(level / 3)))
    return MONSTERS[(band - 1) * 5 + rnd(1, 5)]
end

--------------------------------------------------------------------
-- CHARACTER
--------------------------------------------------------------------

local function newChar(name)
    return {
        name         = name or "Adventurer",
        level        = 1,
        exp          = 0,
        hp           = MAX_HP_BY_LEVEL[1],
        maxHp        = MAX_HP_BY_LEVEL[1],
        gold         = 0,
        bank         = 0,
        weaponIndex  = 0,     -- 0 = bare fists
        armourIndex  = 0,     -- 0 = no armour
        gems         = 0,
        charm        = 0,
        bonusAtk     = 0,
        bonusDef     = 0,
        bonusHp      = 0,
        forestFights = cfg().forestFightsPerDay,
        masterDefeated = false,
        alive        = true,
        dead         = false,
        playerKills  = 0,
        dragonKills  = 0,
        lastDay      = currentDay(),
        lastRestMs   = 0,
        fight        = nil,
        oldMan       = false,   -- old man of the woods is offering a trade
        log          = { "You step off the road at the edge of a dark forest, a stick in your hand." },
    }
end

local function pushLog(char, line)
    char.log = char.log or {}
    char.log[#char.log + 1] = line
    while #char.log > LOG_LINES do table.remove(char.log, 1) end
end

local function applyDailyRollover(char)
    local today = currentDay()
    if (char.lastDay or 0) >= today then return end
    char.lastDay = today
    char.forestFights = cfg().forestFightsPerDay
    char.dead = false
    char.alive = true
    char.hp = char.maxHp
    char.fight = nil
    char.oldMan = false
    pushLog(char, "-- A new day dawns. Forest turns restored, wounds rested. --")
end

local function ensureChar(steamId, name, legacyIds)
    local s = store()
    if not s then return nil end
    local char = s.chars[steamId]
    if not char then
        -- A character saved under this player's old Steam-based key
        -- (before identities became server accounts) moves to the new one.
        for _, legacyId in ipairs(legacyIds or {}) do
            if s.chars[legacyId] then
                char = s.chars[legacyId]
                s.chars[legacyId] = nil
                s.chars[steamId] = char
                persist()
                break
            end
        end
    end
    if not char then
        char = newChar(name)
        s.chars[steamId] = char
        persist()
    else
        if name and name ~= "" then char.name = name end
        -- migrate older saves
        char.weaponIndex = char.weaponIndex or 0
        char.armourIndex = char.armourIndex or 0
        char.gems = char.gems or 0
        char.charm = char.charm or 0
        char.bonusAtk = char.bonusAtk or 0
        char.bonusDef = char.bonusDef or 0
        char.bonusHp = char.bonusHp or 0
        char.lastRestMs = char.lastRestMs or 0
        if char.masterDefeated == nil then char.masterDefeated = false end
        applyDailyRollover(char)
    end
    return char
end

--------------------------------------------------------------------
-- DERIVED STATS
--------------------------------------------------------------------

local function weaponPower(idx)  local w = WEAPONS[idx]; return w and w.power or 0 end
local function armourDef(idx)    local a = ARMOUR[idx];  return a and a.def or 0 end

local function pAttack(c)  return weaponPower(c.weaponIndex) + c.level * 3 + (c.bonusAtk or 0) + 2 end
local function pDefence(c) return armourDef(c.armourIndex) + c.level * 2 + (c.bonusDef or 0) end
local function pMaxHp(c)   return (MAX_HP_BY_LEVEL[c.level] or MAX_HP_BY_LEVEL[MAX_LEVEL]) + (c.bonusHp or 0) end

local function weaponName(idx)  local w = WEAPONS[idx]; return w and w.name or "bare fists" end
local function armourName(idx)   local a = ARMOUR[idx];  return a and a.name or "no armour" end

--------------------------------------------------------------------
-- COMBAT
--------------------------------------------------------------------

-- Combat is resolved as a fraction of each side's own max HP, scaled
-- by a gear ratio. This keeps every fight ~4-12 rounds at ANY level
-- (so the display numbers can grow huge without the maths drifting),
-- while weapon tier, armour tier and the old-man boons still swing
-- the outcome -- and being under-geared for a master or the Dragon
-- still gets you killed.

local WEAPON_TIERS = #WEAPONS
local ARMOUR_TIERS = #ARMOUR

local function gearOffence(char)
    local wt = (char.weaponIndex or 0) / WEAPON_TIERS               -- 0 .. 1
    return 0.55 + wt * 1.05 + math.min(0.5, (char.bonusAtk or 0) / 150)
end

local function gearWard(char)
    local at = (char.armourIndex or 0) / ARMOUR_TIERS               -- 0 .. 1
    return 0.60 + at * 1.05 + math.min(0.5, (char.bonusDef or 0) / 150)
end

-- one exchange: player hits foe, then (if alive) foe hits player.
local function combatRound(char)
    local foe = char.fight
    if not foe then return end

    -- PLAYER -> FOE
    local pct = rnd(90, 150) / 1000
    local crit = false
    if (char.charm or 0) > 0 and chance(math.min(22, char.charm * 2)) then
        pct = pct * 1.5; crit = true
    end
    local hit = math.max(1, math.floor(foe.maxHp * pct * gearOffence(char) / (foe.toughness or 1)))
    foe.hp = foe.hp - hit
    pushLog(char, string.format("You hit %s for %s%s.  (%s HP left)",
        foe.name, commas(hit), crit and " -- a critical strike!" or "",
        commas(math.max(0, foe.hp))))

    if foe.hp <= 0 then return "win" end

    -- FOE -> PLAYER
    local fhit = math.max(1, math.floor(char.maxHp * ((foe.dmgPct or 5) / 100) / gearWard(char)))
    char.hp = char.hp - fhit
    pushLog(char, string.format("%s hits you for %s.  (%s HP left)",
        foe.name, commas(fhit), commas(math.max(0, char.hp))))

    if char.hp <= 0 then return "dead" end
    return "ongoing"
end

local function resolveWin(char)
    local foe = char.fight
    char.fight = nil

    if foe.isMaster then
        char.masterDefeated = true
        char.hp = char.maxHp
        pushLog(char, string.format("You have defeated %s! Turgon nods. \"Return when you are ready to advance.\"", foe.name))
        return
    end

    if foe.isDragon then
        return "dragon"
    end

    local gold = foe.gold or 0
    local exp  = foe.exp or 0
    char.gold = char.gold + gold
    char.exp  = char.exp + exp
    local extra = ""
    if (foe.gems or 0) > 0 then char.gems = char.gems + foe.gems; extra = string.format(", %d gem(s)", foe.gems) end
    pushLog(char, string.format("You slay %s!  +%s gold, +%s experience%s.", foe.name, commas(gold), commas(exp), extra))

    if foe.isDeath then
        pushLog(char, "Death recedes into the mist. Few can say they have beaten it.")
    end
    if char.level < MAX_LEVEL and char.exp >= (EXP_NEEDED[char.level] or math.huge) and not char.masterDefeated then
        pushLog(char, "You feel ready to test yourself against Turgon's master.")
    end
end

local function resolveDeath(char, killer)
    local lost = math.floor(char.gold * cfg().deathGoldPenalty)
    char.gold = char.gold - lost
    char.fight = nil
    char.oldMan = false
    char.dead = true
    char.alive = false
    char.hp = 0
    pushLog(char, string.format("%s has slain you! You drop %s gold where you fall.", killer, commas(lost)))
    pushLog(char, "Your banked gold, gems and gear are safe. Choose 'Rest Until Dawn' to recover.")
end

-- shared post-round bookkeeping; returns nothing, mutates char
local function afterRound(char, outcome)
    if outcome == "win" then
        local res = resolveWin(char)
        if res == "dragon" then return "dragon" end
    elseif outcome == "dead" then
        local foe = char._lastFoeName or "Your foe"
        resolveDeath(char, foe)
    end
end

--------------------------------------------------------------------
-- FOREST
--------------------------------------------------------------------

local function startMonsterFight(char, opts)
    opts = opts or {}
    local lvl = char.level
    local ref = pMaxHp(char)
    -- HP shown is cosmetic; toughness/dmgPct decide the fight (see combatRound).
    local hp = opts.hp or rnd(math.floor(ref * 0.10), math.floor(ref * 0.22))
    local expBand  = (EXP_NEEDED[math.min(lvl, 11)] or 1000) / rnd(14, 22)
    local goldBand = (WEAPONS[math.min(lvl, #WEAPONS)].cost) / rnd(20, 32)
    local foe = {
        name      = opts.name or pickMonster(lvl),
        hp        = hp,
        maxHp     = hp,
        toughness = opts.toughness or (rnd(38, 55) / 100),   -- < 1 => dies fast
        dmgPct    = opts.dmgPct or rnd(2, 4),                 -- % of your max HP / round
        gold      = opts.gold or math.floor(math.max(lvl * 15, goldBand) * cfg().goldMul),
        exp       = opts.exp or math.floor(math.max(lvl * 12, expBand) * cfg().xpMul),
        gems      = opts.gems or 0,
        kind      = opts.kind or "forest",
        isDeath   = opts.isDeath,
    }
    char.fight = foe
    char._lastFoeName = foe.name
    pushLog(char, string.format("You come upon %s!  (%s HP)", foe.name, commas(foe.hp)))
end

local function actForest(char)
    if char.dead then pushLog(char, "You are in no state to walk the forest."); return end
    if char.fight then pushLog(char, "You are already fighting " .. char.fight.name .. "!"); return end
    if char.oldMan then pushLog(char, "The old man of the woods is still waiting on your answer."); return end
    if (char.forestFights or 0) <= 0 then pushLog(char, "You are too weary to face the forest again today."); return end

    char.forestFights = char.forestFights - 1
    local luck = math.min(12, math.floor((char.charm or 0) / 2))
    local roll = rnd(1, 100)

    if roll <= 58 - luck then
        startMonsterFight(char)

    elseif roll <= 72 then
        local found = rnd(char.level * 8, char.level * 22) * cfg().goldMul
        char.gold = char.gold + found
        pushLog(char, "You find a purse on the trail -- " .. commas(found) .. " gold.")

    elseif roll <= 80 then
        local g = rnd(1, 2)
        char.gems = char.gems + g
        pushLog(char, string.format("Something glitters in the leaf litter: %d gem%s.", g, g == 1 and "" or "s"))

    elseif roll <= 86 then
        char.hp = char.maxHp
        pushLog(char, "You drink from a clear forest spring and are fully restored.")

    elseif roll <= 92 then
        local gift = rnd(char.level * 30, char.level * 70) * cfg().xpMul
        char.exp = char.exp + gift
        pushLog(char, "An old hermit shares hard-won wisdom.  +" .. commas(gift) .. " experience.")

    elseif roll <= 95 then
        if (char.gems or 0) >= 2 then
            char.oldMan = true
            pushLog(char, "The old man of the woods appears. \"Two gems,\" he rasps, \"and I will make you stronger. Strength, vitality, or defence?\"")
        else
            pushLog(char, "The old man of the woods watches you pass. \"Bring me two gems and I will make you stronger.\"")
        end

    elseif roll <= 97 then
        char.hp = char.maxHp
        local gift = rnd(char.level * 15, char.level * 40) * cfg().xpMul
        char.exp = char.exp + gift
        pushLog(char, "Jennie the fairy grants you a wish -- full health and +" .. commas(gift) .. " experience.")

    elseif roll <= 99 then
        local stolen = math.min(char.gold, rnd(char.level * 10, char.level * 30) * cfg().goldMul)
        char.gold = char.gold - stolen
        pushLog(char, "A cutpurse bumps you in the dark and is gone. You are " .. commas(stolen) .. " gold poorer.")

    elseif char.level >= 6 then
        -- Death itself -- rare, frightening, but beatable if you are geared
        startMonsterFight(char, {
            name = "Death itself",
            hp = math.floor(pMaxHp(char) * rnd(70, 95) / 100),
            toughness = 1.0,
            dmgPct = rnd(6, 9),
            gold = rnd(char.level * 200, char.level * 500) * cfg().goldMul,
            exp = math.floor((EXP_NEEDED[char.level] or 1000) * 0.5 * cfg().xpMul),
            gems = rnd(3, 6),
            isDeath = true,
        })
        pushLog(char, "A cold wind rises. Death itself blocks the path, scythe in hand.")
    else
        local found = rnd(char.level * 10, char.level * 25) * cfg().goldMul
        char.gold = char.gold + found
        pushLog(char, "You find an abandoned camp and pick it clean -- " .. commas(found) .. " gold.")
    end
end

--------------------------------------------------------------------
-- OLD MAN OF THE WOODS
--------------------------------------------------------------------

local function spendGems(char, kind)
    if not char.oldMan then pushLog(char, "There is no one here to trade with."); return end
    if (char.gems or 0) < 2 then char.oldMan = false; pushLog(char, "You no longer have two gems. The old man vanishes."); return end
    char.gems = char.gems - 2
    char.oldMan = false
    if kind == "strength" then
        local g = rnd(3, 6) + math.floor(char.level / 2)
        char.bonusAtk = (char.bonusAtk or 0) + g
        pushLog(char, "The old man kneads your arms. Your strength grows (+" .. g .. " attack, permanent).")
    elseif kind == "vitality" then
        local g = rnd(math.floor(char.maxHp * 0.05), math.floor(char.maxHp * 0.12)) + 5
        char.bonusHp = (char.bonusHp or 0) + g
        char.maxHp = pMaxHp(char)
        char.hp = char.maxHp
        pushLog(char, "The old man presses a thumb to your brow. Your vitality grows (+" .. commas(g) .. " max HP, permanent).")
    else
        local g = rnd(3, 6) + math.floor(char.level / 2)
        char.bonusDef = (char.bonusDef or 0) + g
        pushLog(char, "The old man traces a rune on your back. Your guard hardens (+" .. g .. " defence, permanent).")
    end
end

--------------------------------------------------------------------
-- SHOPS
--------------------------------------------------------------------

local function tradeCost(list, currentIdx, nextIdx)
    local price = list[nextIdx].cost
    if currentIdx >= 1 and list[currentIdx] then
        price = price - math.floor(list[currentIdx].cost / 2)   -- trade-in
    end
    return math.max(0, price)
end

local function buyWeapon(char)
    if char.fight then pushLog(char, "Not here, not now."); return end
    local nextIdx = (char.weaponIndex or 0) + 1
    if nextIdx > #WEAPONS then pushLog(char, "King Arthur bows. \"You already carry the finest blade I sell.\""); return end
    local cost = tradeCost(WEAPONS, char.weaponIndex, nextIdx)
    if char.gold < cost then
        pushLog(char, string.format("The %s costs %s gold (after trade-in). You are short.", WEAPONS[nextIdx].name, commas(cost)))
        return
    end
    char.gold = char.gold - cost
    char.weaponIndex = nextIdx
    pushLog(char, string.format("You buy the %s for %s gold.", WEAPONS[nextIdx].name, commas(cost)))
end

local function buyArmour(char)
    if char.fight then pushLog(char, "Not here, not now."); return end
    local nextIdx = (char.armourIndex or 0) + 1
    if nextIdx > #ARMOUR then pushLog(char, "Abdul spreads his hands. \"There is nothing better than what you wear.\""); return end
    local cost = tradeCost(ARMOUR, char.armourIndex, nextIdx)
    if char.gold < cost then
        pushLog(char, string.format("The %s costs %s gold (after trade-in). You cannot afford it.", ARMOUR[nextIdx].name, commas(cost)))
        return
    end
    char.gold = char.gold - cost
    char.armourIndex = nextIdx
    pushLog(char, string.format("You buy the %s for %s gold.", ARMOUR[nextIdx].name, commas(cost)))
end

--------------------------------------------------------------------
-- HEALER
--------------------------------------------------------------------

local function healCostPerHp(char) return math.max(1, char.level * 2) end

local function heal(char, fraction)
    if char.dead then pushLog(char, "The healer cannot help you until you have rested."); return end
    if char.fight then pushLog(char, "You cannot stop to bandage up mid-fight."); return end
    local missing = char.maxHp - char.hp
    if missing <= 0 then pushLog(char, "You are already in perfect health."); return end
    local want = fraction and math.ceil(missing * fraction) or missing
    local per = healCostPerHp(char)
    local canAfford = math.floor(char.gold / per)
    local healed = math.min(want, canAfford)
    if healed <= 0 then
        pushLog(char, string.format("The healer wants %s gold per point. You cannot pay.", commas(per)))
        return
    end
    char.hp = char.hp + healed
    char.gold = char.gold - healed * per
    pushLog(char, string.format("The healer closes %s wounds for %s gold.", commas(healed), commas(healed * per)))
end

--------------------------------------------------------------------
-- BANK
--------------------------------------------------------------------

local function bankDeposit(char)
    if char.gold <= 0 then pushLog(char, "You have no gold on hand to deposit."); return end
    char.bank = char.bank + char.gold
    pushLog(char, string.format("You deposit %s gold. The vault now holds %s.", commas(char.gold), commas(char.bank)))
    char.gold = 0
end

local function bankWithdraw(char)
    if char.bank <= 0 then pushLog(char, "Your account is empty."); return end
    char.gold = char.gold + char.bank
    pushLog(char, string.format("You withdraw %s gold. You now carry %s.", commas(char.bank), commas(char.gold)))
    char.bank = 0
end

local function bankGamble(char)
    if char.fight then return end
    local stake = math.floor(char.gold * 0.25)
    if stake < 10 then pushLog(char, "The dealer waves you off -- come back with more gold on hand."); return end
    char.gold = char.gold - stake
    if chance(46) then
        char.gold = char.gold + stake * 2
        pushLog(char, string.format("The dice come up your way! You win %s gold.", commas(stake)))
    else
        pushLog(char, string.format("The dice betray you. You lose %s gold.", commas(stake)))
    end
end

--------------------------------------------------------------------
-- INN
--------------------------------------------------------------------

local function flirt(char)
    if char.fight then return end
    if (char.charm or 0) >= 20 then
        pushLog(char, "Violet laughs. \"You are trouble enough already.\"")
        return
    end
    if chance(55 + math.floor((char.charm or 0) / 2)) then
        char.charm = (char.charm or 0) + 1
        pushLog(char, "You share a drink with Violet and part on good terms.  Charm is now " .. char.charm .. ".")
    else
        pushLog(char, "Violet rolls her eyes and turns to another patron.")
    end
end

local function rest(char)
    local cd = cfg().restCooldownMs
    if cd > 0 and char.lastRestMs and (nowMs() - char.lastRestMs) < cd then
        local left = math.ceil((cd - (nowMs() - char.lastRestMs)) / 60000)
        pushLog(char, string.format("You cannot rest again yet (%d min).", left))
        return
    end
    char.lastRestMs = nowMs()
    char.lastDay = currentDay()
    char.forestFights = cfg().forestFightsPerDay
    char.hp = char.maxHp
    char.dead = false
    char.alive = true
    char.fight = nil
    char.oldMan = false
    pushLog(char, string.format("-- You sleep until dawn. %d forest turns, full health. --", char.forestFights))
end

--------------------------------------------------------------------
-- TURGON'S WARRIOR TRAINING
--------------------------------------------------------------------

local function masterFor(char)
    local lvl = char.level
    local ref = pMaxHp(char)
    -- A heal-up-and-commit check. Roughly an 8-round fight that costs a
    -- fully-healed, level-appropriately-geared player about half their
    -- HP -- and kills someone who shows up wounded or under-armoured.
    local hp = math.floor(ref * 0.52)
    return {
        name      = MASTER_NAMES[lvl] or ("Master of Level " .. lvl),
        hp        = hp,
        maxHp     = hp,
        toughness = 1.0,
        dmgPct    = math.min(7, 3 + math.floor(lvl / 2)),   -- gentler on low-level masters
        kind      = "master",
        isMaster  = true,
    }
end

local function challengeMaster(char)
    if char.fight then pushLog(char, "Finish what you are doing first."); return end
    if char.dead then pushLog(char, "Turgon will not train a corpse. Rest first."); return end
    if char.level >= MAX_LEVEL then
        pushLog(char, "Turgon grips your shoulder. \"There is nothing left for me to teach. The Dragon awaits.\"")
        return
    end
    local need = EXP_NEEDED[char.level] or math.huge
    if char.exp < need then
        pushLog(char, string.format("Turgon shakes his head. \"Not yet. Bring me %s more experience.\"", commas(need - char.exp)))
        return
    end
    if char.masterDefeated then
        pushLog(char, "You have already bested this level's master. Choose 'Advance' when you are ready.")
        return
    end
    if char.hp < char.maxHp then
        pushLog(char, "\"Face my master at full strength or not at all,\" says Turgon. (Heal first.)")
        return
    end
    local m = masterFor(char)
    char.fight = m
    char._lastFoeName = m.name
    pushLog(char, string.format("Turgon gestures. %s steps onto the sand to test you.  (%s HP)", m.name, commas(m.hp)))
end

local function advanceLevel(char)
    if char.fight then return end
    if char.level >= MAX_LEVEL then pushLog(char, "You are already at the peak of mortal skill."); return end
    local need = EXP_NEEDED[char.level] or math.huge
    if char.exp < need then
        pushLog(char, string.format("You need %s more experience before Turgon will advance you.", commas(need - char.exp)))
        return
    end
    if not char.masterDefeated then
        pushLog(char, "You must defeat this level's master before Turgon will advance you.")
        return
    end
    char.level = char.level + 1
    char.masterDefeated = false
    char.maxHp = pMaxHp(char)
    char.hp = char.maxHp
    pushLog(char, string.format("*** Turgon raises you to level %d! *** Max HP is now %s. You are fully healed.",
        char.level, commas(char.maxHp)))
    if char.level >= MAX_LEVEL then
        pushLog(char, "\"You are ready,\" says Turgon quietly. \"Go and face the Red Dragon.\"")
    end
end

--------------------------------------------------------------------
-- THE RED DRAGON
--------------------------------------------------------------------

local function challengeDragon(char)
    if char.level < MAX_LEVEL then
        pushLog(char, string.format("The path to the Dragon's lair is barred until you reach level %d.", MAX_LEVEL))
        return
    end
    if char.dead then pushLog(char, "Not in your condition."); return end
    if char.fight then pushLog(char, "Deal with " .. char.fight.name .. " first."); return end
    if char.hp < char.maxHp then
        pushLog(char, "You would not survive the lair wounded. Heal to full first.")
        return
    end
    if (char.weaponIndex or 0) < 8 or (char.armourIndex or 0) < 8 then
        pushLog(char, "You are not equipped for this. The Dragon has killed better-armed warriors than you.")
        return
    end
    local kills = char.dragonKills or 0
    local hp = math.floor(pMaxHp(char) * (1.0 + kills * 0.15))
    local d = {
        name      = "the Red Dragon",
        hp        = hp,
        maxHp     = hp,
        toughness = 1.45 + kills * 0.10,   -- a long fight: ~10-13 rounds
        dmgPct    = 7 + kills,             -- ~55-70% of a full-HP, gate-geared L12
        kind      = "dragon",
        isDragon  = true,
    }
    char.fight = d
    char._lastFoeName = d.name
    pushLog(char, "You descend into the Red Dragon's lair. The heat is a wall. It turns its head toward you.")
    pushLog(char, string.format("THE RED DRAGON  --  %s HP", commas(d.hp)))
end

local function onDragonSlain(char)
    local s = store()
    char.dragonKills = (char.dragonKills or 0) + 1
    local reward = rnd(6, 12)
    char.gems = (char.gems or 0) + reward
    pushLog(char, "THE RED DRAGON FALLS. Its roar collapses into silence, and the forest is quiet for the first time in years.")
    pushLog(char, string.format("You take %d gems from the hoard. Dragon kills: %d.", reward, char.dragonKills))

    if s then
        s.hall[#s.hall + 1] = {
            name = char.name, dragonKills = char.dragonKills,
            weapon = weaponName(char.weaponIndex), day = currentDay(),
        }
        table.sort(s.hall, function(a, b) return (a.dragonKills or 0) > (b.dragonKills or 0) end)
        while #s.hall > 12 do table.remove(s.hall) end
    end

    -- fresh character; keep bank, gems, name, tallies, and a growing permanent bonus
    local fresh = newChar(char.name)
    fresh.bank        = char.bank
    fresh.gems        = char.gems
    fresh.dragonKills = char.dragonKills
    fresh.playerKills = char.playerKills
    fresh.charm       = char.charm
    fresh.bonusAtk    = (char.bonusAtk or 0) + char.dragonKills * 3
    fresh.bonusDef    = (char.bonusDef or 0) + char.dragonKills * 3
    fresh.bonusHp     = (char.bonusHp or 0) + char.dragonKills * 20
    fresh.maxHp       = MAX_HP_BY_LEVEL[1] + fresh.bonusHp
    fresh.hp          = fresh.maxHp
    fresh.log         = char.log
    pushLog(fresh, "A new legend begins. Turgon greets you at the gate as if he has never seen you before.")
    if s then s.chars[char._steamId] = fresh end
    return fresh
end

--------------------------------------------------------------------
-- SNAPSHOT
--------------------------------------------------------------------

local function place(char)
    if char.dead then return "dead" end
    if char.fight then return "fight" end
    return "town"
end

local function nextGear(list, idx)
    local n = (idx or 0) + 1
    if n > #list then return nil end
    -- cost the player actually pays: sticker price minus a trade-in on
    -- their current gear (matches tradeCost() used by the buy handlers)
    return { name = list[n].name, cost = tradeCost(list, idx or 0, n), sticker = list[n].cost }
end

local function snapshot(char, s)
    local need = EXP_NEEDED[char.level]
    local m = (char.level < MAX_LEVEL) and masterFor(char) or nil
    return {
        char = {
            name = char.name, level = char.level, exp = char.exp,
            expForNext = (need and need > 0) and need or -1,
            hp = math.max(0, char.hp), maxHp = char.maxHp,
            gold = char.gold, bank = char.bank, gems = char.gems or 0,
            charm = char.charm or 0,
            weapon = weaponName(char.weaponIndex), weaponIndex = char.weaponIndex or 0,
            armour = armourName(char.armourIndex), armourIndex = char.armourIndex or 0,
            attack = pAttack(char), defence = pDefence(char),
            forestFights = char.forestFights,
            masterDefeated = char.masterDefeated and true or false,
            dragonKills = char.dragonKills or 0,
            playerKills = char.playerKills or 0,
            bonusAtk = char.bonusAtk or 0, bonusDef = char.bonusDef or 0, bonusHp = char.bonusHp or 0,
            alive = char.alive, dead = char.dead,
            canChallengeMaster = (char.level < MAX_LEVEL) and (char.exp >= (need or math.huge))
                                 and not char.masterDefeated and not char.dead,
            canAdvance = (char.level < MAX_LEVEL) and (char.exp >= (need or math.huge)) and char.masterDefeated,
            canFightDragon = (char.level >= MAX_LEVEL) and not char.dead and not char.fight
                             and char.hp >= char.maxHp
                             and (char.weaponIndex or 0) >= 8 and (char.armourIndex or 0) >= 8,
        },
        fight = char.fight and {
            name = char.fight.name, hp = math.max(0, char.fight.hp), maxHp = char.fight.maxHp,
            kind = char.fight.kind, canFlee = (char.fight.kind == "forest"),
        } or nil,
        oldMan = char.oldMan and true or false,
        master = m and { name = m.name, hp = m.maxHp } or nil,
        nextWeapon = nextGear(WEAPONS, char.weaponIndex),
        nextArmour = nextGear(ARMOUR, char.armourIndex),
        healPerHp = healCostPerHp(char),
        log = char.log or {},
        hallOfHonours = (s and s.hall) or {},
        place = place(char),
        config = { forestFightsPerDay = cfg().forestFightsPerDay },
    }
end

--------------------------------------------------------------------
-- ACTION DISPATCH
--------------------------------------------------------------------

local function doAttack(char)
    if not char.fight then pushLog(char, "There is nothing here to fight."); return end
    local outcome = combatRound(char)
    return afterRound(char, outcome)
end

local function doAutoBattle(char)
    if not char.fight then pushLog(char, "There is nothing here to fight."); return end
    local guard = 0
    while char.fight and guard < 400 do
        guard = guard + 1
        local outcome = combatRound(char)
        if outcome == "win" then
            local res = resolveWin(char)
            if res == "dragon" then return "dragon" end
            break
        elseif outcome == "dead" then
            resolveDeath(char, char._lastFoeName or "Your foe")
            break
        end
    end
end

local function doFlee(char)
    local foe = char.fight
    if not foe then pushLog(char, "You are not in a fight."); return end
    if foe.kind ~= "forest" then pushLog(char, "There is no running from this."); return end
    if chance(45 + char.level * 2) then
        char.fight = nil
        pushLog(char, "You break away from " .. foe.name .. " and slip into the trees.")
    else
        local fhit = math.max(1, math.floor(char.maxHp * ((foe.dmgPct or 4) / 100) / gearWard(char)))
        char.hp = char.hp - fhit
        pushLog(char, string.format("You stumble! %s catches you for %s.  (%s HP left)", foe.name, commas(fhit), commas(math.max(0, char.hp))))
        if char.hp <= 0 then resolveDeath(char, foe.name) end
    end
end

local function doResurrect(char)
    if not char.dead and char.alive then pushLog(char, "You are alive and well."); return end
    rest(char)
end

local DISPATCH = {
    [Actions.FOREST]           = actForest,
    [Actions.ATTACK]           = doAttack,
    [Actions.AUTO_BATTLE]      = doAutoBattle,
    [Actions.FLEE]             = doFlee,
    [Actions.GEM_STRENGTH]     = function(c) spendGems(c, "strength") end,
    [Actions.GEM_VITALITY]     = function(c) spendGems(c, "vitality") end,
    [Actions.GEM_DEFENCE]      = function(c) spendGems(c, "defence") end,
    [Actions.GEM_DECLINE]      = function(c) c.oldMan = false; pushLog(c, "\"Another time, then.\" The old man is gone.") end,
    [Actions.BUY_WEAPON]       = buyWeapon,
    [Actions.BUY_ARMOUR]       = buyArmour,
    [Actions.HEAL_FULL]        = function(c) heal(c, nil) end,
    [Actions.HEAL_SOME]        = function(c) heal(c, 0.25) end,
    [Actions.BANK_DEPOSIT]     = bankDeposit,
    [Actions.BANK_WITHDRAW]    = bankWithdraw,
    [Actions.BANK_GAMBLE]      = bankGamble,
    [Actions.FLIRT]            = flirt,
    [Actions.REST]             = rest,
    [Actions.CHALLENGE_MASTER] = challengeMaster,
    [Actions.ADVANCE_LEVEL]    = advanceLevel,
    [Actions.DRAGON]           = challengeDragon,
    [Actions.RESURRECT]        = doResurrect,
}

--------------------------------------------------------------------
-- PUBLIC ENTRY POINTS
--------------------------------------------------------------------

function Server.GetSnapshot(player)
    local steamId, name = identity(player)
    if not steamId then return nil, "NO_IDENTITY" end
    if not cfg().enabled then return nil, "DISABLED" end
    local char = ensureChar(steamId, name, KIPN.Shared.GetLegacyPlayerIds(player))
    if not char then return nil, "NO_STORE" end
    char._steamId = steamId
    return snapshot(char, store())
end

-- Read-only, no ensureChar: safe to call for any player viewing the
-- KIPN Server Statistics screen (see KIPN_LORDServerStatsPatch.lua).
function Server.GetLeaderboard()
    if not cfg().enabled then return { slayers = {}, adventurers = {} } end
    local s = store()
    if not s then return { slayers = {}, adventurers = {} } end

    local adv = {}
    for _, c in pairs(s.chars or {}) do
        if type(c) == "table" then
            adv[#adv + 1] = {
                name        = c.name or "Adventurer",
                level       = c.level or 1,
                exp         = c.exp or 0,
                dragonKills = c.dragonKills or 0,
                weapon      = weaponName(c.weaponIndex or 0),
            }
        end
    end
    table.sort(adv, function(a, b)
        if a.dragonKills ~= b.dragonKills then return a.dragonKills > b.dragonKills end
        if a.level ~= b.level then return a.level > b.level end
        return (a.exp or 0) > (b.exp or 0)
    end)
    while #adv > 10 do table.remove(adv) end

    return { slayers = s.hall or {}, adventurers = adv }
end

function Server.HandleAction(player, action)
    local steamId, name = identity(player)
    if not steamId then return nil, "NO_IDENTITY" end
    if not cfg().enabled then return nil, "DISABLED" end

    local fn = DISPATCH[action]
    if not fn then return nil, "UNKNOWN_ACTION" end

    local char = ensureChar(steamId, name, KIPN.Shared.GetLegacyPlayerIds(player))
    if not char then return nil, "NO_STORE" end
    char._steamId = steamId

    local signal = fn(char)
    if signal == "dragon" then
        local fresh = onDragonSlain(char)
        if type(fresh) == "table" then char = fresh; char._steamId = steamId end
    end

    persist()
    return snapshot(char, store())
end

log("game logic loaded (full LORD loop)")
