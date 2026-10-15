require "BonkZone/BonkZone_Constants"
require "BonkZone/BonkZone_Logger"
require "BonkZone/BonkZone_Registry"

BonkZone = BonkZone or {}
BonkZone.Presence = BonkZone.Presence or {}

local Presence = BonkZone.Presence
local Constants = BonkZone.Constants
local Logger = BonkZone.Logger
local Registry = BonkZone.Registry

Presence.State = Presence.State or {}

local function isLocalPlayer(player)
    local startedAt = Logger.Begin("Presence.isLocalPlayer")
    if not player then
        Logger.Finish("Presence.isLocalPlayer", startedAt, false)
        return false
    end
    local index = player.getPlayerNum and player:getPlayerNum() or 0
    local localPlayer = getSpecificPlayer and getSpecificPlayer(index) or nil
    local result = localPlayer == player
    Logger.Finish("Presence.isLocalPlayer", startedAt, true, { result = result, index = index })
    return result
end

function Presence.OnPlayerUpdate(player)
    if not isLocalPlayer(player) then return end
    local playerIndex = player:getPlayerNum()
    local state = Presence.State[playerIndex] or { inside = false, lastCheck = 0 }
    Presence.State[playerIndex] = state
    local now = Constants.NowMs()
    if now - state.lastCheck < Constants.ENTRY_CHECK_INTERVAL_MS then return end
    state.lastCheck = now

    local inside, zone = Registry.IsCharacterInside(player)
    if inside ~= state.inside then
        state.inside = inside
        state.zoneId = zone and zone.id or nil
        if HaloTextHelper then
            if inside then
                HaloTextHelper.addBadText(player, getText("IGUI_BonkZone_Entered"))
            else
                HaloTextHelper.addGoodText(player, getText("IGUI_BonkZone_Exited"))
            end
        end
        Logger.Info("Presence", inside and "player entered Bonk Zone" or "player exited Bonk Zone", {
            player = player:getUsername(),
            zoneId = state.zoneId or "",
        })
    end
    Logger.RateLimited("TRACE", "Presence.OnPlayerUpdate." .. tostring(playerIndex), 5000, "Presence.OnPlayerUpdate", "checked", { inside = inside })
end

Events.OnPlayerUpdate.Add(Presence.OnPlayerUpdate)

return Presence

