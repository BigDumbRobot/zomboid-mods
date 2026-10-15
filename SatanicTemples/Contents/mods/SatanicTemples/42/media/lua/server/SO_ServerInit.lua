if isClient() then return end

require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"
-- Networked timed actions are reconstructed by type on the server. Load the
-- shared ritual action before accepting any player action packets.
require "SacrificialOffering/SO_OfferingAction"
require "SacrificialOffering/SO_DropCorpseIntoAltarAction"
require "SacrificialOffering/SO_Sandbox"
require "SacrificialOffering/SO_RecipeParser"
require "SacrificialOffering/SO_ZoneCompatibility"
require "SacrificialOffering/SO_Storage"
require "SacrificialOffering/SO_PlayerLedger"
require "SacrificialOffering/SO_CorpseCarryIntegration"
require "SacrificialOffering/SO_FixtureService"
require "SacrificialOffering/SO_ZoneService"
require "SacrificialOffering/SO_ServerProtection"
require "SacrificialOffering/SO_OfferingService"
require "SacrificialOffering/SO_RelicService"

local SO = SacrificialOffering
SO.Server = SO.Server or {}

function SO.Server.HandleClientCommand(module, command, player, args)
    if module ~= SO.MODULE then return end
    args = type(args) == "table" and args or {}
    SO.Logger.Debug("Server command received", {
        command = command,
        player = SO.PlayerLedger.GetIdentity(player),
        tx = args.tx,
    })
    if command == SO.COMMAND.REQUEST_ZONES then
        SO.ZoneService.Sync(player)
    elseif command == SO.COMMAND.CREATE_ZONE then
        SO.ZoneService.Create(player, args)
    elseif command == SO.COMMAND.RESIZE_ZONE then
        SO.ZoneService.Resize(player, args)
    elseif command == SO.COMMAND.RENAME_ZONE then
        SO.ZoneService.Rename(player, args)
    elseif command == SO.COMMAND.DELETE_ZONE then
        SO.ZoneService.Delete(player, args)
    elseif command == SO.COMMAND.BEGIN_OFFERING then
        SO.OfferingService.Begin(player, args)
    elseif command == SO.COMMAND.MAKE_OFFERING then
        SO.OfferingService.Make(player, args)
    elseif command == SO.COMMAND.DEATH_NOTICE then
        SO.PlayerLedger.HandleDeathNotice(player, args)
    elseif command == SO.COMMAND.PURGE_ZONES then
        SO.ZoneService.PurgeAll(player, false)
    elseif command == SO.COMMAND.RELIC_THEFT then
        SO.RelicService.HandleTheftAttempt(player, args)
    else
        SO.Logger.Warn("Unknown client command ignored", { command = tostring(command) })
    end
end

Events.OnClientCommand.Add(SO.Server.HandleClientCommand)

-- Server-console entry point for a full pre-uninstall clean: removes every
-- temple's fixtures, all zone records, every per-account recovery ledger, and
-- the persisted mod data. Run this, confirm the temples are gone, then remove
-- the mod. Safe to call with no players online.
function SacrificialOffering.PurgeAll()
    if isClient() then
        print("[SacrificialOffering] PurgeAll must be run on the server (or in single-player).")
        return false
    end
    return SO.ZoneService.PurgeAll(nil, true)
end

local function onServerStarted()
    SO.Storage.Get()
    SO.ServerProtection.ClearAllZoneFires()
    SO.ZoneService.ProvisionAndRepair()
    SO.Logger.Info("Server systems ready", {
        version = SO.VERSION,
        zones = #SO.Storage.Get().zones,
        recipes = #SO.RecipeParser.Parse(SO.Sandbox.String("AcceptableItemRecipes")),
    })
end

if Events.OnServerStarted then Events.OnServerStarted.Add(onServerStarted) end

return SO.Server
