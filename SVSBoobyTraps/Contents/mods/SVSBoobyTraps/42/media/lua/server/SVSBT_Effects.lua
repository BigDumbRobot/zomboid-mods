require "SVSBT_Config"

if type(isClient) == "function" and isClient() and not isServer() then
    return
end

SVSBT.Server = SVSBT.Server or {}
SVSBT.Server.Effects = SVSBT.Server.Effects or {}

local Effects = SVSBT.Server.Effects
local Shared = SVSBT.Shared
local Config = SVSBT.Config
local Logger = SVSBT.Logger

local function randomChance(chance)
    chance = math.max(0, math.min(1, tonumber(chance) or 0))
    local roll = type(ZombRandFloat) == "function" and ZombRandFloat(0, 1)
        or (type(ZombRand) == "function" and ZombRand(0, 100000) / 100000 or math.random())
    return roll < chance
end

local function randomRange(minimum, maximum)
    minimum, maximum = tonumber(minimum) or 0, tonumber(maximum) or 0
    if maximum < minimum then minimum, maximum = maximum, minimum end
    if type(ZombRandFloat) == "function" then return ZombRandFloat(minimum, maximum) end
    return minimum + (maximum - minimum) * math.random()
end

local function randomEntry(values)
    if not values or #values == 0 then
        return nil
    end

    local index = type(ZombRand) == "function" and ZombRand(1, #values + 1) or math.random(1, #values)
    return values[index]
end

local function wornItems(player)
    local result = {}

    if not player or not player:getWornItems() then
        return result
    end

    local worn = player:getWornItems()

    for i = 0, worn:size() - 1 do
        local entry = worn:get(i)
        local item = entry and entry:getItem() or nil

        if item then
            result[#result + 1] = item
        end
    end

    return result
end

-- Gendered vanilla pain vocalization (VoiceMale/FemalePainFromLacerate) so a
-- trap victim audibly reacts, the same way they would if a zombie clawed them.
local function screamInPain(character)
    if not character or type(character.playSound) ~= "function" then return end
    local female = type(character.isFemale) == "function" and character:isFemale()
    pcall(character.playSound, character, female and "VoiceFemalePainFromLacerate" or "VoiceMalePainFromLacerate")
end

-- silent suppresses the pain scream for damage that isn't "a trap just got
-- sprung on you" -- e.g. a recurring sickness tick from an already-triggered
-- biological exposure, which would otherwise scream every single tick for
-- the whole illness instead of once at the moment of actual exposure.
local function applyGeneralDamage(character, amount, silent)
    if not character or not character:getBodyDamage() then
        return 0
    end

    local adjusted = math.max(0, tonumber(amount) or 0) * Config.Get("DamageMultiplier")
    character:getBodyDamage():ReduceGeneralHealth(adjusted)

    if adjusted > 0 and not silent and instanceof(character, "IsoPlayer") then
        screamInPain(character)
    end

    return adjusted
end

-- Clamps damage so overallBodyHealth (getOverallBodyHealth/
-- setOverallBodyHealth/ReduceGeneralHealth all share the same 0-100 field)
-- never crosses below `floor` -- used
-- for anthrax specifically, which should make a player sick, never kill
-- them outright the way a bear trap or shotgun blast legitimately can.
local function applyNonLethalDamage(character, amount, floor)
    if not character or not character:getBodyDamage() then
        return 0
    end

    local bodyDamage = character:getBodyDamage()
    local current = type(bodyDamage.getOverallBodyHealth) == "function"
        and bodyDamage:getOverallBodyHealth() or 100
    local adjusted = math.max(0, tonumber(amount) or 0) * Config.Get("DamageMultiplier")
    local allowed = math.max(0, current - (tonumber(floor) or 5))
    local applied = math.min(adjusted, allowed)

    if applied > 0 then
        bodyDamage:ReduceGeneralHealth(applied)
    end

    return applied
end

local function bodyPart(character, bodyPartType)
    if not character or not character:getBodyDamage() or not bodyPartType then
        return nil
    end

    return character:getBodyDamage():getBodyPart(bodyPartType)
end

local function addLaceration(part, deepChance, lacerationChance)
    if not part then
        return
    end

    if randomChance(deepChance) and type(part.generateDeepWound) == "function" then
        part:generateDeepWound()
        part:setBleedingTime(math.max(part:getBleedingTime(), 20))
    elseif randomChance(lacerationChance) then
        part:setCut(true)
        part:setBleedingTime(math.max(part:getBleedingTime(), 12))
    else
        part:setScratched(true, false)
        part:setBleedingTime(math.max(part:getBleedingTime(), 5))
    end
end

function Effects.PlaySound(soundName, square, radius, volume)
    local run = Logger.Begin("Effects.PlaySound", soundName)
    local played = false

    if square and type(playServerSound) == "function" then
        local ok = pcall(playServerSound, soundName, square)
        played = ok
    elseif square and type(square.playSound) == "function" then
        local ok = pcall(function() square:playSound(soundName) end)
        played = ok
    end

    if square and type(addSound) == "function" and (tonumber(radius) or 0) > 0 then
        pcall(addSound, nil, square:getX(), square:getY(), square:getZ(),
            math.floor(tonumber(radius) or 0), math.floor(tonumber(volume) or 100))
    end

    Logger.Finish(run, played, "played=" .. tostring(played))
    return played
end

-- Every mod sound family (media/scripts/SVSBT_Sounds.txt, clips in
-- media/sound). The SERVER picks which clip of a family plays, so everyone in
-- earshot hears the same one for the same event rather than each client
-- rolling its own -- and because these all go out through Effects.PlaySound,
-- each one also lays down a world sound that nearby zombies will come and
-- investigate.
local SoundFamilies = {
    -- A trap was successfully set, or a set trap went off.
    success = { prefix = "SVSBT_Success", count = 5 },
    -- Somebody is searching for traps, and how the search ended.
    search = { prefix = "SVSBT_TrapSearch", count = 3 },
    found = { prefix = "SVSBT_TrapFound", count = 3 },
    notFound = { prefix = "SVSBT_TrapNotFound", count = 3 },
}

function Effects.PlayRandomSound(family, square, enabledSetting, radiusSetting, volumeSetting)
    local run = Logger.Begin("Effects.PlayRandomSound", family)
    local entry = SoundFamilies[family]

    if not entry then
        Logger.Finish(run, false, "UNKNOWN_SOUND_FAMILY")
        return false
    end

    if not square then
        Logger.Finish(run, false, "SQUARE_REQUIRED")
        return false
    end

    if not Config.Get(enabledSetting) then
        Logger.Finish(run, false, "disabled")
        return false
    end

    local index = math.floor(randomRange(1, entry.count + 1))
    local name = entry.prefix .. tostring(math.max(1, math.min(entry.count, index)))
    local played = Effects.PlaySound(name, square, Config.Get(radiusSetting), Config.Get(volumeSetting))
    Logger.Finish(run, played, name)
    return played
end

function Effects.PlayTrapSetSound(square)
    return Effects.PlayRandomSound("success", square,
        "TrapSetSoundEnabled", "TrapSetSoundRadiusTiles", "TrapSetSoundVolume")
end

-- Same five clips as a successful set, sounded from the trap's own tile when
-- it goes off, so the noise comes from where the trap actually is rather than
-- from whoever tripped it.
function Effects.PlayTrapDetonationSound(square)
    return Effects.PlayRandomSound("success", square,
        "TrapDetonationSoundEnabled", "TrapDetonationSoundRadiusTiles", "TrapDetonationSoundVolume")
end

-- stage is "search" (the hunt is under way), "found", or "notFound".
function Effects.PlayInspectionSound(stage, square)
    return Effects.PlayRandomSound(stage, square,
        "InspectionSoundsEnabled", "InspectionSoundRadiusTiles", "InspectionSoundVolume")
end

function Effects.WetPlayer(player)
    local run = Logger.Begin("Effects.WetPlayer", Shared.Username(player))

    if not player then
        Logger.Finish(run, false, "PLAYER_REQUIRED")
        return false
    end

    local wetness = Config.Get("WaterBucketWetness")
    local clothingWetness = Config.Get("WaterBucketClothingWetness")
    local stats = player:getStats()

    if stats and CharacterStat and CharacterStat.WETNESS then
        local maximum = CharacterStat.WETNESS:getMaximumValue()
        stats:set(CharacterStat.WETNESS, math.min(maximum, wetness))
    end

    if player:getBodyDamage() and player:getBodyDamage():getBodyParts() then
        local parts = player:getBodyDamage():getBodyParts()

        for i = 0, parts:size() - 1 do
            parts:get(i):setWetness(wetness)
        end
    end

    -- A dumped bucket soaks straight through -- unlike rain building up
    -- gradually, water resistance shouldn't blunt a direct dousing, so every
    -- worn item goes straight to WaterBucketClothingWetness (100 by
    -- default), full stop.
    for _, item in ipairs(wornItems(player)) do
        if type(item.setWetness) == "function" then
            item:setWetness(clothingWetness)
        end
    end

    local damage = applyGeneralDamage(player, Config.Get("WaterBucketDamage"))
    -- A dropped bucket/rope rig should sting -- a shallow scratch across the
    -- scalp, not a serious wound.
    addLaceration(bodyPart(player, BodyPartType.Head), 0.02, 0.35)
    Effects.PlaySound("WashClothing", player:getSquare(), 15, 30)
    Logger.Finish(run, true, "wetness=" .. tostring(wetness) .. " | damage=" .. tostring(damage))
    return true
end

-- A shotgun rigged behind a door catches whoever opens it from the trapped
-- side at close range -- a real, localized blast to the torso (BodyPart:
-- ReduceHealth, same verified API as the bear trap) rather than generic
-- health loss, with pellet spread lacerating nearby parts too.
function Effects.TriggerShotgun(target)
    local run = Logger.Begin("Effects.TriggerShotgun")

    if instanceof(target, "IsoZombie") or instanceof(target, "IsoAnimal") then
        local damage = math.max(0, Config.Get("ShotgunDoorDamage") * Config.Get("DamageMultiplier") / 40)
        target:setHealth(math.max(0, target:getHealth() - damage))
        -- Lowering health alone leaves a zombie standing in multiplayer.
        if target:getHealth() <= 0 and type(target.Kill) == "function" and not target:isDead() then target:Kill(nil) end
        Effects.PlaySound("DoubleBarrelShotgunShoot", target:getSquare(), 60, 100)
        Logger.Finish(run, true, "creatureDamage=" .. tostring(damage))
        return true
    end

    if instanceof(target, "IsoPlayer") then
        local torso = bodyPart(target, BodyPartType.Torso_Upper)
        local damage = math.max(0, Config.Get("ShotgunDoorDamage") * Config.Get("DamageMultiplier"))

        if torso and type(torso.ReduceHealth) == "function" then
            torso:ReduceHealth(damage)
        else
            applyGeneralDamage(target, Config.Get("ShotgunDoorDamage"))
        end

        addLaceration(torso, Config.Get("ShotgunDoorDeepWoundChance"), Config.Get("ShotgunDoorLacerationChance"))

        for _, partType in ipairs({ BodyPartType.ForeArm_L, BodyPartType.ForeArm_R }) do
            if randomChance(0.5) then
                addLaceration(bodyPart(target, partType), Config.Get("ShotgunDoorDeepWoundChance") * 0.5, 0.7)
            end
        end

        screamInPain(target)
        Effects.PlaySound("DoubleBarrelShotgunShoot", target:getSquare(), 60, 100)
        Logger.Finish(run, true, "playerDamage=" .. tostring(damage))
        return true
    end

    Logger.Finish(run, false, "UNSUPPORTED_TARGET")
    return false
end

function Effects.DamageFootwear(player)
    local run = Logger.Begin("Effects.DamageFootwear", Shared.Username(player))
    local protection = 0
    local damaged = false

    for _, item in ipairs(wornItems(player)) do
        local name = string.lower(tostring(item:getFullType() or ""))

        if string.find(name, "shoe", 1, true) or string.find(name, "boot", 1, true) then
            protection = Config.Get("NailBoardFootwearProtection")

            if type(item.getCondition) == "function" and type(item.setCondition) == "function" then
                item:setCondition(math.max(0, item:getCondition() - Config.Get("NailBoardFootwearDamage")))
                damaged = true
            end

            break
        end
    end

    Logger.Finish(run, true, "protection=" .. tostring(protection) .. " | damaged=" .. tostring(damaged))
    return protection
end

function Effects.TriggerNailBoard(target)
    local run = Logger.Begin("Effects.TriggerNailBoard")
    local baseDamage = Config.Get("NailBoardBaseDamage")

    if instanceof(target, "IsoZombie") or instanceof(target, "IsoAnimal") then
        local damage = math.max(0, baseDamage * Config.Get("DamageMultiplier") / 100)
        target:setHealth(math.max(0, target:getHealth() - damage))
        Logger.Finish(run, true, "creatureDamage=" .. tostring(damage))
        return true
    end

    if instanceof(target, "IsoPlayer") then
        local protection = Effects.DamageFootwear(target)
        local damage = baseDamage * (1 - protection)
        local partType = randomEntry({ BodyPartType.Foot_L, BodyPartType.Foot_R })
        local part = bodyPart(target, partType)
        applyGeneralDamage(target, damage)
        addLaceration(part, 0.10, Config.Get("NailBoardLacerationChance"))
        Effects.PlaySound("PZ_MetalSnap", target:getSquare(), 15, 25)
        Logger.Finish(run, true, "playerDamage=" .. tostring(damage))
        return true
    end

    Logger.Finish(run, false, "UNSUPPORTED_TARGET")
    return false
end

-- A vehicle rolling over a shotgun trap takes the blast in its front end:
-- a front tire and two more of its front parts, each losing the trap's
-- damage (half of it at the default 100).
local SHOTGUN_VEHICLE_PARTS = { "Windshield", "EngineDoor", "HeadlightLeft", "HeadlightRight", "Engine" }

function Effects.ShotgunVehicle(vehicle)
    local run = Logger.Begin("Effects.ShotgunVehicle")
    if not vehicle then
        Logger.Finish(run, false, "NO_VEHICLE")
        return false
    end
    local loss = math.max(0, Config.Get("ShotgunDoorDamage") * Config.Get("DamageMultiplier") * 0.5)
    local function roll(n) return type(ZombRand) == "function" and ZombRand(n) or math.random(0, n - 1) end
    local ids = { roll(2) == 0 and "TireFrontLeft" or "TireFrontRight" }
    local pool = {}
    for _, id in ipairs(SHOTGUN_VEHICLE_PARTS) do pool[#pool + 1] = id end
    for _ = 1, 2 do ids[#ids + 1] = table.remove(pool, roll(#pool) + 1) end
    local damaged = 0
    for _, id in ipairs(ids) do
        local part = vehicle:getPartById(id)
        if part then
            part:setCondition(math.max(0, part:getCondition() - loss))
            if type(vehicle.transmitPartCondition) == "function" then vehicle:transmitPartCondition(part) end
            damaged = damaged + 1
        end
    end
    Effects.PlaySound("DoubleBarrelShotgunShoot", vehicle:getSquare(), 60, 100)
    Logger.Finish(run, damaged > 0, "parts=" .. damaged .. " | loss=" .. tostring(loss))
    return damaged > 0
end

function Effects.DamageVehicleTire(vehicle)
    local run = Logger.Begin("Effects.DamageVehicleTire")

    if not vehicle or not Config.Get("NailBoardDamagesTires") then
        Logger.Finish(run, false, "DISABLED_OR_NO_VEHICLE")
        return false
    end

    local candidates = { "TireFrontLeft", "TireFrontRight", "TireRearLeft", "TireRearRight" }
    local start = type(ZombRand) == "function" and ZombRand(1, #candidates + 1) or math.random(1, #candidates)
    local damaged = false

    for offset = 0, #candidates - 1 do
        local id = candidates[((start + offset - 1) % #candidates) + 1]
        local part = vehicle:getPartById(id)

        if part then
            part:setCondition(math.max(0, part:getCondition() - Config.Get("NailBoardTireDamage")))

            if type(vehicle.transmitPartCondition) == "function" then
                vehicle:transmitPartCondition(part)
            end

            damaged = true
            break
        end
    end

    Logger.Finish(run, damaged, "damaged=" .. tostring(damaged))
    return damaged
end

function Effects.TriggerBearTrap(target)
    local run = Logger.Begin("Effects.TriggerBearTrap")
    local baseDamage = Config.Get("BearTrapBaseDamage")

    if instanceof(target, "IsoZombie") or instanceof(target, "IsoAnimal") then
        local damage = math.max(0, baseDamage * Config.Get("DamageMultiplier") / 75)
        if instanceof(target, "IsoAnimal") then
            damage = math.max(damage, target:getHealth() * 0.70 * Config.Get("DamageMultiplier"))
        end
        target:setHealth(math.max(0, target:getHealth() - damage))
        if type(target.sendExtraUpdateToClients) == "function" then target:sendExtraUpdateToClients() end
        Logger.Finish(run, true, "creatureDamage=" .. tostring(damage))
        return true
    end

    if instanceof(target, "IsoPlayer") then
        local partType = randomEntry({
            BodyPartType.Foot_L, BodyPartType.Foot_R,
            BodyPartType.LowerLeg_L, BodyPartType.LowerLeg_R,
        })
        local part = bodyPart(target, partType)
        -- Jaws close on one leg/foot -- damage that specific part directly
        -- (BodyPart:ReduceHealth) rather than the character's general health
        -- pool, so it's always that leg that's hurt, never anywhere else.
        local damage = math.max(0, baseDamage * Config.Get("DamageMultiplier"))
        if part and type(part.ReduceHealth) == "function" then
            part:ReduceHealth(damage)
        else
            applyGeneralDamage(target, baseDamage)
        end
        screamInPain(target)
        addLaceration(part, 0.35, 0.95)

        -- Guaranteed, not chance-based: jaws locked around the leg means it's
        -- genuinely fractured while caught. calculateInjurySpeed/
        -- getFootInjurySpeedModifier (real IsoGameCharacter movement code)
        -- read fracture state directly, so this -- not a made-up speed
        -- multiplier -- is what actually makes movement slow and difficult.
        if part then
            part:setFractureTime(math.max(part:getFractureTime(), 100))
        end

        Effects.PlaySound("PZ_MetalSnap", target:getSquare(), 25, 50)
        Logger.Finish(run, true, "playerDamage=" .. tostring(baseDamage))
        return true
    end

    Logger.Finish(run, false, "UNSUPPORTED_TARGET")
    return false
end

function Effects.BearTrapEscapeInjury(player)
    local run = Logger.Begin("Effects.BearTrapEscapeInjury", Shared.Username(player))

    if not player then
        Logger.Finish(run, false, "PLAYER_REQUIRED")
        return 0
    end

    local damage = Config.Get("BearTrapEscapeDamage")
    applyGeneralDamage(player, damage)

    for _, partType in ipairs({ BodyPartType.LowerLeg_L, BodyPartType.LowerLeg_R }) do
        local part = bodyPart(player, partType)

        if part then
            if type(part.generateDeepWound) == "function" then part:generateDeepWound() end
            part:setBleedingTime(math.max(part:getBleedingTime(), 30))
            if type(part.setFractureTime) == "function" then
                part:setFractureTime(math.max(part:getFractureTime(), 25))
            end
        end
    end

    Effects.PlaySound("PZ_MetalSnap", player:getSquare(), 25, 50)
    Logger.Finish(run, true, "damage=" .. tostring(damage))
    return damage
end

function Effects.InjureSettingArm(player, severity)
    local run = Logger.Begin("Effects.InjureSettingArm", Shared.Username(player))
    local partType = randomEntry({
        BodyPartType.Hand_L, BodyPartType.Hand_R,
        BodyPartType.ForeArm_L, BodyPartType.ForeArm_R,
        BodyPartType.UpperArm_L, BodyPartType.UpperArm_R,
    })
    local part = bodyPart(player, partType)
    local damage = math.max(4, tonumber(severity) or 10)

    applyGeneralDamage(player, damage)
    addLaceration(part, 0.18, 0.85)
    Effects.PlaySound("PZ_MetalSnap", player and player:getSquare() or nil, 15, 30)
    Logger.Finish(run, part ~= nil, "damage=" .. tostring(damage))
    return part ~= nil
end

function Effects.ExplosionWounds(character, damage, distanceBand)
    local run = Logger.Begin("Effects.ExplosionWounds", distanceBand)

    if not character or not character:getBodyDamage() then
        Logger.Finish(run, false, "CHARACTER_REQUIRED")
        return false
    end

    applyGeneralDamage(character, damage)
    local count = distanceBand == "inner" and 3 or (distanceBand == "middle" and 2 or 1)
    local parts = {
        BodyPartType.Head, BodyPartType.Torso_Upper, BodyPartType.Torso_Lower,
        BodyPartType.ForeArm_L, BodyPartType.ForeArm_R,
        BodyPartType.UpperLeg_L, BodyPartType.UpperLeg_R,
        BodyPartType.LowerLeg_L, BodyPartType.LowerLeg_R,
    }

    for _ = 1, count do
        addLaceration(bodyPart(character, randomEntry(parts)),
            Config.Get("ExplosiveDeepWoundChance"), Config.Get("ExplosiveLacerationChance"))
    end

    Logger.Finish(run, true, "damage=" .. tostring(damage) .. " | wounds=" .. tostring(count))
    return true
end

function Effects.TriggerExplosion(x, y, z, sourceObject, canHarmPlayer, forceFire, trapRecord)
    local run = Logger.Begin("Effects.TriggerExplosion", tostring(x) .. "," .. tostring(y) .. "," .. tostring(z))
    local square = getCell() and getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z)) or nil

    if not square then
        Logger.Finish(run, false, "SQUARE_NOT_LOADED")
        return false
    end

    Effects.PlaySound("BigExplosion", square, Config.Get("ExplosiveSoundRadiusTiles"), 100)
    local inner = Config.Get("ExplosiveInnerRadiusTiles")
    local middle = math.max(inner, Config.Get("ExplosiveMiddleRadiusTiles"))
    local outer = math.max(middle, Config.Get("ExplosiveOuterRadiusTiles"))
    local affected = 0

    for _, player in ipairs(Shared.Players()) do
        local sameFloor = math.floor(tonumber(player:getZ()) or -99) == math.floor(tonumber(z) or -98)
        local distance = Shared.Distance(x, y, player:getX(), player:getY())

        if sameFloor and distance <= outer and (not canHarmPlayer or canHarmPlayer(player)) then
            local damage = Config.Get("ExplosiveOuterDamage")
            local band = "outer"

            if distance <= inner then
                damage = Config.Get("ExplosiveInnerDamage")
                band = "inner"
            elseif distance <= middle then
                damage = Config.Get("ExplosiveMiddleDamage")
                band = "middle"
            end

            if trapRecord then
                SVSBT.Server.Combat.Apply(trapRecord, player, Effects.ExplosionWounds, damage, band)
            else
                Effects.ExplosionWounds(player, damage, band)
            end
            affected = affected + 1
        end
    end

    for sx = math.floor(x - outer), math.floor(x + outer) do
        for sy = math.floor(y - outer), math.floor(y + outer) do
            local targetSquare = getCell():getGridSquare(sx, sy, math.floor(z))

            if targetSquare and Shared.Distance(x, y, sx, sy) <= outer then
                local movers = targetSquare:getMovingObjects()

                for i = 0, movers:size() - 1 do
                    local mover = movers:get(i)

                    if (instanceof(mover, "IsoZombie") or instanceof(mover, "IsoAnimal")) then
                        local distance = Shared.Distance(x, y, mover:getX(), mover:getY())
                        local damage = distance <= inner and Config.Get("ExplosiveInnerDamage")
                            or (distance <= middle and Config.Get("ExplosiveMiddleDamage") or Config.Get("ExplosiveOuterDamage"))
                        mover:setHealth(math.max(0, mover:getHealth() - (damage * Config.Get("DamageMultiplier") / 60)))
                        affected = affected + 1
                    end
                end
            end
        end
    end

    if sourceObject and Config.Get("ExplosiveDestroysMailboxContents")
        and type(sourceObject.getContainer) == "function" and sourceObject:getContainer() then
        sourceObject:getContainer():clear()
    end

    local igniteChance = math.max(Config.Get("ExplosiveFireChance"), forceFire == true and 1 or 0)
    if igniteChance > 0 and randomChance(igniteChance)
        and IsoFireManager and type(IsoFireManager.StartFire) == "function" then
        pcall(IsoFireManager.StartFire, getCell(), square, true, forceFire == true and 100 or 50)
        if trapRecord then SVSBT.Server.Combat.TrackFire(trapRecord, square) end
        for _, offset in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            if forceFire == true then
                local near = getCell():getGridSquare(math.floor(x) + offset[1], math.floor(y) + offset[2], math.floor(z))
                if near and randomChance(0.5) then
                    pcall(IsoFireManager.StartFire, getCell(), near, true, 60)
                    if trapRecord then SVSBT.Server.Combat.TrackFire(trapRecord, near) end
                end
            end
        end
    end

    Logger.Finish(run, true, "affected=" .. tostring(affected))
    return true
end

function Effects.ApplyDye(player)
    local run = Logger.Begin("Effects.ApplyDye", Shared.Username(player))

    if not player then
        Logger.Finish(run, false, "PLAYER_REQUIRED")
        return false
    end

    local dirtiness = Config.Get("DyeClothingDirtiness")

    -- Dirtiness and clothing blood level alone are subtle during normal
    -- play (and clothing blood level only renders on the clothing itself,
    -- never on exposed skin). Light, visible scratches on exposed body
    -- parts -- the same mechanism every other trap in this mod already uses
    -- for genuinely visible blood -- makes the driver actually look
    -- soaked, not just carry a hidden dirtiness flag. This is a paint/dye
    -- charge, not a weapon: randomized damage in a modest range, and never
    -- anything past a scratch (no cuts, no deep wounds).
    applyGeneralDamage(player, randomRange(Config.Get("DyeDamageMin"), Config.Get("DyeDamageMax")))
    for _, partType in ipairs({
        BodyPartType.Head, BodyPartType.Neck, BodyPartType.Torso_Upper,
        BodyPartType.ForeArm_L, BodyPartType.ForeArm_R,
        BodyPartType.Hand_L, BodyPartType.Hand_R,
    }) do
        local part = bodyPart(player, partType)
        if part then
            part:setScratched(true, false)
            part:setBleedingTime(math.max(part:getBleedingTime(), 5))
        end
    end

    for _, item in ipairs(wornItems(player)) do
        if type(item.setDirtiness) == "function" then
            item:setDirtiness(math.max(tonumber(item:getDirtiness()) or 0, dirtiness))
        end
        if type(item.setBloodLevel) == "function" then
            item:setBloodLevel(1.0)
        end
    end

    local data = player:getModData()
    data.SVSBT_DyeMarkedUntil = Shared.WorldAgeHours() + (Config.Get("DyeDurationDays") * 24)

    -- A muffled shot from the seat, then a burst of smoke -- the mechanism
    -- that fires the dye/blood charge, not just a paint can.
    Effects.PlaySound("PistolShoot", player:getSquare(), 15, 40)
    Effects.PlaySound("SmokeBombExplode", player:getSquare(), 15, 40)

    if type(player.transmitModData) == "function" then
        player:transmitModData()
    end

    Logger.Finish(run, true, "until=" .. tostring(data.SVSBT_DyeMarkedUntil))
    return true
end

function Effects.BiologicalProtection(player)
    local run = Logger.Begin("Effects.BiologicalProtection", Shared.Username(player))
    local mask = false
    local gloves = false

    for _, item in ipairs(wornItems(player)) do
        local fullType = string.lower(tostring(item:getFullType() or ""))
        local bodyLocation = type(item.getBodyLocation) == "function" and string.lower(tostring(item:getBodyLocation() or "")) or ""

        if string.find(fullType, "mask", 1, true) or string.find(fullType, "respirator", 1, true)
            or string.find(bodyLocation, "mask", 1, true) then
            mask = true
        end

        if string.find(fullType, "glove", 1, true) or string.find(bodyLocation, "hand", 1, true) then
            gloves = true
        end
    end

    local factor = 1

    if mask then factor = factor * (1 - Config.Get("AnthraxMaskProtection")) end
    if gloves then factor = factor * (1 - Config.Get("AnthraxGloveProtection")) end

    local antibioticPower = type(player.getReduceInfectionPower) == "function"
        and math.max(0, math.min(1, tonumber(player:getReduceInfectionPower()) or 0)) or 0
    factor = factor * (1 - (Config.Get("AnthraxAntibioticProtection") * antibioticPower))
    factor = math.max(0.05, math.min(1, factor))

    Logger.Finish(run, true, "factor=" .. tostring(factor) .. " | mask=" .. tostring(mask) .. " | gloves=" .. tostring(gloves))
    return factor
end

-- Total damage is a fixed budget (AnthraxTotalDamage) spread evenly across
-- every tick of the full exposure window -- not a separate upfront lump plus
-- an unrelated per-tick rate.
-- Only the REMAINDER after the initial lump is spread across the rest of
-- the illness -- AnthraxTotalDamage is the grand total (initial + gradual).
local function anthraxDamagePerTick()
    local totalTicks = math.max(1, math.floor((Config.Get("AnthraxDurationHours") * 3600) / Config.Get("AnthraxTickSeconds")))
    local gradual = math.max(0, Config.Get("AnthraxTotalDamage") - Config.Get("AnthraxInitialDamage"))
    return gradual / totalTicks
end

-- Gendered vanilla cough cue (VoiceMale/FemaleCough). The very first exposure always
-- coughs (that's the "something is wrong" tell); the ongoing illness cough
-- or sneeze at random so it doesn't feel like a metronome.
local function cough(player)
    if not player or type(player.playSound) ~= "function" then return end
    local female = type(player.isFemale) == "function" and player:isFemale()
    pcall(player.playSound, player, female and "VoiceFemaleCough" or "VoiceMaleCough")
end

local function coughOrSneeze(player)
    if not player or type(player.playSound) ~= "function" then return end
    local female = type(player.isFemale) == "function" and player:isFemale()
    local name = randomChance(0.5)
        and (female and "VoiceFemaleCough" or "VoiceMaleCough")
        or (female and "VoiceFemaleSneezeLight" or "VoiceMaleSneezeLight")
    pcall(player.playSound, player, name)
end

function Effects.BeginBiologicalExposure(player)
    local run = Logger.Begin("Effects.BeginBiologicalExposure", Shared.Username(player))
    local factor = Effects.BiologicalProtection(player)
    -- This is the actual "a trap just got sprung on you" moment for this
    -- kind -- the one-time reaction belongs here, not on every recurring
    -- sickness tick afterward (see TickBiologicalExposure's silent damage).
    screamInPain(player)
    cough(player)
    applyNonLethalDamage(player, Config.Get("AnthraxInitialDamage") * factor, Config.Get("AnthraxNeverLethalFloor"))

    if player and player:getStats() and CharacterStat and CharacterStat.SICKNESS then
        local stats = player:getStats()
        local maximum = CharacterStat.SICKNESS:getMaximumValue()
        stats:set(CharacterStat.SICKNESS,
            math.min(maximum, stats:get(CharacterStat.SICKNESS) + (0.18 * factor)))
    end

    Logger.Finish(run, true, "factor=" .. tostring(factor) .. " | totalDamageOverTime=" .. tostring(Config.Get("AnthraxTotalDamage")))
    return factor
end

function Effects.TickBiologicalExposure(player, factor)
    local run = Logger.Begin("Effects.TickBiologicalExposure", Shared.Username(player))

    if not player then
        Logger.Finish(run, false, "PLAYER_REQUIRED")
        return false
    end

    factor = math.max(0.05, math.min(1, tonumber(factor) or 1))
    local currentProtection = Effects.BiologicalProtection(player)
    factor = math.min(factor, currentProtection)
    applyNonLethalDamage(player, anthraxDamagePerTick() * factor, Config.Get("AnthraxNeverLethalFloor"))
    coughOrSneeze(player)

    if player:getStats() and CharacterStat then
        local stats = player:getStats()

        if CharacterStat.SICKNESS then
            local maxSickness = CharacterStat.SICKNESS:getMaximumValue()
            stats:set(CharacterStat.SICKNESS, math.min(maxSickness,
                stats:get(CharacterStat.SICKNESS) + (Config.Get("AnthraxSicknessPerTick") * factor)))
        end

        if CharacterStat.FOOD_SICKNESS then
            local maxFoodSickness = CharacterStat.FOOD_SICKNESS:getMaximumValue()
            stats:set(CharacterStat.FOOD_SICKNESS, math.min(maxFoodSickness,
                stats:get(CharacterStat.FOOD_SICKNESS) + (Config.Get("AnthraxSicknessPerTick") * 20 * factor)))
        end
    end

    Logger.Finish(run, true, "factor=" .. tostring(factor))
    return true
end

function Effects.DamageVehicleEngine(vehicle, amount)
    local run = Logger.Begin("Effects.DamageVehicleEngine")
    local part = vehicle and vehicle:getPartById("Engine") or nil

    if not part then
        Logger.Finish(run, false, "ENGINE_PART_NOT_FOUND")
        return false
    end

    part:setCondition(math.max(0, part:getCondition() - math.floor(tonumber(amount) or 0)))

    if type(vehicle.transmitPartCondition) == "function" then
        vehicle:transmitPartCondition(part)
    end

    Logger.Finish(run, true, "condition=" .. tostring(part:getCondition()))
    return true
end

Logger.Info("SVSBT_Effects.load", "server-side trap effects initialized")

return Effects
