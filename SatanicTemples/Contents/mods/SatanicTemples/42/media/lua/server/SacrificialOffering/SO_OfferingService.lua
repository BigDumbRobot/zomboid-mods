if isClient() then return end

require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"
require "SacrificialOffering/SO_Sandbox"
require "SacrificialOffering/SO_RecipeParser"
require "SacrificialOffering/SO_Storage"
require "SacrificialOffering/SO_PlayerLedger"
require "SacrificialOffering/SO_FixtureService"
require "SacrificialOffering/SO_ZoneService"
require "Camping/SCampfireSystem"

local SO = SacrificialOffering
SO.OfferingService = SO.OfferingService or {}
local Offerings = SO.OfferingService

Offerings.ActiveAltars = Offerings.ActiveAltars or {}
Offerings.PendingWrath = Offerings.PendingWrath or {}
Offerings.PendingWrathByAltar = Offerings.PendingWrathByAltar or {}
-- Rituals in progress: tx -> the verdict committed when the ritual started.
Offerings.PendingRituals = Offerings.PendingRituals or {}
Offerings.RitualByAltar = Offerings.RitualByAltar or {}

-- Nobody learns the outcome before the ritual channel ends, so the verdict is
-- delivered as soon as it ends (the channel itself is the suspense).
local WRATH_SUSPENSE_MS = 0
-- An abandoned ritual whose committed verdict is wrath still delivers it once
-- the ritual would have ended. Time only accrues while the game is ticking, so
-- pausing single-player cannot make it land early.
local RITUAL_MS = math.floor(SO.RITUAL_SECONDS * 1000)
local RITUAL_GRACE_MS = 5000
local MAX_RITUAL_TICK_STEP_MS = 250
local NEARBY_ANIMAL_RADIUS_TILES = 1
-- The configured animal recovery strength represents a substantial adult
-- carcass. B42 corpse-item weight is the animal's actual body weight and, unlike
-- animalSize, is comparable between species and already reflects juveniles.
local FULL_STRENGTH_ANIMAL_WEIGHT = 100
-- Large livestock may be considerably more valuable than the 100 kg baseline,
-- but no single animal should approach the rare-item or player-corpse tiers.
-- If an admin configures a baseline above 15, that explicit setting remains the
-- minimum ceiling so a 100 kg carcass can still deliver the configured value.
local LARGE_ANIMAL_RECOVERY_CAP = 15
local GREED_TRANSLATIONS = {
    "IGUI_SO_GreedWrath_1",
    "IGUI_SO_GreedWrath_2",
    "IGUI_SO_GreedWrath_3",
    "IGUI_SO_GreedWrath_4",
    "IGUI_SO_GreedWrath_5",
    "IGUI_SO_GreedWrath_6",
    "IGUI_SO_GreedWrath_7",
    "IGUI_SO_GreedWrath_8",
}

local function randomGreedTranslation()
    return GREED_TRANSLATIONS[ZombRand(0, #GREED_TRANSLATIONS) + 1]
end

local function broadcastEffect(effect, position, tx)
    local args = { effect = effect, x = position.x, y = position.y, z = position.z, tx = tx }
    if isServer() then
        sendServerCommand(SO.MODULE, SO.SERVER_COMMAND.EFFECT, args)
    elseif SO.Client and SO.Client.HandleEffect then
        SO.Client.HandleEffect(args)
    end
end

local function sendSoundCue(player, tx, outcome)
    local args = { tx = tx, outcome = outcome }
    if isServer() then
        sendServerCommand(player, SO.MODULE, SO.SERVER_COMMAND.SOUND_CUE, args)
    elseif SO.Sound and SO.Sound.HandleFirstBeat then
        SO.Sound.HandleFirstBeat(args)
    end
end

local function findAltar(args)
    local zone = SO.Storage.FindZone(args and args.zoneId)
    if not zone or not zone.fixtures or not zone.fixtures.altar then return nil, nil end

    local front = zone.fixtures.altar
    local back = zone.fixtures.altarBack or { x = front.x, y = front.y - 1, z = front.z }
    local x, y, z = tonumber(args and args.x), tonumber(args and args.y), tonumber(args and args.z)
    local position, kind
    if x == front.x and y == front.y and z == front.z then
        position, kind = front, SO.FIXTURE.ALTAR
    elseif x == back.x and y == back.y and z == back.z then
        position, kind = back, SO.FIXTURE.ALTAR_BACK
    else
        return nil, nil
    end

    local altar = SO.Fixtures.FindTaggedObject(position.x, position.y, position.z, kind)
    if not altar or altar:getName() ~= SO.ALTAR_NAME then return nil, nil end
    local md = altar:getModData()
    if tonumber(md[SO.MOD_DATA.ZONE_ID]) ~= tonumber(zone.id) then return nil, nil end
    local container = altar:getContainer()
    if not container or container:getType() ~= SO.ALTAR_CONTAINER_TYPE then return nil, nil end
    return zone, altar
end

-- The two dumpster sprites have separate ItemContainers, but together they are
-- one sacrificial altar.  Every judgment and consumption pass uses both.
local function altarContainers(zone)
    local result = {}
    local fixtures = zone and zone.fixtures
    local front = fixtures and fixtures.altar
    if not front then return result end
    local positions = {
        { position = front, kind = SO.FIXTURE.ALTAR },
        {
            position = fixtures.altarBack or { x = front.x, y = front.y - 1, z = front.z },
            kind = SO.FIXTURE.ALTAR_BACK,
        },
    }

    for _, entry in ipairs(positions) do
        local position = entry.position
        local object = SO.Fixtures.FindTaggedObject(position.x, position.y, position.z, entry.kind)
        local container = object and object:getContainer()
        if container and container:getType() == SO.ALTAR_CONTAINER_TYPE then
            result[#result + 1] = container
        end
    end
    return result
end

local function isCampfireLit(zone)
    if not zone or not zone.fixtures or not zone.fixtures.campfire then return false end
    local position = zone.fixtures.campfire
    local campfire = SCampfireSystem.instance:getLuaObjectAt(position.x, position.y, position.z)
    if not campfire or not campfire.isLit or not campfire:getIsoObject() then return false end
    local md = campfire:getIsoObject():getModData()
    return md and md[SO.MOD_DATA.PROTECTED] == true and tonumber(md[SO.MOD_DATA.ZONE_ID]) == tonumber(zone.id)
end

local function snapshotItems(containers)
    local result = {}
    for _, container in ipairs(containers) do
        local items = container:getItems()
        for index = 0, items:size() - 1 do table.insert(result, items:get(index)) end
    end
    return result
end

local function isIntactAnimalBody(body)
    -- A carcass is a sacrifice only while it is the complete animal.
    -- server-authoritative because the item's name and icon are not reliable
    -- indicators after butchering. B42 sets these flags as the head, hide, and
    -- meat are removed and hasAnimalParts() becomes false for a stripped body.
    local intactOk, intact = pcall(function()
        if not body:isAnimal() or body:isAnimalSkeleton() or not body:hasAnimalParts() then return false end
        local md = body:getModData()
        return not md or (md.skeleton ~= true and md.skinned ~= true and md.headless ~= true)
    end)
    return intactOk and intact == true
end

local function intactAnimalBody(item)
    if not item then return nil end
    if item:getFullType() ~= "Base.CorpseAnimal" then return nil end
    local ok, body = pcall(function() return item:getDeadBodyObject() end)
    if not ok or not isIntactAnimalBody(body) then return nil end
    return body
end

local function isAnimalCorpse(item)
    return intactAnimalBody(item) ~= nil
end

-- Large animal bodies cannot always fit in either dumpster container. Treat an
-- intact carcass on either altar tile or any immediately adjacent square as an
-- offering. Both ordinary IsoDeadBody carcasses and dropped CorpseAnimal world
-- items are supported; other ground items and human corpses are ignored.
local function nearbyAnimalOfferings(zone)
    local items, targets = {}, {}
    local fixtures = zone and zone.fixtures
    local front = fixtures and fixtures.altar
    if not front then return items, targets end
    local centers = {
        front,
        fixtures.altarBack or { x = front.x, y = front.y - 1, z = front.z },
    }
    local seenSquares, seenObjects = {}, {}

    local function collect(item, object, kind, square)
        if not item or not object or seenObjects[object] or not isAnimalCorpse(item) then return end
        seenObjects[object] = true
        items[#items + 1] = item
        targets[#targets + 1] = { object = object, kind = kind, square = square }
    end

    for _, center in ipairs(centers) do
        for dx = -NEARBY_ANIMAL_RADIUS_TILES, NEARBY_ANIMAL_RADIUS_TILES do
            for dy = -NEARBY_ANIMAL_RADIUS_TILES, NEARBY_ANIMAL_RADIUS_TILES do
                local square = getCell():getGridSquare(center.x + dx, center.y + dy, center.z)
                if square and not seenSquares[square] then
                    seenSquares[square] = true

                    local bodies = square:getStaticMovingObjects()
                    for index = 0, bodies:size() - 1 do
                        local body = bodies:get(index)
                        if body and instanceof(body, "IsoDeadBody") and isIntactAnimalBody(body) then
                            local ok, item = pcall(function() return body:getItem() end)
                            if ok then collect(item, body, "body", square) end
                        end
                    end

                    local worldObjects = square:getWorldObjects()
                    for index = 0, worldObjects:size() - 1 do
                        local object = worldObjects:get(index)
                        local ok, item = pcall(function() return object:getItem() end)
                        if ok then collect(item, object, "world-item", square) end
                    end
                end
            end
        end
    end
    return items, targets
end

local function snapshotOffering(zone, containers)
    local items = snapshotItems(containers)
    local nearbyItems, nearbyTargets = nearbyAnimalOfferings(zone)
    for _, item in ipairs(nearbyItems) do items[#items + 1] = item end
    return items, nearbyTargets
end

local function scriptHasTag(item, expectedTag)
    if not item then return false end
    -- Try the namespaced tag ("base:animalhead") and its short form ("animalhead").
    local forms = { expectedTag }
    local short = tostring(expectedTag):match("[^:]+$")
    if short and short ~= expectedTag then forms[#forms + 1] = short end

    -- B42.20's InventoryItem:hasTag takes an ItemTag object, not a string:
    -- hasTag("base:animalhead") throws "No implementation found" (caught, but
    -- debug servers dump a stack trace for every item checked). Resolve the tag
    -- the way vanilla does and pass that.
    local tagOk, tag = pcall(function() return ItemTag.get(ResourceLocation.of(expectedTag)) end)
    if tagOk and tag then
        local ok, has = pcall(function() return item:hasTag(tag) end)
        if ok then return has == true end
    end

    local ok, found = pcall(function()
        local scriptItem = item.getScriptItem and item:getScriptItem()
        local tags = scriptItem and scriptItem.getTags and scriptItem:getTags()
        if not tags then return false end
        local values = (tags.toArray and tags:toArray()) or tags
        local count = (values.size and values:size()) or #values
        for index = 1, count do
            local raw = (values.get and values:get(index - 1)) or values[index]
            if raw then
                local text = string.lower(tostring(raw))
                for _, form in ipairs(forms) do
                    if text == string.lower(form) then return true end
                end
            end
        end
        return false
    end)
    return ok and found == true
end

local function isAnimalHead(item)
    return scriptHasTag(item, "base:animalhead")
end

local function animalCorpseContribution(item)
    local body = intactAnimalBody(item)
    if not body then return nil end
    local weight = 0
    local weightOk = pcall(function()
        weight = tonumber(item:getActualWeight()) or 0
    end)
    if not weightOk or weight <= 0 then
        -- Modded corpse items may omit actualWeight. Preserve a small, nonzero
        -- fallback without letting missing metadata grant a full sacrifice.
        weight = 1
    end
    local baseStrength = SO.Sandbox.RecoveryStrength("animal")
    local rawSizeFactor = math.max(0, weight / FULL_STRENGTH_ANIMAL_WEIGHT)
    local contributionCap = math.max(LARGE_ANIMAL_RECOVERY_CAP, baseStrength)
    local contribution = math.min(baseStrength * rawSizeFactor, contributionCap)
    local creditedSizeFactor = baseStrength > 0 and contribution / baseStrength or 0
    return contribution, creditedSizeFactor, weight
end

local function animalHeadContribution(item)
    if not isAnimalHead(item) then return nil end
    local weight = 1
    pcall(function() weight = tonumber(item:getActualWeight()) or 1 end)
    -- A two-kilogram adult livestock head reaches 15% of a full-size carcass;
    -- lighter juvenile and small-animal heads are worth proportionally less.
    local headSize = SO.Util.Clamp(weight / 2, 0.2, 1)
    return SO.Sandbox.RecoveryStrength("animal") * 0.15 * headSize, headSize
end

local function itemQuality(item)
    if not item then return 0.1 end
    local conditionQuality = 1
    local conditionOk, condition, maximum = pcall(function()
        return item:getCondition(), item:getConditionMax()
    end)
    if conditionOk and tonumber(maximum) and tonumber(maximum) > 0 then
        conditionQuality = SO.Util.Clamp((tonumber(condition) or 0) / tonumber(maximum), 0, 1)
    end
    local brokenOk, broken = pcall(function() return item:isBroken() end)
    if brokenOk and broken == true then conditionQuality = 0 end

    local quality = conditionQuality
    local ammoOk, currentAmmo, maximumAmmo = pcall(function()
        return item:getCurrentAmmoCount(), item:getMaxAmmo()
    end)
    local isWeapon = instanceof and instanceof(item, "HandWeapon")
    if ammoOk and not isWeapon and tonumber(maximumAmmo) and tonumber(maximumAmmo) > 0 then
        local ammoQuality = SO.Util.Clamp((tonumber(currentAmmo) or 0) / tonumber(maximumAmmo), 0, 1)
        quality = math.min(quality, ammoQuality)
    end

    -- A broken item or empty magazine is still an accepted sacrifice, but is
    -- worth only a tenth of a perfect/full example rather than becoming free.
    return math.max(0.1, quality)
end

-- Score every rare item in the offering: each satisfied recipe instance (a
-- repeated item can satisfy the same recipe again) adds baseStrength x its own
-- quality. The caller caps the running life total at 100, so over-supplying in a
-- single sacrifice is never a penalty -- it just fills to the ceiling and
-- consumes everything. Only a LATER attempt, once the life is already maxed,
-- draws wrath.
local function scoreRareItems(recipes, items, baseStrength)
    local byType = {}
    for _, item in ipairs(items or {}) do
        local fullType = item and item:getFullType()
        if fullType then
            byType[fullType] = byType[fullType] or {}
            table.insert(byType[fullType], itemQuality(item))
        end
    end
    for _, list in pairs(byType) do
        table.sort(list, function(left, right) return left > right end)
    end

    local cursor = {}
    local count, strengthSum, qualitySum, qualityN = 0, 0, 0, 0
    for _, recipe in ipairs(recipes or {}) do
        local parts = recipe.parts or {}
        while #parts > 0 do
            local canSatisfy = true
            for _, part in ipairs(parts) do
                if #(byType[part.fullType] or {}) - (cursor[part.fullType] or 0) < part.count then
                    canSatisfy = false
                    break
                end
            end
            if not canSatisfy then break end

            local instanceSum, instanceN = 0, 0
            for _, part in ipairs(parts) do
                local list = byType[part.fullType]
                local used = cursor[part.fullType] or 0
                for offset = 1, part.count do
                    instanceSum = instanceSum + (list[used + offset] or 0.1)
                    instanceN = instanceN + 1
                end
                cursor[part.fullType] = used + part.count
            end
            local instanceQuality = instanceN > 0 and (instanceSum / instanceN) or 0.1
            strengthSum = strengthSum + baseStrength * instanceQuality
            qualitySum = qualitySum + instanceSum
            qualityN = qualityN + instanceN
            count = count + 1
        end
    end
    local averageQuality = qualityN > 0 and (qualitySum / qualityN) or 0
    return count, strengthSum, averageQuality
end

local function playerCorpseOwner(item)
    if not item then return nil end
    local itemType = item:getFullType()
    if itemType ~= "Base.CorpseMale" and itemType ~= "Base.CorpseFemale" then return nil end
    local ok, body = pcall(function() return item:getDeadBodyObject() end)
    if not ok or not SO.PlayerLedger.IsPlayerCorpse(body) then return nil end
    -- GetCorpseOwner performs a final authoritative tagging attempt while the
    -- draggable item's embedded IsoDeadBody is still available.
    return SO.PlayerLedger.GetCorpseOwner(item)
end

local function isPlayerCorpse(item)
    if not item then return false end
    local itemType = item:getFullType()
    if itemType ~= "Base.CorpseMale" and itemType ~= "Base.CorpseFemale" then return false end
    local ok, body = pcall(function() return item:getDeadBodyObject() end)
    return ok and SO.PlayerLedger.IsPlayerCorpse(body)
end

local function analyze(items, player)
    local identity = SO.PlayerLedger.GetIdentity(player)
    local hasAnimal, hasPlayerCorpse = false, false
    local hasOtherPlayerCorpse, hasOwnPlayerCorpse, hasUnknownPlayerCorpse = false, false, false
    local corpseVictims = {}
    for _, item in ipairs(items) do
        if isAnimalCorpse(item) or isAnimalHead(item) then hasAnimal = true end
        if isPlayerCorpse(item) then
            hasPlayerCorpse = true
            local owner = playerCorpseOwner(item)
            if not owner or not identity then
                hasUnknownPlayerCorpse = true
            elseif owner == identity then
                hasOwnPlayerCorpse = true
            else
                hasOtherPlayerCorpse = true
                corpseVictims[#corpseVictims + 1] = owner
            end
        end
    end

    -- Offering your own corpse is a cheat attempt: the Dark Lord takes the flesh
    -- and carves his due out of the living body. An unidentified player corpse
    -- is treated as one's own: only a corpse positively tied to somebody else
    -- may grant recovery, so missing ownership metadata can never become a
    -- reward exploit. Punished before anything else.
    if hasOwnPlayerCorpse or hasUnknownPlayerCorpse then
        return { valid = false, reason = "self-corpse", hasPlayerCorpse = true }
    end

    -- Highest tier: a corpse positively owned by another player needs no animal
    -- corpse or item recipe. Its strength decays only for this sacrificer when
    -- they repeatedly redeem corpses belonging to the same victim.
    if hasOtherPlayerCorpse then
        local recoveryStrength, priorVictimUses = 0, 0
        for _, victimIdentity in ipairs(corpseVictims) do
            local candidateStrength, uses = SO.PlayerLedger.GetPlayerCorpseRecoveryStrength(player, victimIdentity)
            if candidateStrength > recoveryStrength then
                recoveryStrength = candidateStrength
                priorVictimUses = uses
            end
        end
        return {
            valid = true,
            kind = "corpse",
            recoveryStrength = recoveryStrength,
            recoveryCap = 100,
            additiveRecovery = false,
            baseRecoveryStrength = SO.Sandbox.RecoveryStrength("corpse"),
            corpseVictims = corpseVictims,
            priorVictimUses = priorVictimUses,
            hasAnimal = hasAnimal,
            hasPlayerCorpse = true,
        }
    end

    local recipes = SO.RecipeParser.Parse(SO.Sandbox.String("AcceptableItemRecipes"))
    local baseRecoveryStrength = SO.Sandbox.RecoveryStrength("item")
    local rareCount, rareStrengthRaw, rareQuality = scoreRareItems(recipes, items, baseRecoveryStrength)
    if rareCount > 0 then
        -- Report the true offering value (each rare item counts). PlanRecovery
        -- clamps to 100 and against what the life has already redeemed, so a
        -- single sacrifice of 2+ pristine rare items fills straight to full.
        local recoveryStrength = math.floor(math.min(rareStrengthRaw, 100) * 10 + 0.5) / 10
        return {
            valid = true,
            kind = "item",
            recoveryStrength = recoveryStrength,
            recoveryCap = 100,
            additiveRecovery = true,
            baseRecoveryStrength = baseRecoveryStrength,
            quality = rareQuality,
            rareItemCount = rareCount,
            hasAnimal = hasAnimal,
            hasPlayerCorpse = hasPlayerCorpse,
        }
    end

    -- Lowest tier: intact carcasses and butchered animal heads may be combined,
    -- but unrelated items cannot turn an invalid mixture into an animal offering.
    local animalOnly = hasAnimal and #items > 0
    local animalStrength, carcassCount, headCount = 0, 0, 0
    local animalCarcassWeight, animalSizeFactor = 0, 0
    if animalOnly then
        for _, item in ipairs(items) do
            local contribution, sizeFactor, carcassWeight = animalCorpseContribution(item)
            if contribution then
                animalStrength = animalStrength + contribution
                carcassCount = carcassCount + 1
                animalCarcassWeight = animalCarcassWeight + (carcassWeight or 0)
                animalSizeFactor = animalSizeFactor + (sizeFactor or 0)
            else
                contribution = animalHeadContribution(item)
            end
            if contribution and not isAnimalCorpse(item) then
                animalStrength = animalStrength + contribution
                headCount = headCount + 1
            elseif not contribution then
                animalOnly = false
                break
            end
        end
    end
    if animalOnly then
        local roundedStrength = math.floor(animalStrength * 10 + 0.5) / 10
        if animalStrength > 0 then roundedStrength = math.max(0.1, roundedStrength) end
        return {
            valid = true,
            kind = "animal",
            recoveryStrength = roundedStrength,
            recoveryCap = SO.Sandbox.RecoveryStrength("item"),
            additiveRecovery = true,
            baseRecoveryStrength = SO.Sandbox.RecoveryStrength("animal"),
            animalCarcassCount = carcassCount,
            animalHeadCount = headCount,
            animalCarcassWeight = animalCarcassWeight,
            animalSizeFactor = animalSizeFactor,
            hasAnimal = true,
            hasPlayerCorpse = false,
        }
    end
    return {
        valid = false,
        reason = "unacceptable-item",
        hasAnimal = hasAnimal,
        hasPlayerCorpse = hasPlayerCorpse,
    }
end

local function soundOutcomeFor(analysis)
    -- A player's own (or unidentifiable) player corpse is a known rejection.
    -- It keeps SatanThinks on the first beat and selects SacrificeDenied after
    -- the suspense smoke, while another player's corpse retains its special
    -- PlayerCorpse response.
    if analysis and analysis.reason == "self-corpse" then return SO.SOUND_OUTCOME.FAILURE end
    if analysis and analysis.hasPlayerCorpse then return SO.SOUND_OUTCOME.PLAYER_CORPSE end
    if analysis and analysis.valid then return SO.SOUND_OUTCOME.SUCCESS_ITEM end
    return SO.SOUND_OUTCOME.FAILURE
end

local function consumeAll(containers, nearbyAnimals)
    local consumed = 0
    for _, container in ipairs(containers) do
        while container:getItems():size() > 0 do
            local item = container:getItems():get(0)
            container:DoRemoveItem(item)
            if sendRemoveItemFromContainer then sendRemoveItemFromContainer(container, item) end
            consumed = consumed + 1
        end
        container:setDrawDirty(true)
    end
    for _, target in ipairs(nearbyAnimals or {}) do
        local object = target.object
        local square = object and object:getSquare()
        -- The offering snapshot is fresh and transactions are server-serialized,
        -- but retain this identity check so a carcass moved by another system is
        -- never removed from a different square.
        if square and square == target.square then
            if target.kind == "body" then
                square:removeCorpse(object, false)
            else
                square:transmitRemoveItemFromSquare(object)
            end
            consumed = consumed + 1
        end
    end
    return consumed
end

local function parsePrizeItems(raw)
    local prizes, total = {}, 0
    for token in tostring(raw or ""):gmatch("[^;,+]+") do
        local part = SO.RecipeParser.ParsePart(token)
        if part and total < 100 then
            local count = math.min(part.count, 100 - total)
            prizes[#prizes + 1] = { fullType = part.fullType, count = count }
            total = total + count
        end
    end
    return prizes, total
end

local function spawnPlayerCorpsePrizes(player)
    if not SO.Sandbox.Boolean("PlayerCorpsePrizeEnabled") then return 0 end
    local square = player and player:getCurrentSquare()
    if not square then return 0 end

    local prizes, requested = parsePrizeItems(SO.Sandbox.String("PlayerCorpsePrizeItems"))
    local spawned = 0
    for _, prize in ipairs(prizes) do
        for _ = 1, prize.count do
            local ok, worldItem = pcall(function()
                local item = instanceItem(prize.fullType)
                if not item then return nil end
                local offset = 0.2 + (spawned % 6) * 0.1
                return square:AddWorldInventoryItem(item, math.min(offset, 0.8), 0.2 + (math.floor(spawned / 6) % 6) * 0.1, 0)
            end)
            if ok and worldItem then
                spawned = spawned + 1
            else
                SO.Logger.Warn("Could not create configured player-corpse prize", {
                    fullType = prize.fullType,
                })
            end
        end
    end
    SO.Logger.Info("Created player-corpse prizes", { requested = requested, spawned = spawned })
    return spawned
end

local function planRecovery(player, analysis)
    return SO.PlayerLedger.PlanRecovery(player, analysis.recoveryStrength,
        analysis.recoveryCap or 100, analysis.additiveRecovery == true)
end

local function rollWrathDamage()
    local minimum, maximum = SO.Sandbox.WrathRange()
    return ZombRand(minimum, maximum + 1)
end

-- Zombie injuries are applied to the server's IsoPlayer and then sent to that
-- player's connection. Wrath follows the same authoritative path so both sides
-- retain the body-part injuries and their matching overall-health decrease.

local function applyWrath(player, damage, breakBones)
    local body = player and player:getBodyDamage()
    if not body then return false end

    local ok, err = pcall(function()
        -- The rolled damage is the exact health taken. Deep wounds, scratches
        -- and fractures carry damage of their own, so they go on first and the
        -- general-health cut (spread over the body parts by the game's own
        -- modifiers) only tops the loss up to the roll.
        local startHealth = tonumber(body:getOverallBodyHealth()) or 0
        local target = math.max(0, startHealth - damage)

        local parts = body:getBodyParts()
        if parts and parts:size() > 0 then
            local woundCandidates = {}
            for index = 0, parts:size() - 1 do
                woundCandidates[#woundCandidates + 1] = index
            end

            local function takeRandomIndex(candidates)
                local position = ZombRand(0, #candidates) + 1
                return table.remove(candidates, position)
            end

            -- Every wrath event has randomized wound locations and severity:
            -- one or two deep wounds and one to three scratches.
            local deepCount = math.min(1 + ZombRand(0, 2), #woundCandidates)
            local deepIndices = {}
            for _ = 1, deepCount do
                deepIndices[#deepIndices + 1] = takeRandomIndex(woundCandidates)
            end

            local scratchCount = math.min(1 + ZombRand(0, 3), #woundCandidates)
            if scratchCount == 0 then scratchCount = 1 end
            for _ = 1, scratchCount do
                local scratchIndex
                if #woundCandidates > 0 then
                    scratchIndex = takeRandomIndex(woundCandidates)
                else
                    scratchIndex = deepIndices[1]
                end

                local part = parts:get(scratchIndex)
                part:setScratched(true, true)
                part:generateBleeding()
                part:setAdditionalPain(part:getAdditionalPain() + 15.0)
            end

            for index = 1, #deepIndices do
                local part = parts:get(deepIndices[index])
                part:generateDeepWound()
                part:setAdditionalPain(part:getAdditionalPain() + 30.0)
            end

            -- Sacrificing one's own corpse adds one or two broken bones. The
            -- 50-80 duration is the same range used by B42 fall fractures.
            if breakBones then
                local fractureCandidates = {}
                for index = 0, parts:size() - 1 do
                    fractureCandidates[#fractureCandidates + 1] = index
                end
                local fractureCount = math.min(1 + ZombRand(0, 2), #fractureCandidates)
                for _ = 1, fractureCount do
                    local fractureIndex = takeRandomIndex(fractureCandidates)
                    local part = parts:get(fractureIndex)
                    part:setFractureTime(50.0 + ZombRand(0, 31))
                    part:setAdditionalPain(part:getAdditionalPain() + 35.0)
                end
            end

            body:calculateOverallHealth()
        end

        for _ = 1, 3 do
            local excess = (tonumber(body:getOverallBodyHealth()) or 0) - target
            if excess <= 0.5 then break end
            body:ReduceGeneralHealth(excess)
            body:calculateOverallHealth()
        end

        -- Called last: on a server this engine method ends by syncing every
        -- injury above to the player's client (NetworkPlayerAI:syncDamage() is
        -- not callable from Lua). damageType 0 adds no wound, and zero damage
        -- and pain keep the loss exactly the roll.
        body:applyDamageFromWeapon(0, 0.0, 0, 0.0)
    end)
    if not ok then
        SO.Logger.Error("Failed to apply wrath injuries", { error = tostring(err), damage = damage })
        return false
    end
    return true
end

local function applyMinorWrath(player, damage)
    local body = player and player:getBodyDamage()
    if not body then return false end
    local ok, err = pcall(function()
        body:ReduceGeneralHealth(damage)
        local parts = body:getBodyParts()
        if parts and parts:size() > 0 then
            body:calculateOverallHealth()
            -- NetworkPlayerAI:syncDamage() is not exposed to Lua. damageType 3
            -- is a scratch (B42.20 BodyDamage.applyDamageFromWeapon switch), and
            -- the Java side ends by syncing all injuries to the player's client.
            -- Zero damage keeps the rolled health loss exact; 5 is the pain.
            body:applyDamageFromWeapon(ZombRand(0, parts:size()), 0.0, 3, 5.0)
        else
            body:calculateOverallHealth()
        end
    end)
    if not ok then
        SO.Logger.Error("Failed to apply minor wrath injuries", { error = tostring(err), damage = damage })
        return false
    end
    return true
end

-- Trying to sacrifice your own corpse receives the full wrath wound set plus
-- broken bones and a fixed, severe health deduction.
local function selfCorpseOffering(player, altarPosition, tx, run, endsRitual)
    local damage = 80
    local applied = applyWrath(player, damage, true)
    SO.ZoneService.SendResult(player, SO.RESULT.SELF_CORPSE, SO.TRANSLATION.SELF_CORPSE, {
        tx = tx,
        damage = damage,
        endsRitual = endsRitual == true,
        soundOutcome = SO.SOUND_OUTCOME.FAILURE,
    })
    SO.Logger.EndRun(run, "self-corpse", { damage = damage, applied = tostring(applied) })
end

local function invalidOffering(player, altarPosition, tx, reason, run, endsRitual, soundOutcome, minor,
    greedTranslation)
    local damage = minor and ZombRand(3, 10) or rollWrathDamage()
    local applied = minor and applyMinorWrath(player, damage) or applyWrath(player, damage)
    local translation = minor and SO.TRANSLATION.MINOR_WRATH or SO.TRANSLATION.WRATH
    SO.ZoneService.SendResult(player, SO.RESULT.WRATH, translation, {
        tx = tx,
        damage = damage,
        endsRitual = endsRitual == true,
        soundOutcome = soundOutcome or SO.SOUND_OUTCOME.FAILURE,
        greedTranslation = greedTranslation,
    })
    SO.Logger.EndRun(run, minor and "minor-wrath" or "wrath", {
        reason = reason,
        damage = damage,
        applied = tostring(applied),
    })
end

local function queueWrath(player, zone, altarPosition, tx, reason, run, isSelfCorpse, soundOutcome, minor,
        ritualSmokeStarted)
    if Offerings.PendingWrath[tx] then
        SO.Logger.EndRun(run, "duplicate-awaiting-wrath")
        return true
    end
    local altarKey = tostring(zone.id)
    local greedTranslation
    if reason == "animal-life-cap" or reason == "item-life-cap" then
        greedTranslation = randomGreedTranslation()
    end
    -- Begin() already starts this exact plume for normal button-driven attempts.
    -- Keep the fallback for a late failure discovered only when the channel
    -- completes, but do not stack a second plume that would reveal early wrath.
    if not ritualSmokeStarted then
        broadcastEffect(SO.EFFECT.WRATH_SMOKE, altarPosition, tx)
    end
    Offerings.PendingWrath[tx] = {
        player = player,
        altarPosition = altarPosition,
        altarKey = altarKey,
        tx = tx,
        reason = reason,
        run = run,
        isSelfCorpse = isSelfCorpse == true,
        minor = minor == true,
        greedTranslation = greedTranslation,
        soundOutcome = soundOutcome or SO.SOUND_OUTCOME.FAILURE,
        dueAt = SO.Util.NowMs() + WRATH_SUSPENSE_MS,
    }
    Offerings.PendingWrathByAltar[altarKey] = tx
    SO.Logger.Step(run, ritualSmokeStarted and "wrath-queued" or "wrath-smoke", {
        delayMs = WRATH_SUSPENSE_MS,
        reason = reason,
        greedTranslation = greedTranslation,
    })
    return true
end

function Offerings.ProcessPendingWrath()
    local now = SO.Util.NowMs()
    for tx, pending in pairs(Offerings.PendingWrath) do
        if now >= pending.dueAt then
            -- Clear the lock before resolving so an error cannot strand the altar.
            Offerings.PendingWrath[tx] = nil
            if Offerings.PendingWrathByAltar[pending.altarKey] == tx then
                Offerings.PendingWrathByAltar[pending.altarKey] = nil
            end

            local ok, err = pcall(function()
                if pending.isSelfCorpse then
                    selfCorpseOffering(pending.player, pending.altarPosition, tx, pending.run, true)
                else
                    invalidOffering(pending.player, pending.altarPosition, tx, pending.reason, pending.run, true,
                        pending.soundOutcome, pending.minor, pending.greedTranslation)
                end
            end)
            if not ok then
                SO.Logger.Error("Delayed wrath resolution failed", { tx = tx, error = tostring(err) })
                SO.ZoneService.SendResult(pending.player, SO.RESULT.ERROR, "IGUI_SO_InternalError", {
                    tx = tx,
                    endsRitual = true,
                })
                SO.Logger.EndRun(pending.run, "error", { error = tostring(err) })
            end
        end
    end
end

local function clearRitual(tx)
    local pending = Offerings.PendingRituals[tx]
    if not pending then return nil end
    Offerings.PendingRituals[tx] = nil
    if Offerings.RitualByAltar[pending.altarKey] == tx then Offerings.RitualByAltar[pending.altarKey] = nil end
    return pending
end

-- Deliver wrath committed when the ritual started: consume whatever is on the
-- altar now and punish. `tx` overrides the transaction the result is sent under
-- (so it also ends a newer ritual the same player just started).
local function deliverCommittedWrath(pending, run, tx)
    local zone = SO.Storage.FindZone(pending.zoneId) or { id = pending.zoneId }
    if zone.fixtures then
        local containers = altarContainers(zone)
        local _, nearbyAnimals = snapshotOffering(zone, containers)
        local consumed = consumeAll(containers, nearbyAnimals)
        SO.Logger.Step(run, "consumed", { count = consumed })
    end
    local verdict = pending.verdict
    return queueWrath(pending.player, zone, pending.altarPosition, tx or pending.tx, verdict.reason, run,
        verdict.isSelfCorpse, SO.SOUND_OUTCOME.FAILURE, verdict.minor, true)
end

function Offerings.ProcessPendingRituals()
    local now = SO.Util.NowMs()
    local step = Offerings.lastRitualTickAt
        and math.min(math.max(now - Offerings.lastRitualTickAt, 0), MAX_RITUAL_TICK_STEP_MS) or 0
    Offerings.lastRitualTickAt = now
    for tx, pending in pairs(Offerings.PendingRituals) do
        pending.elapsedMs = pending.elapsedMs + step
        if pending.elapsedMs >= RITUAL_MS + RITUAL_GRACE_MS then
            clearRitual(tx)
            if pending.verdict.valid then
                -- Walked away from a good offering: nothing consumed, nothing redeemed.
                SO.Logger.Debug("Unfinished ritual expired", { tx = tx })
            else
                local run = SO.Logger.BeginRun("offering-abandoned", tx,
                    { player = SO.PlayerLedger.GetIdentity(pending.player) })
                local ok, err = pcall(deliverCommittedWrath, pending, run)
                if not ok then
                    SO.Logger.Error("Abandoned-ritual wrath failed", { tx = tx, error = tostring(err) })
                    SO.Logger.EndRun(run, "error", { error = tostring(err) })
                end
            end
        end
    end
end

-- Judge the offering when the ritual starts -- the moment the player commits
-- while beside the altar -- and start its sounds, but apply nothing: no
-- consumption, no reward, no wrath. The verdict is locked in so changing the altar
-- mid-ritual cannot turn wrath into a reward, and it is delivered only when the
-- channel completes (Make) or, if the player walks away, when it would have.
local function beginOffering(player, args, tx, run)
    local zone, altar = findAltar(args)
    if not zone or not altar then
        SO.Logger.EndRun(run, "ignored-invalid-altar")
        return false
    end
    local altarKey = tostring(zone.id)
    if Offerings.PendingWrathByAltar[altarKey] then
        SO.ZoneService.SendResult(player, SO.RESULT.ERROR, SO.TRANSLATION.BUSY, { tx = tx, endsRitual = true })
        SO.Logger.EndRun(run, "busy-awaiting-wrath")
        return false
    end
    local ritualTx = Offerings.RitualByAltar[altarKey]
    if ritualTx and ritualTx ~= tx then
        local earlier = Offerings.PendingRituals[ritualTx]
        if earlier and earlier.player == player then
            -- The same supplicant restarting after walking away ends the earlier
            -- ritual here; committed wrath is delivered, not escaped.
            clearRitual(ritualTx)
            if not earlier.verdict.valid then
                deliverCommittedWrath(earlier, run, tx)
                return true
            end
        elseif earlier then
            SO.ZoneService.SendResult(player, SO.RESULT.ERROR, SO.TRANSLATION.BUSY, { tx = tx, endsRitual = true })
            SO.Logger.EndRun(run, "busy-ritual-in-progress")
            return false
        else
            Offerings.RitualByAltar[altarKey] = nil
        end
    end
    local altarPosition = zone.fixtures.altar
    if SO.Util.DistanceSquared(player, altarPosition.x, altarPosition.y, altarPosition.z)
        > SO.MAX_INTERACTION_DISTANCE * SO.MAX_INTERACTION_DISTANCE then
        SO.Logger.EndRun(run, "ignored-too-far")
        return false
    end
    if not isCampfireLit(zone) then
        SO.Logger.EndRun(run, "ignored-fire-unlit")
        return false
    end

    local containers = altarContainers(zone)
    local items, nearbyAnimals = snapshotOffering(zone, containers)
    if #items == 0 then
        SO.Logger.EndRun(run, "ignored-empty")
        return false
    end

    -- Every accepted ritual begins behind the same dense smoke omen. Start it
    -- before analyzing the offering so the visual cannot disclose the verdict.
    broadcastEffect(SO.EFFECT.WRATH_SMOKE, altarPosition, tx)
    SO.Logger.Step(run, "ritual-smoke", { itemCount = #items })

    local analysis = analyze(items, player)
    local recoverable, recoveryReason = planRecovery(player, analysis)
    local verdict
    if analysis.valid and recoveryReason == "cap" and (analysis.kind == "animal" or analysis.kind == "item") then
        verdict = { valid = false, reason = analysis.kind .. "-life-cap", minor = analysis.kind == "animal" }
    elseif not analysis.valid then
        verdict = { valid = false, reason = analysis.reason, isSelfCorpse = analysis.reason == "self-corpse" }
    else
        verdict = { valid = true }
    end

    -- The ritual's sounds play from its start and follow the verdict (the
    -- items, reward and punishment still land only when it ends). A valid
    -- offering with nothing to recover keeps a neutral first beat.
    local cue = SO.SOUND_OUTCOME.PENDING
    if not verdict.valid then
        cue = SO.SOUND_OUTCOME.FAILURE
    elseif recoverable then
        cue = analysis.hasPlayerCorpse and SO.SOUND_OUTCOME.PLAYER_CORPSE or SO.SOUND_OUTCOME.SUCCESS_ITEM
    end
    sendSoundCue(player, tx, cue)
    Offerings.PendingRituals[tx] = {
        tx = tx,
        player = player,
        zoneId = zone.id,
        altarKey = altarKey,
        altarPosition = altarPosition,
        verdict = verdict,
        elapsedMs = 0,
    }
    Offerings.RitualByAltar[altarKey] = tx
    SO.Logger.EndRun(run, "committed", {
        valid = tostring(verdict.valid),
        reason = verdict.reason,
        kind = analysis.kind,
        itemCount = #items,
        recoverable = tostring(recoverable),
        recoveryReason = recoveryReason,
    })
    return true
end

local function executeOffering(player, args, tx, run)
    -- A verdict of wrath committed at ritual start is delivered now regardless of
    -- what is on the altar, so emptying it mid-ritual cannot escape it.
    local pending = Offerings.PendingRituals[tx]
    if pending and pending.player == player then
        clearRitual(tx)
        if not pending.verdict.valid then return deliverCommittedWrath(pending, run) end
    end
    local zone, altar = findAltar(args)
    if not zone or not altar then
        SO.ZoneService.SendResult(player, SO.RESULT.ERROR, SO.TRANSLATION.ZONE_INVALID, { tx = tx })
        SO.Logger.EndRun(run, "invalid-altar")
        return false
    end
    local altarPosition = zone.fixtures.altar
    if SO.Util.DistanceSquared(player, altarPosition.x, altarPosition.y, altarPosition.z) > SO.MAX_INTERACTION_DISTANCE * SO.MAX_INTERACTION_DISTANCE then
        SO.ZoneService.SendResult(player, SO.RESULT.ERROR, "IGUI_SO_TooFar", { tx = tx })
        SO.Logger.EndRun(run, "too-far")
        return false
    end
    if not isCampfireLit(zone) then
        SO.ZoneService.SendResult(player, SO.RESULT.ERROR, "IGUI_SO_FireNotLit", { tx = tx })
        SO.Logger.EndRun(run, "fire-unlit")
        return false
    end

    local containers = altarContainers(zone)
    local items, nearbyAnimals = snapshotOffering(zone, containers)
    if #items == 0 then
        SO.ZoneService.SendResult(player, SO.RESULT.ERROR, "IGUI_SO_AltarEmpty", { tx = tx })
        SO.Logger.EndRun(run, "empty")
        return false
    end

    local analysis = analyze(items, player)
    if analysis.valid then
        local recoverable, recoveryReason, targetStrength, creditedStrength = planRecovery(player, analysis)
        if not recoverable then
            if recoveryReason == "cap" and (analysis.kind == "animal" or analysis.kind == "item") then
                local consumed = consumeAll(containers, nearbyAnimals)
                SO.Logger.Step(run, "consumed", { count = consumed })
                return queueWrath(player, zone, altarPosition, tx, analysis.kind .. "-life-cap", run,
                    false, SO.SOUND_OUTCOME.FAILURE, analysis.kind == "animal")
            end
            -- A valid offering with no XP gap or no stronger corpse target is not
            -- consumed. Tier-cap violations above are deliberate exceptions.
            local translation = recoveryReason == "strength" and SO.TRANSLATION.NO_UPGRADE
                or SO.TRANSLATION.NO_RECOVERY
            -- Nothing was taken, so neither the accepted nor the denied beat plays.
            SO.ZoneService.SendResult(player, SO.RESULT.INFO, translation, { tx = tx })
            SO.Logger.EndRun(run, "no-recovery", {
                reason = recoveryReason,
                recoveryStrength = analysis.recoveryStrength,
            })
            return true
        end
        analysis.targetRecoveryStrength = targetStrength
        analysis.creditedRecoveryStrength = creditedStrength
    end
    SO.Logger.Step(run, "verified", {
        valid = tostring(analysis.valid),
        kind = analysis.kind,
        reason = analysis.reason,
        itemCount = #items,
    })

    local consumed = consumeAll(containers, nearbyAnimals)
    SO.Logger.Step(run, "consumed", { count = consumed })
    if not analysis.valid then
        return queueWrath(player, zone, altarPosition, tx, analysis.reason, run,
            analysis.reason == "self-corpse", soundOutcomeFor(analysis))
    end

    local recovered, xpAdded = SO.PlayerLedger.Recover(player,
        analysis.targetRecoveryStrength or analysis.recoveryStrength)
    if not recovered then
        return queueWrath(player, zone, altarPosition, tx, "recovery-race", run, false,
            SO.SOUND_OUTCOME.FAILURE)
    end

    broadcastEffect(SO.EFFECT.FLAME, altarPosition, tx)
    if analysis.kind == "corpse" then
        SO.PlayerLedger.RecordPlayerCorpseSacrifices(player, analysis.corpseVictims)
        local prizesSpawned = spawnPlayerCorpsePrizes(player)
        local translation = prizesSpawned > 0 and SO.TRANSLATION.SUCCESS_CORPSE_PRIZE
            or SO.TRANSLATION.SUCCESS_CORPSE
        SO.ZoneService.SendResult(player, SO.RESULT.SUCCESS_CORPSE, translation, {
            tx = tx,
            recoveryStrength = analysis.targetRecoveryStrength or analysis.recoveryStrength,
            recoveryAddedStrength = analysis.creditedRecoveryStrength,
            xpAdded = xpAdded,
            prizesSpawned = prizesSpawned,
            soundOutcome = SO.SOUND_OUTCOME.PLAYER_CORPSE,
        })
    else
        SO.ZoneService.SendResult(player, SO.RESULT.SUCCESS_ITEM, SO.TRANSLATION.SUCCESS_ITEM, {
            tx = tx,
            recoveryStrength = analysis.targetRecoveryStrength or analysis.recoveryStrength,
            recoveryAddedStrength = analysis.creditedRecoveryStrength,
            xpAdded = xpAdded,
            soundOutcome = SO.SOUND_OUTCOME.SUCCESS_ITEM,
        })
    end
    SO.Logger.EndRun(run, "success", {
        kind = analysis.kind,
        recoveryStrength = analysis.recoveryStrength,
        targetRecoveryStrength = analysis.targetRecoveryStrength,
        creditedRecoveryStrength = analysis.creditedRecoveryStrength,
        baseRecoveryStrength = analysis.baseRecoveryStrength,
        animalCarcassWeight = analysis.animalCarcassWeight
            and string.format("%.3f", analysis.animalCarcassWeight) or nil,
        animalSizeFactor = analysis.animalSizeFactor
            and string.format("%.4f", analysis.animalSizeFactor) or nil,
        quality = analysis.quality and string.format("%.3f", analysis.quality) or nil,
        priorVictimUses = analysis.priorVictimUses,
        xpAdded = string.format("%.2f", xpAdded),
    })
    return true
end

function Offerings.Begin(player, args)
    args = type(args) == "table" and args or {}
    local tx = SO.Util.Trim(args.tx):gsub("[%c]", ""):sub(1, 96)
    if tx == "" then tx = SO.Util.NewTransactionId("offering-begin", player) end
    local run = SO.Logger.BeginRun("offering-begin", tx, { player = SO.PlayerLedger.GetIdentity(player) })
    local ok, result = pcall(beginOffering, player, args, tx, run)
    if not ok then
        SO.Logger.Error("Offering commitment check failed", { tx = tx, error = tostring(result) })
        SO.Logger.EndRun(run, "error", { error = tostring(result) })
        return false
    end
    return result
end

function Offerings.Make(player, args)
    local tx = args and SO.Util.Trim(args.tx):gsub("[%c]", ""):sub(1, 96) or ""
    if tx == "" then tx = SO.Util.NewTransactionId("offering", player) end
    local run = SO.Logger.BeginRun("offering", tx, { player = SO.PlayerLedger.GetIdentity(player) })
    if Offerings.PendingWrath[tx] then
        -- Instant/admin timed actions may complete before the suspense timer.
        -- The queued judgment owns the result and must not be replaced by an
        -- immediate "altar empty" failure.
        SO.Logger.EndRun(run, "awaiting-wrath")
        return true
    end
    -- Both dumpster halves share one lock so simultaneous clicks on opposite
    -- sides cannot consume or reward the same logical offering twice.
    local altarKey = args and tostring(args.zoneId) or "invalid"
    if Offerings.ActiveAltars[altarKey] then
        SO.ZoneService.SendResult(player, SO.RESULT.ERROR, SO.TRANSLATION.BUSY, { tx = tx })
        SO.Logger.EndRun(run, "busy")
        return false
    end
    Offerings.ActiveAltars[altarKey] = tx
    local ok, result = pcall(executeOffering, player, args or {}, tx, run)
    Offerings.ActiveAltars[altarKey] = nil
    if not ok then
        SO.Logger.Error("Offering transaction failed", { tx = tx, error = tostring(result) })
        SO.ZoneService.SendResult(player, SO.RESULT.ERROR, "IGUI_SO_InternalError", { tx = tx })
        SO.Logger.EndRun(run, "error", { error = tostring(result) })
        return false
    end
    return result
end

Events.OnTick.Add(Offerings.ProcessPendingWrath)
Events.OnTick.Add(Offerings.ProcessPendingRituals)

return Offerings
