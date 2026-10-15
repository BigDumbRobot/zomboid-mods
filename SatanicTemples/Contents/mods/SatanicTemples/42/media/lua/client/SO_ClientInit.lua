require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_CorpseCarryIntegration"
require "SacrificialOffering/SO_CorpseLabelIntegration"
require "SacrificialOffering/SO_VehicleCorpseIntegration"
require "SacrificialOffering/SO_AltarIconIntegration"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"
require "SacrificialOffering/SO_Sandbox"
require "SacrificialOffering/SO_RecipeParser"
require "SacrificialOffering/SO_ZoneCompatibility"
require "SacrificialOffering/SO_Announce"
require "SacrificialOffering/SO_Sound"
require "SacrificialOffering/SO_ClientState"
require "SacrificialOffering/SO_Effects"
require "SacrificialOffering/SO_RitualTrance"
require "SacrificialOffering/SO_Protection"
require "SacrificialOffering/SO_ClientZoneRules"
require "SacrificialOffering/SO_ZoneEditorIntegration"
require "SacrificialOffering/SO_WorldMapIntegration"
require "SacrificialOffering/SO_AnimalCorpseIntegration"
require "SacrificialOffering/SO_Proximity"
require "SacrificialOffering/SO_OfferingAction"
require "ISUI/LootWindow/Handlers/SO_MakeOffering"

local SO = SacrificialOffering

local function requestZones()
    SO.Client.RequestZones()
    SO.Logger.Info("Client systems ready", { version = SO.VERSION })
end

local function onCreatePlayer(playerIndex, player)
    if playerIndex == 0 then SO.Client.RequestZones() end
end

local function onPlayerDeath(player)
    if not player or not player:isLocalPlayer() then return end
    SO.Client.SendCommand(SO.COMMAND.DEATH_NOTICE, {
        tx = SO.Util.NewTransactionId("death", player),
        onlineId = player:getOnlineID(),
    })
end

Events.OnGameStart.Add(requestZones)
Events.OnCreatePlayer.Add(onCreatePlayer)
Events.OnPlayerDeath.Add(onPlayerDeath)

return SO.Client
