--- Shared bootstrap: attaches the skylight texture once tile definitions have
--- loaded, and loads the daylight and glass modules.

local Log = require("Skylights/Logger")
local SpriteRegistry = require("Skylights/SpriteRegistry")
require("Skylights/Daylight")
require("Skylights/Glass")

local Bootstrap = {}

function Bootstrap.onLoadedTileDefinitions(spriteManager)
    Log.time("SharedBootstrap.onLoadedTileDefinitions", SpriteRegistry.attachTexture, spriteManager)
end

if not SkylightsSharedBootstrapRegistered then
    SkylightsSharedBootstrapRegistered = true
    Events.OnLoadedTileDefinitions.Add(Bootstrap.onLoadedTileDefinitions)
end

return Bootstrap
