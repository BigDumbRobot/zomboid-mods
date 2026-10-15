require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_CorpseCarryIntegration"
require "Vehicles/TimedActions/ISEnterVehicle"

local SO = SacrificialOffering
local Integration = SO.CorpseCarryIntegration

if Integration.VehicleHookInstalled then return Integration end
if not ISEnterVehicle or type(ISEnterVehicle.start) ~= "function" then return Integration end
Integration.VehicleHookInstalled = true

-- Vehicle entry drops human corpses because their base item has HEAVY_ITEM.
-- Temporarily hide that tag only while vanilla evaluates entry, matching the
-- carriable-animal behavior without weakening other heavy items. This hook must
-- remain client-only: ISEnterVehicle does not exist in SP's server Lua loader.
local vanillaEnterVehicleStart = ISEnterVehicle.start
function ISEnterVehicle:start()
    local item = Integration.CarriedCorpse(self.character)
    local tags = item and item:getTags() or nil
    local restoreHeavyTag = tags ~= nil and item:hasTag(ItemTag.HEAVY_ITEM)
    if restoreHeavyTag then pcall(function() tags:remove(ItemTag.HEAVY_ITEM) end) end

    local ok, result = pcall(vanillaEnterVehicleStart, self)
    if restoreHeavyTag then pcall(function() tags:add(ItemTag.HEAVY_ITEM) end) end
    if not ok then error(result) end
    return result
end

return Integration
