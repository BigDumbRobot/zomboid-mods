-- The Whisperers: shared config, gore measurement and misery effects.
-- Loaded on client, server and single player.

Whisperers = Whisperers or {}
local W = Whisperers

W.Module = "TheWhisperers"
W.HalfMeter = 50
W.FullMeter = 100

W.Defaults = {
    Enabled = true,
    MinGorePercent = 25,
    FullGorePercent = 70,
    MeterRiseRate = 5.0,
    MeterFallRate = 4.0,
    MeterFallDelay = 2,
    MeterZombieRadius = 8,
    UprightStillLevel = 55,
    UprightWalkLevel = 70,
    DisguisedStillLevel = 10,
    DisguisedWalkLevel = 30,
    DisguisedRunLevel = 35,
    DisguisedSprintLevel = 60,
    RunLevel = 85,
    SprintLevel = 100,
    SneakMoveLevel = 10,
    MeleeNoise = 25,
    NoiseMultiplier = 1.0,
    AttractRadiusMin = 5,
    AttractRadiusMax = 18,
    FullAlertRadius = 35,
    InterestHalfLife = 10,
    UnhappinessPerHour = 30.0,
    UnhappinessCap = 85,
    StressPerHour = 20.0,
    StressCap = 60,
    DiscomfortLevel = 80,

    -- Guts
    GutsWeight = 2.5,
    GutsHalfLifeHours = 72,
    GutsBaseYield = 2,
    GutsYieldPerLevel = 0.5,
    GutsCoveragePerItem = 50,
    GutsSmearEfficiency = 75,
    GutsCarryThresholdKg = 5.0,
    GutsCarrySicknessPerHour = 10.0,
    GutsCarryDiscomfort = 60,
    CorpseSicknessPerHour = 12.0,
    CorpseSicknessCap = 80,

    -- Heads and faces
    HeadBlowsLongBlade = 6,
    HeadBlowsAxe = 5,
    HeadStabsShortBlade = 24,
    ShortBladeEndurancePerStab = 0.02,
    FaceCutBaseTime = 600,
    HeadStakeBreakChance = 75,

    -- Masks and suits
    MaskStealthMultiplier = 5.0,
    SuitStealthMultiplier = 10.0,
    MaskCover = 35,
    SuitCover = 65,
    CoverFallBoost = 50.0,
    CoverNoticeBonus = 40,
    MaskVisionBlur = 100,
    MaskClearRadius = 3.0,
    ZombieMannerisms = true,
    WearToggleDamage = 10,
    WearDamagePerHour = 1.0,
    BreakChancePerHour = 3.0,
    GearDryHalfLifeHours = 168,
    GearTreatHours = 336,
    ZombieBrainSickness = 40,
    PlayerBrainMinSkill = 6,
    PlayerBrainLevels = 1,
    NailDamage = 30,
    MaskRepairTailoring = 5,
    SuitTailoring = 4,
    SuitButchering = 3,
    SuitHitDestroyDamage = 20.0,
    SuitHitConditionLoss = 2.0,
}

function W.Get(name)
    local vars = SandboxVars and SandboxVars.TheWhisperers
    if type(vars) == "table" and vars[name] ~= nil then
        return vars[name]
    end
    return W.Defaults[name]
end

function W.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function W.isMultiplayer()
    return (isClient and isClient()) or (isServer and isServer())
end

-- Stable key for a player across clients: online ID in MP, player number in SP.
function W.playerKey(player)
    if W.isMultiplayer() then
        return "o" .. tostring(player:getOnlineID())
    end
    return "l" .. tostring(player:getPlayerNum())
end

-- Gore -------------------------------------------------------------------

local function isWeapon(item)
    return item and instanceof(item, "HandWeapon")
end

-- Returns gorePercent (0-100: how much of the body is caked in visible blood,
-- times any worn face mask / skin suit multiplier), anyGore (true while ANY
-- blood remains on skin, worn clothing, or a carried weapon, or dead skin is
-- worn -- the character stays miserable until all of it is gone), the raw
-- unmultiplied gore, the multiplier, and cover (0-1: how much the worn dead
-- skin hides you, MaskCover + SuitCover).
function W.measureGore(player)
    local partCount = BloodBodyPartType.MAX:index()
    local perPart = {}
    local anyGore = false
    local multiplier = 1
    local cover = 0
    local G = W.Gear

    local visual = player:getHumanVisual()
    if visual then
        for i = 0, partCount - 1 do
            local b = visual:getBlood(BloodBodyPartType.FromIndex(i)) or 0
            perPart[i] = b
            if b > 0.001 then anyGore = true end
        end
    end

    local worn = player:getWornItems()
    if worn then
        for i = 0, worn:size() - 1 do
            local item = worn:get(i):getItem()
            -- Worn dead skin counts as fully bloodied where it covers, and
            -- multiplies the whole disguise while it holds together.
            local deadSkin = G and G.isGear(item) and G.isWorking(item)
            if deadSkin then
                anyGore = true
                multiplier = multiplier * G.multiplierFor(item)
                cover = cover + G.coverFor(item)
            end
            if item and instanceof(item, "Clothing") then
                local covered = BloodClothingType.getCoveredParts(item:getBloodClothingType())
                if covered then
                    for j = 0, covered:size() - 1 do
                        local part = covered:get(j)
                        local b = deadSkin and 1 or (item:getBlood(part) or 0)
                        local idx = part:index()
                        if b > (perPart[idx] or 0) then perPart[idx] = b end
                        if b > 0.001 then anyGore = true end
                    end
                end
            end
        end
    end

    local sum = 0
    for i = 0, partCount - 1 do sum = sum + (perPart[i] or 0) end
    local coverage = partCount > 0 and (sum / partCount) or 0

    local weaponBlood = 0
    local primary = player:getPrimaryHandItem()
    if isWeapon(primary) then weaponBlood = primary:getBloodLevel() or 0 end

    if not anyGore then
        if weaponBlood > 0.001 then
            anyGore = true
        else
            local items = player:getInventory():getItems()
            for i = 0, items:size() - 1 do
                local item = items:get(i)
                if isWeapon(item) and (item:getBloodLevel() or 0) > 0.001 then
                    anyGore = true
                    break
                end
            end
        end
    end

    local raw = W.clamp(coverage * 90 + weaponBlood * 10, 0, 100)
    return W.clamp(raw * multiplier, 0, 100), anyGore, raw, multiplier, W.clamp(cover, 0, 1)
end

-- 0 below the minimum, rising to 1 at the "fully covered" level.
function W.camoStrength(gore)
    local minG = W.Get("MinGorePercent")
    local fullG = math.max(minG + 1, W.Get("FullGorePercent"))
    if gore < minG then return 0 end
    return W.clamp((gore - minG) / (fullG - minG), 0, 1)
end

function W.isCamouflaged(gore)
    return W.Get("Enabled") and gore >= W.Get("MinGorePercent")
end

-- 0-1: how far worn dead skin carries the disguise, the stealth hierarchy
-- guts < face mask < skin suit. 0 with gore alone, MaskCover% in a mask,
-- SuitCover% in a suit, 1 in both, scaled by camouflage strength. It drives
-- how fast the meter settles, how low it settles, how much noise gets
-- through, and how loud you must get before zombies notice.
function W.disguise(strength, cover)
    return W.clamp(strength * (cover or 0), 0, 1)
end

-- Meter level at which zombies start to notice you: half, raised by up to
-- CoverNoticeBonus points by the disguise.
function W.noticeAt(disguise)
    return math.min(W.FullMeter - 1, W.HalfMeter + W.Get("CoverNoticeBonus") * (disguise or 0))
end

-- Misery -----------------------------------------------------------------

W.MiseryClock = W.MiseryClock or {}

-- Stats are server-authoritative in B42 MP: every change made on the server
-- is pushed to the owning client with syncPlayerStats.
local function statMask(stat)
    local ok, mask = pcall(function() return SyncPlayerStatsPacket.getBitMaskForStat(stat) end)
    return ok and tonumber(mask) or 0
end

function W.syncStats(player, stats)
    if not isServer() or not stats or #stats == 0 then return end
    local mask, seen = 0, {}
    for _, stat in ipairs(stats) do
        local m = statMask(stat)
        if m > 0 and not seen[m] then
            seen[m] = true
            mask = mask + m
        end
    end
    if mask > 0 then pcall(syncPlayerStats, player, mask) end
end

-- Raises `stat` by pctAmount percent of its maximum without passing capPct.
-- Returns true if it changed.
function W.raiseStat(stats, stat, pctAmount, capPct)
    if not stat or pctAmount <= 0 then return false end
    local max = stat:getMaximumValue()
    local cap = max * capPct / 100
    local cur = stats:get(stat)
    if cur < cap then
        stats:set(stat, math.min(cap, cur + max * pctAmount / 100))
        return true
    end
    return false
end
local raiseStat = W.raiseStat

-- Held stats -------------------------------------------------------------
-- Vanilla eases DISCOMFORT toward its own target and drains FOOD_SICKNESS
-- every frame, so topping them up now and then makes the moodles flicker.
-- Instead the periodic code records what corpse material is doing to a
-- player (W.setHold) and W.applyHolds re-applies it every tick, the way
-- vanilla's own corpse sickness works.
--   gore, guts  discomfort floors, percent
--   sickRate    corpse sickness, percent of FOOD_SICKNESS per in-game hour
--   sickCap     corpse sickness never passes this, percent
W.Holds = W.Holds or {}

function W.setHold(player, field, value)
    local key = W.playerKey(player)
    local h = W.Holds[key]
    if not h then
        h = {}
        W.Holds[key] = h
    end
    h[field] = value
end

function W.getHold(player, field)
    local h = W.Holds[W.playerKey(player)]
    return h and h[field] or nil
end

-- Vanilla's per-frame food sickness drain (defines.lua).
local function foodSicknessDrain()
    local z = ZomboidGlobals and tonumber(ZomboidGlobals.FoodSicknessDecrease) or 0.0015
    return z * getGameTime():getMultiplier()
end

-- Every tick. Only the side that owns the player's stats adds sickness; any
-- side may hold the discomfort floor so its moodle stays put between syncs.
-- Returns the stats that jumped enough to be worth syncing, or nil.
function W.applyHolds(player, authoritative)
    local h = W.Holds[W.playerKey(player)]
    if not h or player:isDead() or not W.Get("Enabled") then return nil end
    local stats = player:getStats()
    local changed

    local floor = math.max(h.gore or 0, h.guts or 0)
    if floor > 0 then
        local stat = CharacterStat.DISCOMFORT
        local max = stat:getMaximumValue()
        -- One point over the floor keeps vanilla's per-frame easing from
        -- dipping the moodle a level below it.
        local target = math.min(max, max * (floor + 1) / 100)
        local cur = stats:get(stat)
        if cur < target then
            stats:set(stat, target)
            if target - cur > max / 100 then changed = { stat } end
        end
    end

    if not authoritative then return changed end
    if (h.sickRate or 0) <= 0 then
        h.sickClock = nil
        return changed
    end
    local now = getGameTime():getWorldAgeHours()
    local dt = W.clamp(now - (h.sickClock or now), 0, 0.25)
    h.sickClock = now
    local stat = CharacterStat.FOOD_SICKNESS
    local max = stat:getMaximumValue()
    local cap = max * (h.sickCap or 100) / 100
    local cur = stats:get(stat)
    if cur < cap then
        local add = max * h.sickRate / 100 * dt
        -- Vanilla drains food sickness unless poisoned; cancel that while exposed.
        if stats:isAtMinimum(CharacterStat.POISON) then add = add + foodSicknessDrain() end
        stats:set(stat, math.min(cap, cur + add))
    end
    return changed
end

-- Called periodically by whoever owns the player's stats (client in SP, the
-- server in MP). Uses in-game time so fast-forward and sleep behave.
function W.applyMisery(player, gore, anyGore)
    if not player or player:isDead() or not W.Get("Enabled") then return end
    W.setHold(player, "gore", anyGore and W.Get("DiscomfortLevel") or nil)
    local key = W.playerKey(player)
    local now = getGameTime():getWorldAgeHours()
    local last = W.MiseryClock[key]
    W.MiseryClock[key] = now
    if not anyGore or not last then return end

    local dt = W.clamp(now - last, 0, 0.25)
    local intensity = 0.5 + 0.5 * W.clamp(gore / math.max(1, W.Get("FullGorePercent")), 0, 1)
    if CharacterTrait and CharacterTrait.HEMOPHOBIC and player:hasTrait(CharacterTrait.HEMOPHOBIC) then
        intensity = intensity * 2
    end

    local stats = player:getStats()
    if not stats or not CharacterStat then return end
    local changed = {}
    pcall(function()
        if raiseStat(stats, CharacterStat.UNHAPPINESS, W.Get("UnhappinessPerHour") * dt * intensity, W.Get("UnhappinessCap")) then
            changed[#changed + 1] = CharacterStat.UNHAPPINESS
        end
        if raiseStat(stats, CharacterStat.STRESS, W.Get("StressPerHour") * dt * intensity, W.Get("StressCap")) then
            changed[#changed + 1] = CharacterStat.STRESS
        end
    end)
    W.syncStats(player, changed)
end
