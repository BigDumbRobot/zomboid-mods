-- KIPN_GovCraftingReference.lua
--
-- Serves GET_CRAFTING_REQUIREMENTS -> the fixed reference ingredient
-- lists shown on the Government Services desk's "See Required Crafting
-- Items" panel. These mirror the recipes in
-- media/scripts/KIPN_GovArtifactRecipes.txt (which are the single
-- source of truth -- crafting is not runtime-configurable).

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.GovCraftingReference = KIPN.Server.GovCraftingReference or {}

local GovCraftingReference = KIPN.Server.GovCraftingReference

-- "tag:pen" is a descriptive label; the real recipe accepts any item
-- carrying a base:pen / bluepen / redpen / greenpen tag.
local REGISTRATION_FORM_ITEMS = {
    { itemType = "Base.SheetPaper2", displayName = "Sheet of Paper", count = 3 },
    { itemType = "tag:pen",          displayName = "Pen (any color)", count = 1 },
    { itemType = "Base.Stapler",     displayName = "Stapler", count = 1 },
    { itemType = "Base.Staples",     displayName = "Staples", count = 2 },
    { itemType = "Base.Paperclip",   displayName = "Paperclip", count = 1 },
}

local function copyList(list)
    local out = {}
    for i, row in ipairs(list) do
        out[i] = {
            itemType = row.itemType,
            displayName = row.displayName,
            count = row.count,
        }
    end
    return out
end

local function handleGetCraftingRequirements(player, _args)
    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.CRAFTING_REQUIREMENTS_DATA,
        {
            property = copyList(REGISTRATION_FORM_ITEMS),
            excavation = copyList(REGISTRATION_FORM_ITEMS),
        }
    )
    return true
end

function GovCraftingReference.Initialize()
    if type(KIPN.Server.RegisterCommandHandler) == "function"
        and type(KIPN.Server.GetCommandHandler) == "function"
        and not KIPN.Server.GetCommandHandler(
            KIPN.Shared.Commands.GET_CRAFTING_REQUIREMENTS
        )
    then
        -- Public: any authenticated player may view the reference list.
        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.GET_CRAFTING_REQUIREMENTS,
            handleGetCraftingRequirements
        )
    end
    return true
end

print("[KIPN] Government Services Crafting Reference loaded")
