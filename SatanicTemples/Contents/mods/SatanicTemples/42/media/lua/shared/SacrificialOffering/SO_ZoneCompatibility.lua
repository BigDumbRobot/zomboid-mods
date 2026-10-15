require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"

local SO = SacrificialOffering
SO.ZoneCompatibility = SO.ZoneCompatibility or {}
local Compatibility = SO.ZoneCompatibility

Compatibility.Providers = Compatibility.Providers or {}
Compatibility.TempleProvider = Compatibility.TempleProvider or nil

-- Neutral, opt-in API for managed-zone mods. No specific third-party mod is read,
-- required, or patched by Satanic Temples.
function Compatibility.RegisterProvider(id, provider)
    id = SO.Util.Trim(id)
    if id == "" or type(provider) ~= "table" then return false end
    if type(provider.GetZones) ~= "function" and type(provider.Intersects) ~= "function" then return false end
    Compatibility.Providers[id] = provider
    SO.Logger.Info("Registered managed-zone compatibility provider", { provider = id })
    return true
end

function Compatibility.UnregisterProvider(id)
    if Compatibility.Providers[id] == nil then return false end
    Compatibility.Providers[id] = nil
    SO.Logger.Info("Unregistered managed-zone compatibility provider", { provider = id })
    return true
end

function Compatibility.SetTempleProvider(provider)
    Compatibility.TempleProvider = provider
end

local function normalizeProviderZone(zone)
    if type(zone) ~= "table" then return nil end
    return SO.Util.NormalizeRect(zone.x1 or zone.x, zone.y1 or zone.y,
        zone.x2 or (zone.x and zone.w and zone.x + zone.w),
        zone.y2 or (zone.y and zone.h and zone.y + zone.h))
end

function Compatibility.CheckExternalOverlap(rect, ignoreProviderId)
    for id, provider in pairs(Compatibility.Providers) do
        if id ~= ignoreProviderId then
            local ok, result = pcall(function()
                if type(provider.Intersects) == "function" then
                    return provider.Intersects(rect.x1, rect.y1, rect.x2, rect.y2)
                end
                local intersects = false
                SO.Util.ForEachJavaOrLuaList(provider.GetZones(), function(zone)
                    if not intersects and SO.Util.RectsIntersect(rect, normalizeProviderZone(zone)) then intersects = true end
                end)
                return intersects
            end)
            if not ok then
                SO.Logger.Warn("Managed-zone provider failed", { provider = id, error = tostring(result) })
            elseif result then
                return true, id
            end
        end
    end
    return false, nil
end

function Compatibility.IntersectsTemple(x1, y1, x2, y2, ignoreZoneId)
    local rect = SO.Util.NormalizeRect(x1, y1, x2, y2)
    if not rect or type(Compatibility.TempleProvider) ~= "function" then return false end
    local ok, result = pcall(Compatibility.TempleProvider, rect, ignoreZoneId)
    if not ok then
        SO.Logger.Warn("Temple intersection provider failed", { error = tostring(result) })
        return false
    end
    return result == true
end

SO.Zones = SO.Zones or {}
SO.Zones.IntersectsTemple = Compatibility.IntersectsTemple

return Compatibility
