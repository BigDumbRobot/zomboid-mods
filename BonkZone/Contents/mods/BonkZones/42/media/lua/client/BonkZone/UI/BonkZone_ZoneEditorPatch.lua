require "ISUI/AdminPanel/ZoneEditor/MultiplayerZoneEditorMode"
require "ISUI/AdminPanel/ZoneEditor/MultiplayerZoneEditorMode_NonPVP"
require "ISUI/AdminPanel/ZoneEditor/MultiplayerZoneEditorMode_Safehouse"
require "ISUI/AdminPanel/ZoneEditor/ISMultiplayerZoneEditor"
require "BonkZone/UI/MultiplayerZoneEditorMode_Bonk"
require "BonkZone/BonkZone_Logger"
require "BonkZone/BonkZone_Network"

BonkZone = BonkZone or {}
BonkZone.ZoneEditorPatch = BonkZone.ZoneEditorPatch or {}

local Patch = BonkZone.ZoneEditorPatch
local Logger = BonkZone.Logger

Patch.Installed = Patch.Installed or false

local function comboHasMode(combo, modeId)
    if not combo then return false end
    for index = 1, combo:getOptionCount() do
        if combo:getOptionData(index) == modeId then return true end
    end
    return false
end

local function canUseBonkEditor()
    local startedAt = Logger.Begin("ZoneEditorPatch.canUseBonkEditor")
    local player = getPlayer and getPlayer() or nil
    if not player then
        Logger.Finish("ZoneEditorPatch.canUseBonkEditor", startedAt, false, "missing player")
        return false
    end
    -- UI gate only; the server (Server.canManageZones) is the real authority. Keep the
    -- rule identical: admin access level, or a role granted the Non-PVP zone capability.
    local allowed = false
    if player.getAccessLevel then
        local level = string.lower(tostring(player:getAccessLevel() or ""))
        allowed = level == "admin"
    end
    if not allowed and player.getRole and Capability and Capability.CanSetupNonPVPZone then
        local ok, result = pcall(function()
            local role = player:getRole()
            return role and role:hasCapability(Capability.CanSetupNonPVPZone)
        end)
        allowed = ok and result == true
    end
    Logger.Finish("ZoneEditorPatch.canUseBonkEditor", startedAt, true, { allowed = allowed })
    return allowed
end

function Patch.Install()
    local startedAt = Logger.Begin("ZoneEditorPatch.Install")
    if Patch.Installed then
        Logger.Finish("ZoneEditorPatch.Install", startedAt, true, "already installed")
        return
    end
    Patch.Installed = true

    local function ensureBonkMode(editor)
        if not editor or not editor.mode or not editor.modeCombo then return false end
        if not editor.mode.Bonk then
            editor.mode.Bonk = MultiplayerZoneEditorMode_Bonk:new(editor)
            editor:addChild(editor.mode.Bonk)
            editor.mode.Bonk:setVisible(false)
        end
        local authorized = canUseBonkEditor()
        if authorized and not comboHasMode(editor.modeCombo, "Bonk") then
            editor.modeCombo:addOptionWithData(getText("IGUI_BonkZone_Mode"), "Bonk")
        end
        if editor.buttonPanel and editor.buttonPanel.bringToTop then editor.buttonPanel:bringToTop() end
        if editor.modeCombo.bringToTop then editor.modeCombo:bringToTop() end
        return authorized
    end

    local originalCreateChildren = ISMultiplayerZoneEditor.createChildren
    ISMultiplayerZoneEditor.createChildren = function(self)
        originalCreateChildren(self)
        ensureBonkMode(self)
        BonkZone.Network.RequestSync(true)
        Logger.Info("ZoneEditorPatch", "Bonk mode attached to editor")
    end

    local originalOnRolesReceived = ISMultiplayerZoneEditor.OnRolesReceived
    ISMultiplayerZoneEditor.OnRolesReceived = function()
        local instance = ISMultiplayerZoneEditor_instance
        local restoreBonk = instance and instance.currentMode == "Bonk" and instance.mode and instance.mode.Bonk
        originalOnRolesReceived()
        instance = ISMultiplayerZoneEditor_instance
        local authorized = ensureBonkMode(instance)
        if restoreBonk and authorized then
            instance.modeCombo:selectData("Bonk")
            instance:onSwitchMode("Bonk")
        end
        Logger.Debug("ZoneEditorPatch", "roles refreshed", { bonkAvailable = authorized })
    end

    -- Transfer the single vanilla/previous listener to the new cooperative
    -- wrapper. Every participating zone mod performs the same hand-off, so the
    -- final event invokes the complete chain exactly once in any load order.
    Events.OnRolesReceived.Remove(originalOnRolesReceived)
    Events.OnRolesReceived.Add(ISMultiplayerZoneEditor.OnRolesReceived)

    Logger.Info("ZoneEditorPatch", "vanilla multiplayer zone editor patched")
    Logger.Finish("ZoneEditorPatch.Install", startedAt, true)
end

Patch.Install()

return Patch
