--- Shared settings for Skylights.

local Config = SkylightsConfig or {}

Config.LOG_PREFIX = "[Skylights]"
Config.COMMAND_MODULE = "Skylights"

-- Tile from media/skylights.tiles (mod.info tiledef). The mod ships no texture
-- pack, so SpriteRegistry.lua attaches media/textures/<SPRITE_NAME>.png to it.
Config.SPRITE_NAME = "skylights_01_0"

-- modData key that marks a placed skylight.
Config.MARKER_KEY = "SkylightsProbe"

-- Roof square modData key left by a broken skylight: the open hole lets
-- daylight in, and the square below counts as outdoors, until a floor is built
-- over it.
Config.HOLE_KEY = "SkylightsHole"

-- Lowest z a skylight may be built at (0 would be ground level).
Config.MIN_Z = 1

-- Light under an intact skylight follows the outdoor light on the roof square
-- (day, night, weather) and spreads over LIGHT_RADIUS tiles of the room below.
Config.LIGHT_RADIUS = 5
Config.LIGHT_COLOR = { r = 1.0, g = 0.97, b = 0.9 }

-- Sandbox defaults (media/sandbox-options.txt), used when a value is missing.
Config.DEFAULT_INDOOR_BRIGHTNESS = 80
Config.DEFAULT_BREAK_CHANCE = 20

Config.CRACK_SOUND = "ZombieThumpVehicleWindow"
Config.BREAK_SOUND = "SmashWindow"

local function sandbox(name, default)
    local vars = SandboxVars and SandboxVars.Skylights
    local value = vars and tonumber(vars[name])
    if value == nil then
        return default
    end
    return math.max(0, math.min(100, value))
end

--- Sandbox "Indoor Brightness": 0-100 percent of the outdoor light under a skylight.
function Config.indoorBrightness()
    return sandbox("IndoorBrightness", Config.DEFAULT_INDOOR_BRIGHTNESS)
end

--- Sandbox "Break Chance": 0-100 percent chance per crossing that the glass breaks.
function Config.breakChance()
    return sandbox("BreakChance", Config.DEFAULT_BREAK_CHANCE)
end

--- True where skylight state is decided: the server, or single player.
function Config.isAuthority()
    return not isClient()
end

--- True where the world is rendered: a client, or single player.
function Config.isRenderer()
    return not isServer()
end

SkylightsConfig = Config

return Config
