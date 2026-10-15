require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Logger"
require "SacrificialOffering/SO_ClientState"
require "ISUI/AdminPanel/ZoneEditor/ISMultiplayerZoneEditor"
require "ISUI/AdminPanel/ZoneEditor/SO_TempleZoneMode"

local SO = SacrificialOffering
SO.ZoneEditorIntegration = SO.ZoneEditorIntegration or {}
local Integration = SO.ZoneEditorIntegration

local function isAuthorized()
    local player = getPlayer()
    if not player or not player:getRole() then return false end
    return player:getRole():hasCapability(Capability.CanSetupNonPVPZone) or
        player:getRole():hasCapability(Capability.CanSetupSafehouses)
end

local function comboHasMode(combo)
    if not combo then return false end
    for index = 1, combo:getOptionCount() do
        if combo:getOptionData(index) == SO.ZONE_MODE then return true end
    end
    return false
end

function Integration.EnsureMode(editor)
    if not editor or not editor.modeCombo or not editor.mode then return end
    if not editor.mode[SO.ZONE_MODE] then
        local mode = MultiplayerZoneEditorMode_SO_SatanicTemples:new(editor)
        editor.mode[SO.ZONE_MODE] = mode
        editor:addChild(mode)
        mode:setVisible(false)
    end
    if isAuthorized() and not comboHasMode(editor.modeCombo) then
        editor.modeCombo:addOptionWithData(getText("IGUI_SO_ZoneEditorMode"), SO.ZONE_MODE)
    end
end

function Integration.OnRolesReceived()
    local editor = ISMultiplayerZoneEditor_instance
    if editor then Integration.EnsureMode(editor) end
end

if not Integration.Patched then
    Integration.Patched = true
    local oldCreateChildren = ISMultiplayerZoneEditor.createChildren
    function ISMultiplayerZoneEditor:createChildren()
        oldCreateChildren(self)
        Integration.EnsureMode(self)
    end

    local oldOnRolesReceived = ISMultiplayerZoneEditor.OnRolesReceived
    function ISMultiplayerZoneEditor.OnRolesReceived()
        local editor = ISMultiplayerZoneEditor_instance
        local restoreTemple = editor and editor.currentMode == SO.ZONE_MODE
        oldOnRolesReceived()
        editor = ISMultiplayerZoneEditor_instance
        Integration.EnsureMode(editor)
        if restoreTemple and editor and isAuthorized() then
            editor.modeCombo:selectData(SO.ZONE_MODE)
            editor:onSwitchMode(SO.ZONE_MODE)
        end
    end

    -- Transfer the one role-event listener to this cooperative wrapper. Other
    -- zone mods use the same hand-off, creating one composable chain regardless
    -- of which mod loads first.
    Events.OnRolesReceived.Remove(oldOnRolesReceived)
    Events.OnRolesReceived.Add(ISMultiplayerZoneEditor.OnRolesReceived)
    SO.Logger.Debug("Additive Satanic Temples Zone Editor mode installed")
end

return Integration
