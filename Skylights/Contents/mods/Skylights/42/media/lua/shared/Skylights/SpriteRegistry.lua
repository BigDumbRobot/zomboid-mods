--- Attaches the skylight texture to its tile sprite.
---
--- media/skylights.tiles defines the sprite (RenderLayer=Floor, attachedFloor,
--- BlockRain). Tile textures normally come from a texture pack; this mod ships
--- a loose PNG instead, loaded by its file path once the tile definitions exist.

local Config = require("Skylights/Config")
local Log = require("Skylights/Logger")

local SpriteRegistry = SkylightsSpriteRegistry or {}

function SpriteRegistry.attachTexture(spriteManager)
    local manager = spriteManager or IsoSpriteManager.instance
    local sprite = manager and manager:getSprite(Config.SPRITE_NAME)
    if sprite == nil then
        Log.warn("SpriteRegistry.attachTexture", "tile sprite missing; is the tiledef loaded?", {
            sprite = Config.SPRITE_NAME,
        })
        return nil
    end
    if not Config.isRenderer() then
        return sprite -- a dedicated server never draws, so it has no texture to attach
    end

    local path = "media/textures/" .. Config.SPRITE_NAME .. ".png"
    local loaded = pcall(function()
        sprite:LoadFramesNoDirPageSimple(path)
    end)
    if not loaded or sprite:hasNoTextures() then
        Log.warn("SpriteRegistry.attachTexture", "texture not attached", { path = path })
    end
    return sprite
end

SkylightsSpriteRegistry = SpriteRegistry

return SpriteRegistry
