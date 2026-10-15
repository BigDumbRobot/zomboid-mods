require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"
require "SacrificialOffering/SO_ClientState"
require "SacrificialOffering/SO_Lightning"

local SO = SacrificialOffering
SO.Effects = SO.Effects or {}
local Effects = SO.Effects

Effects.Active = Effects.Active or {}

-- These are visual IsoFire objects only: they do not use StartFire/StartSmoke,
-- carry no spread state, and are removed locally at expiry. The cluster makes
-- Satan's response envelop the altar without burning the temple -- or anyone
-- standing in it. IsoFire.update() flags its square "burning" while lifeStage
-- < 4 (characters on a burning square catch fire) and calls square:BurnTick()
-- unless the object is smoke. The two-argument constructor starts at stage 0
-- as real fire, and setLifeStage() cannot change that, so every effect uses the
-- smoke constructor (smoke = true, lifeStage 4) whatever animation it shows.
local EFFECT_CONFIG = {
    [SO.EFFECT.FLAME] = {
        durationMs = 12000,
        offsets = {
            { 0, 0 },
            { -1, 0 }, { 1, 0 },
            { 0, -1 }, { 0, 1 },
        },
    },
    [SO.EFFECT.SMOKE] = {
        durationMs = 24000,
        offsets = {
            { 0, 0 },
            { -1, 0 }, { 1, 0 },
            { 0, -1 }, { 0, 1 },
            { -1, -1 }, { 1, -1 },
            { -1, 1 }, { 1, 1 },
        },
    },
    -- Every offering starts here before its outcome is known. Several out-of-
    -- phase smoke animations rise from both dumpster tiles, with lighter spill
    -- around their edges, keeping success and wrath visually indistinguishable.
    [SO.EFFECT.WRATH_SMOKE] = {
        durationMs = 24000,
        offsets = {
            { 0, 0, 6 }, { 0, -1, 6 },
            { -1, 0, 2 }, { 1, 0, 2 },
            { -1, -1, 2 }, { 1, -1, 2 },
            { 0, 1, 2 }, { 0, -2, 2 },
        },
    },
    -- A single short-lived wisp rising from the entranced sacrificer's own tile.
    -- Refreshed on a timer by SO_RitualTrance, so keep it small and brief.
    [SO.EFFECT.TRANCE] = {
        durationMs = 5000,
        offsets = { { 0, 0 } },
    },
}

local function addTransientAnimation(square, effect, expiresAt, startFrame)
    -- (cell, square, canBurnAnywhere, energy, life, smoke): life 0 keeps the
    -- engine's random life; our own expiry removes the object first.
    local object = IsoFire.new(getCell(), square, true, 0, 0, true)
    -- Replace the engine's smoke animation with ours.
    object:RemoveAttachedAnims()
    local animation = effect == SO.EFFECT.FLAME and "Fire" or "Smoke"
    local frames = effect == SO.EFFECT.FLAME and IsoFire.NUM_FRAMES_FIRE or IsoFire.NUM_FRAMES_SMOKE
    object:AttachAnim(animation, "01", frames, IsoFireManager.FIRE_ANIM_DELAY,
        Core.getTileScale(), -Core.getTileScale(), true, startFrame or 0, false, 0.95, IsoFireManager.FIRE_TINT_MOD)
    square:AddTileObject(object)

    table.insert(Effects.Active, {
        object = object,
        square = square,
        expiresAt = expiresAt,
    })
end

function Effects.Play(args)
    if args and args.effect == SO.EFFECT.LIGHTNING then return SO.Lightning.Play(args) end
    if not args or not EFFECT_CONFIG[args.effect] then return end
    local player = getPlayer()
    if player then
        local dx, dy = player:getX() - args.x, player:getY() - args.y
        if dx * dx + dy * dy > 2500 then return end
    end
    local config = EFFECT_CONFIG[args.effect]
    local expiresAt = SO.Util.NowMs() + config.durationMs
    local ok, errorMessage = pcall(function()
        for _, offset in ipairs(config.offsets) do
            local square = getCell():getGridSquare(args.x + offset[1], args.y + offset[2], args.z)
            local layers = offset[3] or 1
            if square then
                for _ = 1, layers do
                   
                    local javaFrameCount = args.effect == SO.EFFECT.FLAME
                        and IsoFire.NUM_FRAMES_FIRE or IsoFire.NUM_FRAMES_SMOKE
                    local frameCount = math.max(1, math.floor(tonumber(tostring(javaFrameCount)) or 1))
                    addTransientAnimation(square, args.effect, expiresAt, ZombRand(0, frameCount))
                end
            end
        end
    end)
    if not ok then SO.Logger.Warn("Could not play altar effect", { effect = args.effect, error = tostring(errorMessage) }) end
end

function Effects.OnTick()
    local now = SO.Util.NowMs()
    for index = #Effects.Active, 1, -1 do
        local active = Effects.Active[index]
        if now >= active.expiresAt or not active.object or active.object:getObjectIndex() == -1 then
            -- Always drop the entry. If its square has streamed out (the player
            -- died or moved away), RemoveTileObject throws on the missing chunk,
            -- and an entry left behind would throw again on every tick. An
            -- unloaded square takes the object with it.
            if active.square and active.object and active.square:getChunk()
                and active.object:getObjectIndex() ~= -1 then
                pcall(function() active.square:RemoveTileObject(active.object) end)
            end
            -- The engine never clears the smoke/burning square flags an IsoFire
            -- sets; leave nothing behind once the visual is gone.
            if active.square and active.square:getChunk() then
                pcall(function()
                    local properties = active.square:getProperties()
                    if properties then
                        properties:unset(IsoFlagType.burning)
                        properties:unset(IsoFlagType.smoke)
                    end
                    active.square:RecalcProperties()
                end)
            end
            table.remove(Effects.Active, index)
        end
    end
end

SO.Client.HandleEffect = Effects.Play
Events.OnTick.Add(Effects.OnTick)

return Effects
