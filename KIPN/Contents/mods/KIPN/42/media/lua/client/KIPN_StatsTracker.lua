-- KIPN_StatsTracker.lua
--
-- Client-side accumulation for every Tier B stat in
-- KIPN.Shared.StatsCatalog (shared/KIPN_StatsCatalog.lua) -- the
-- stats that have no vanilla getter and no running total, so they
-- must be derived by hooking events/TimedActions and periodically
-- flushed to the server via SUBMIT_STATS_DELTA.
--
-- Technique credit: every hook here follows the same approach the
-- example mods in Contents/EXAMPLE/ (ServerStats, TwisTonFire Stats
-- MP STABLE) already proved works in vanilla Project Zomboid MP --
-- this file reimplements the technique natively, it does not call
-- into those mods.
--
-- pvpKills and deaths are also Tier B (see the catalog) but are
-- NOT tracked here -- they are computed server-side by
-- KIPN_LeaderboardService.lua's own OnWeaponHitCharacter/
-- OnCharacterDeath handlers. Tracking them here too would double
-- count.
--
-- This module does NOT:
--   * touch UI
--   * persist anything itself (the server owns persistence)
--   * track for anyone but the local player

if isServer() then
    return
end

require "KIPN_Shared"
require "KIPN_StatsCatalog"

if not KIPN then

    error(
        "[KIPN_StatsTracker] "
        .. "KIPN core is not initialized."
    )
end

if not KIPN.Shared or not KIPN.Shared.StatsCatalog then

    error(
        "[KIPN_StatsTracker] "
        .. "KIPN_StatsCatalog is not initialized."
    )
end

--------------------------------------------------------------------
-- PENDING DELTA ACCUMULATOR
--
-- Cumulative fields hold a running numeric total-since-last-flush.
-- Peak fields hold the best candidate seen since last flush. The
-- favoriteWeapon field holds an array of weapon names (one per
-- credited zombie kill) rather than a single value, so a multi-kill
-- flush interval doesn't undercount -- see KIPN_StatsService.lua's
-- applyDelta().
--------------------------------------------------------------------

local pending = {}

local function addCumulative(id, amount)

    if type(amount) ~= "number" or amount <= 0 then
        return
    end

    pending[id] = (pending[id] or 0) + amount
end

local function setPeak(id, candidate)

    if type(candidate) ~= "number" then
        return
    end

    if not pending[id] or candidate > pending[id] then
        pending[id] = candidate
    end
end

local function addFavoriteWeaponKill(weaponName)

    if type(weaponName) ~= "string" or weaponName == "" then
        return
    end

    if type(pending.favoriteWeapon) ~= "table" then
        pending.favoriteWeapon = {}
    end

    pending.favoriteWeapon[#pending.favoriteWeapon + 1] = weaponName
end

--------------------------------------------------------------------
-- LOCAL PLAYER HELPER
--------------------------------------------------------------------

local function getLocalPlayer()

    local ok, player = pcall(getSpecificPlayer, 0)

    if ok and player and not player:isDead() then
        return player
    end

    return nil
end

--------------------------------------------------------------------
-- DISTANCE (FOOT + VEHICLE)
--
-- No vanilla event exists -- diff position each OnPlayerUpdate tick.
-- Skip the first sample after (re)spawn/load, clamp deltas that look
-- like a teleport rather than real movement.
--------------------------------------------------------------------

local FOOT_TELEPORT_THRESHOLD = 25.0
local VEHICLE_TELEPORT_THRESHOLD = 120.0

local lastPosition = { _init = false }

local function updateDistance(player)

    local ok, x, y =
        pcall(
            function()
                return player:getX(), player:getY()
            end
        )

    if not ok then
        return
    end

    if not lastPosition._init then

        lastPosition._init = true
        lastPosition.x = x
        lastPosition.y = y

        return
    end

    local dx = x - lastPosition.x
    local dy = y - lastPosition.y

    lastPosition.x = x
    lastPosition.y = y

    local d = math.sqrt((dx * dx) + (dy * dy))

    if d ~= d then
        -- NaN guard.
        return
    end

    local inVehicle =
        type(player.getVehicle) == "function"
        and player:getVehicle() ~= nil

    if inVehicle then

        if d <= VEHICLE_TELEPORT_THRESHOLD then
            addCumulative("vehicleDistance", d)
        end

    else

        if d <= FOOT_TELEPORT_THRESHOLD then
            addCumulative("distanceTravelled", d)
        end
    end
end

--------------------------------------------------------------------
-- CALORIES CONSUMED
--
-- getNutrition():getCalories() is the CURRENT value, not a running
-- total -- diff it each tick, only counting positive/plausible gains.
--------------------------------------------------------------------

local lastCalories = nil

local function updateCalories(player)

    local ok, nutrition = pcall(function() return player:getNutrition() end)

    if not ok or not nutrition or type(nutrition.getCalories) ~= "function" then
        return
    end

    local okCal, calories = pcall(function() return nutrition:getCalories() end)

    if not okCal or type(calories) ~= "number" then
        return
    end

    if lastCalories ~= nil then

        local gained = calories - lastCalories

        if gained > 0 and gained < 5000 then
            addCumulative("caloriesConsumed", gained)
        end
    end

    lastCalories = calories
end

--------------------------------------------------------------------
-- HEAVIEST CARRIED (PEAK)
--------------------------------------------------------------------

local function updateHeaviestWeight(player)

    if type(player.getInventoryWeight) ~= "function" then
        return
    end

    local ok, weight = pcall(function() return player:getInventoryWeight() end)

    if ok and type(weight) == "number" then
        setPeak("heaviestWeight", weight)
    end
end

--------------------------------------------------------------------
-- MOST KILLS IN A DAY (PEAK)
--
-- Events.EveryDays resets the baseline; OnPlayerUpdate tracks the
-- peak of (current kills - baseline) within the day. If a new life's
-- kill count drops below the stored baseline (kills reset to 0 on
-- respawn), re-anchor rather than reporting a negative daily count.
--------------------------------------------------------------------

local killsAtDayStart = nil

local function onWorldDay()

    local player = getLocalPlayer()

    if not player or type(player.getZombieKills) ~= "function" then
        return
    end

    local ok, kills = pcall(function() return player:getZombieKills() end)

    if ok and type(kills) == "number" then
        killsAtDayStart = kills
    end
end

local function updateMostKillsInDay(player)

    if type(player.getZombieKills) ~= "function" then
        return
    end

    local ok, kills = pcall(function() return player:getZombieKills() end)

    if not ok or type(kills) ~= "number" then
        return
    end

    if killsAtDayStart == nil or kills < killsAtDayStart then
        killsAtDayStart = kills
    end

    setPeak("mostKillsInDay", kills - killsAtDayStart)
end

--------------------------------------------------------------------
-- BULLETS FIRED
--
-- OnWeaponSwing arms a "this swing can shoot" flag; each
-- OnWeaponSwingHitPoint invocation while armed adds one shot's worth
-- of ammo. Ammo-delta tracking (diffing magazine count) is
-- deliberately NOT used -- it drifts in MP because clients don't
-- decrement the magazine locally, the server syncs it later.
--------------------------------------------------------------------

local swingArmed = false

local function onWeaponSwing(_character, weapon)

    swingArmed = false

    local player = getLocalPlayer()

    if not player or not weapon then
        return
    end

    if not ISReloadWeaponAction or type(ISReloadWeaponAction.canShoot) ~= "function" then
        return
    end

    local ok, canShoot = pcall(ISReloadWeaponAction.canShoot, player, weapon)

    swingArmed = ok and canShoot == true
end

local function onWeaponSwingHitPoint(_character, weapon)

    if not swingArmed or not weapon then
        return
    end

    local ok, ammoPerShoot = pcall(function() return weapon:getAmmoPerShoot() end)

    if ok and type(ammoPerShoot) == "number" and ammoPerShoot > 0 then
        addCumulative("bulletsFired", ammoPerShoot)
    end
end

--------------------------------------------------------------------
-- GENERIC TimedAction PATCH HELPER
--
-- Wraps className.methodName so the original still runs, then calls
-- onSuccess(self, ...) afterward. Defensive: silently no-ops if the
-- class/method doesn't exist on this build (mod/version drift), same
-- spirit as the rest of KIPN's defensive style.
--------------------------------------------------------------------

local function patchAction(className, methodName, onSuccess)

    local class = _G[className]

    if not class or type(class[methodName]) ~= "function" then
        return
    end

    local original = class[methodName]

    class[methodName] =
        function(self, ...)

            local result = { original(self, ...) }

            pcall(onSuccess, self, ...)

            return unpack(result)
        end
end

--------------------------------------------------------------------
-- ITEMS CRAFTED
--------------------------------------------------------------------

patchAction(
    "ISHandcraftAction",
    "perform",
    function() addCumulative("itemsCrafted", 1) end
)

patchAction(
    "ISCraftAction",
    "perform",
    function() addCumulative("itemsCrafted", 1) end
)

--------------------------------------------------------------------
-- WEAPONS REPAIRED
--------------------------------------------------------------------

patchAction(
    "ISFixAction",
    "perform",
    function(self)

        local item = self and self.item

        if item and instanceof(item, "HandWeapon") then
            addCumulative("weaponsRepaired", 1)
        end
    end
)

--------------------------------------------------------------------
-- WEAPONS DESTROYED
--
-- Two redundant detection paths, deduped by item ID -- neither
-- vanilla hook alone reliably catches every break.
--------------------------------------------------------------------

local brokenWeaponIds = {}

local function noteWeaponBroken(item)

    if not item or type(item.getID) ~= "function" then
        return
    end

    local ok, id = pcall(function() return item:getID() end)

    if not ok or brokenWeaponIds[id] then
        return
    end

    brokenWeaponIds[id] = true

    addCumulative("weaponsDestroyed", 1)
end

local function checkHeldWeapons(player)

    for _, getterName in ipairs({ "getPrimaryHandItem", "getSecondaryHandItem" }) do

        if type(player[getterName]) == "function" then

            local ok, item = pcall(player[getterName], player)

            if ok and item
                and instanceof(item, "HandWeapon")
                and type(item.isBroken) == "function" then

                local okBroken, broken = pcall(function() return item:isBroken() end)

                if okBroken and broken then
                    noteWeaponBroken(item)
                end
            end
        end
    end
end

if OnBreak then

    for handlerName, handlerFn in pairs(OnBreak) do

        if type(handlerFn) == "function" then

            OnBreak[handlerName] =
                function(item, character, ...)

                    local result = { handlerFn(item, character, ...) }

                    if character and character:isLocalPlayer() then
                        pcall(noteWeaponBroken, item)
                    end

                    return unpack(result)
                end
        end
    end
end

--------------------------------------------------------------------
-- TREES CHOPPED
--
-- Server-authoritative fell/damage in dedicated MP means perform()
-- doesn't always run -- also credit on stop()/isValid() failure once
-- the tree object is confirmed gone (getObjectIndex() < 0).
--------------------------------------------------------------------

local function treeIsGone(action)

    local tree = action and action.tree

    if not tree or type(tree.getObjectIndex) ~= "function" then
        return false
    end

    local ok, index = pcall(function() return tree:getObjectIndex() end)

    return ok and type(index) == "number" and index < 0
end

local function noteTreeChopped(action)

    if not action or action._kipnTreeCounted then
        return
    end

    action._kipnTreeCounted = true

    addCumulative("treesChopped", 1)
end

if ISChopTreeAction then

    patchAction(
        "ISChopTreeAction",
        "perform",
        function(self) noteTreeChopped(self) end
    )

    local originalStop = ISChopTreeAction.stop

    if type(originalStop) == "function" then

        ISChopTreeAction.stop =
            function(self, ...)

                if treeIsGone(self) then
                    pcall(noteTreeChopped, self)
                end

                return originalStop(self, ...)
            end
    end

    local originalIsValid = ISChopTreeAction.isValid

    if type(originalIsValid) == "function" then

        ISChopTreeAction.isValid =
            function(self, ...)

                local valid = originalIsValid(self, ...)

                if not valid and treeIsGone(self) then
                    pcall(noteTreeChopped, self)
                end

                return valid
            end
    end
end

--------------------------------------------------------------------
-- FIRES LIT
--------------------------------------------------------------------

for _, className in ipairs({
    "ISLightFromLiterature",
    "ISLightFromKindle",
    "ISLightFromPetrol",
}) do

    patchAction(
        className,
        "perform",
        function() addCumulative("firesLit", 1) end
    )
end

--------------------------------------------------------------------
-- FORAGE FINDS
--------------------------------------------------------------------

patchAction(
    "ISForageAction",
    "perform",
    function() addCumulative("forageFinds", 1) end
)

--------------------------------------------------------------------
-- PLANTS HARVESTED
--------------------------------------------------------------------

patchAction(
    "ISHarvestPlantAction",
    "perform",
    function() addCumulative("plantsHarvested", 1) end
)

--------------------------------------------------------------------
-- FISH CAUGHT
--
-- ISPickupFishAction handles junk pickups too -- must check the
-- transition into having a fish AND the isFish flag.
--------------------------------------------------------------------

if ISPickupFishAction
    and type(ISPickupFishAction.PickupFishUpdate) == "function" then

    local originalPickupFishUpdate = ISPickupFishAction.PickupFishUpdate

    ISPickupFishAction.PickupFishUpdate =
        function(self, ...)

            local wasInInv = self and self.fishInInv

            local result = { originalPickupFishUpdate(self, ...) }

            if self and self.isFish
                and self.fishInInv
                and not wasInInv then

                addCumulative("fishCaught", 1)
            end

            return unpack(result)
        end
end

--------------------------------------------------------------------
-- TRAPS CAUGHT
--
-- The animal-presence check must run BEFORE the original perform(),
-- which clears it.
--------------------------------------------------------------------

if ISCheckTrapAction
    and type(ISCheckTrapAction.perform) == "function" then

    local function trapHasCaughtAnimal(trap)

        if not trap then
            return false
        end

        if type(trap.updateFromIsoObject) == "function" then
            pcall(function() trap:updateFromIsoObject() end)
        end

        return trap.animal ~= nil
            and trap.animal.type ~= nil
    end

    local originalCheckTrap = ISCheckTrapAction.perform

    ISCheckTrapAction.perform =
        function(self, ...)

            local caught =
                self and trapHasCaughtAnimal(self.trap)

            local result = { originalCheckTrap(self, ...) }

            if caught then
                addCumulative("trapsCaught", 1)
            end

            return unpack(result)
        end
end

--------------------------------------------------------------------
-- THINGS BUILT (CARPENTRY)
--------------------------------------------------------------------

patchAction(
    "ISBuildAction",
    "perform",
    function() addCumulative("thingsBuilt", 1) end
)

if ISMultiStageBuild then

    if type(ISMultiStageBuild.perform) == "function" then

        patchAction(
            "ISMultiStageBuild",
            "perform",
            function() addCumulative("thingsBuilt", 1) end
        )

    elseif type(ISMultiStageBuild.complete) == "function" then

        local originalComplete = ISMultiStageBuild.complete

        ISMultiStageBuild.complete =
            function(self, result, ...)

                local returned = { originalComplete(self, result, ...) }

                if result ~= false then
                    addCumulative("thingsBuilt", 1)
                end

                return unpack(returned)
            end
    end
end

--------------------------------------------------------------------
-- FAVORITE WEAPON (BY CONFIRMED ZOMBIE KILL)
--
-- Mirrors the PvP attribution technique KIPN_LeaderboardService.lua
-- already uses server-side, applied here client-side to zombie
-- kills: record the most recent hit per zombie, credit the weapon
-- when that zombie dies shortly after.
--------------------------------------------------------------------

local HIT_CREDIT_WINDOW_MS = 10000

local lastZombieHit = {}

local function classifyWeaponName(weapon)

    if not weapon then
        return "Unarmed"
    end

    local ok, name = pcall(function() return weapon:getDisplayName() end)

    if ok and name and name ~= "" then
        return name
    end

    return "Unknown"
end

local function onZombieWeaponHit(attacker, victim, weapon)

    if not victim or not instanceof(victim, "IsoZombie") then
        return
    end

    if not attacker or not attacker:isLocalPlayer() then
        return
    end

    lastZombieHit[victim] = {
        weaponName = classifyWeaponName(weapon),
        atMs = _G.getTimestampMs and _G.getTimestampMs() or 0,
    }
end

local function onZombieDead(zombie)

    local hit = lastZombieHit[zombie]

    lastZombieHit[zombie] = nil

    if not hit then
        return
    end

    local now = _G.getTimestampMs and _G.getTimestampMs() or 0

    if now - (hit.atMs or 0) <= HIT_CREDIT_WINDOW_MS then
        addFavoriteWeaponKill(hit.weaponName)
    end
end

if Events and Events.OnWeaponHitCharacter then
    Events.OnWeaponHitCharacter.Add(onZombieWeaponHit)
end

if Events and Events.OnZombieDead then
    Events.OnZombieDead.Add(onZombieDead)
end

if Events and Events.OnWeaponSwing then
    Events.OnWeaponSwing.Add(onWeaponSwing)
end

if Events and Events.OnWeaponSwingHitPoint then
    Events.OnWeaponSwingHitPoint.Add(onWeaponSwingHitPoint)
end

if Events and Events.EveryDays then
    Events.EveryDays.Add(onWorldDay)
end

--------------------------------------------------------------------
-- PERIODIC FLUSH
--
-- Per-tick sampling (distance/calories/weight/daily-kills/held-
-- weapon check) runs unthrottled on every OnPlayerUpdate. The actual
-- network flush is throttled to roughly once every 5 real seconds.
--------------------------------------------------------------------

local FLUSH_INTERVAL_MS = 5000

local lastFlushMs = 0

local function isTableEmpty(t)
    for _ in pairs(t) do
        return false
    end
    return true
end

local function flush(_player)

    if isTableEmpty(pending) then
        return
    end

    local ok = pcall(
        sendClientCommand,
        "KIPN",
        KIPN.Shared.Commands.SUBMIT_STATS_DELTA,
        pending
    )

    if ok then
        pending = {}
    end
end

local function onPlayerUpdate(player)

    if not player or not player:isLocalPlayer() or player:isDead() then
        return
    end

    updateDistance(player)
    updateCalories(player)
    updateHeaviestWeight(player)
    updateMostKillsInDay(player)
    checkHeldWeapons(player)

    local now = _G.getTimestampMs and _G.getTimestampMs() or 0

    if lastFlushMs == 0 or (now - lastFlushMs) >= FLUSH_INTERVAL_MS then
        lastFlushMs = now
        flush(player)
    end
end

if Events and Events.OnPlayerUpdate then
    Events.OnPlayerUpdate.Add(onPlayerUpdate)
end

if Events and Events.OnPlayerAttackFinished then

    Events.OnPlayerAttackFinished.Add(
        function(player)
            if player and player:isLocalPlayer() then
                checkHeldWeapons(player)
            end
        end
    )
end

print("[KIPN] Stats Tracker loaded")
