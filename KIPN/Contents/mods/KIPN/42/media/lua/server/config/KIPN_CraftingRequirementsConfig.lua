-- KIPN_CraftingRequirementsConfig.lua
--
-- Terminal keeps only the "Computer Repair Tool" requirement: the set
-- of tool item types a player must carry (any ONE of them) to perform
-- "Repair Computer", checked live by handleRepairComputer in
-- KIPN_Server.lua.
--
-- Every other recipe (Registration Form / Deed / Permit / Title) is
-- now defined purely in each service module's media/scripts and is no
-- longer runtime-configurable -- KIPN configuration is Sandbox-only.

if isClient() and not isServer() then
    return
end

require "KIPN/KIPN_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.CraftingRequirementsConfig =
    KIPN.Server.CraftingRequirementsConfig or {}

local CraftingRequirementsConfig =
    KIPN.Server.CraftingRequirementsConfig

-- Any ONE of these (OR semantics). Exact FullTypes only -- matches the
-- screwdrivers handleDisassembleComputer already requires. Kept, never
-- consumed.
local COMPUTER_REPAIR_TOOLS = {
    "Base.Screwdriver",
    "Base.Screwdriver_Improvised",
    "Base.Screwdriver_Old",
}

function CraftingRequirementsConfig.PlayerHasComputerRepairTool(player)

    local inventory =
        player
        and player.getInventory
        and player:getInventory()

    if not inventory
        or type(inventory.contains) ~= "function"
    then
        return false
    end

    for _, itemType in ipairs(COMPUTER_REPAIR_TOOLS) do
        if inventory:contains(itemType) then
            return true
        end
    end

    return false
end

function CraftingRequirementsConfig.Initialize()
    print(
        "[KIPN CRAFTING REQUIREMENTS CONFIG] " ..
        "Initialized (computer repair tool only)."
    )
    return true
end

print("[KIPN CRAFTING REQUIREMENTS CONFIG] Module loaded.")
