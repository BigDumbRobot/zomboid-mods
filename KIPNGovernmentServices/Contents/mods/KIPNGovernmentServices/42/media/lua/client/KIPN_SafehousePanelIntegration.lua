-- KIPN_SafehousePanelIntegration.lua
--
-- Keeps vanilla's useful SafeHouse management panel (members/title/respawn),
-- adds a KIPN boundary viewer, and routes Release through KIPN's authoritative
-- server transaction instead of vanilla sendSafehouseRelease().

if isServer() then return end

require "ISUI/UserPanel/ISSafehouseUI"
require "KIPN_Shared"
require "KIPN_SafehouseAreaUI"

local UI_BORDER_SPACING = 10

local function kipnPropertyClaimsEnabled()
    local vars = SandboxVars and SandboxVars.KIPN
    if vars and vars.SafehouseClaimsEnabled ~= nil then
        return vars.SafehouseClaimsEnabled == true
    end
    return true
end

local originalInitialise = ISSafehouseUI.initialise
local originalUpdateButtons = ISSafehouseUI.updateButtons
local originalOnClick = ISSafehouseUI.onClick
local originalOnReleaseSafehouse = ISSafehouseUI.onReleaseSafehouse

function ISSafehouseUI:initialise()
    originalInitialise(self)

    local anchor = self.releaseSafehouse
    if not anchor then return end

    local button = ISButton:new(
        anchor:getRight() + UI_BORDER_SPACING,
        anchor:getY(),
        120,
        anchor:getHeight(),
        "View KIPN Bounds",
        self,
        ISSafehouseUI.onClick
    )
    button.internal = "KIPN_VIEW_BOUNDS"
    button:initialise()
    button:instantiate()
    button.borderColor = self.buttonBorderColor
    if button.setWidthToTitle then button:setWidthToTitle(100) end
    self:addChild(button)
    button:setVisible(false)
    self.kipnViewBounds = button
end

function ISSafehouseUI:updateButtons()
    originalUpdateButtons(self)
    local button = self.kipnViewBounds
    if not button then return end

    local anchor = self.releaseSafehouse
    if anchor then
        button:setX(anchor:getRight() + UI_BORDER_SPACING)
        button:setY(anchor:getY())
    end
    local enabled = kipnPropertyClaimsEnabled()
    button:setVisible(enabled and self.safehouse ~= nil)

    -- Ownership transfer is a KIPN ownership operation, not a vanilla panel
    -- mutation. Keep title/member/respawn management, but do not let a KIPN
    -- property silently detach itself by changing vanilla owner underneath the
    -- ClaimService record.
    if enabled and self.changeOwnership then
        self.changeOwnership:setVisible(false)
        self.changeOwnership.enable = false
    end
end

function ISSafehouseUI:onClick(button)
    if button.internal == "KIPN_VIEW_BOUNDS" then
        KIPN_SafehouseAreaUI.open(self.player, self.safehouse)
        return
    end
    originalOnClick(self, button)
end

function ISSafehouseUI:onReleaseSafehouse(button, player)
    if not kipnPropertyClaimsEnabled() then
        return originalOnReleaseSafehouse(self, button, player)
    end

    if button.internal == "YES" then
        local ui = button.parent and button.parent.ui
        local safehouse = ui and ui.safehouse
        if ui and safehouse and (ui:isOwner() or ui:hasPrivilegedAccessLevel()) then
            local command = KIPN.Shared and KIPN.Shared.Commands
                and KIPN.Shared.Commands.RELEASE_SAFEHOUSE
                or "releaseSafehouse"
            sendClientCommand("KIPN", command, {
                x = safehouse:getX(),
                y = safehouse:getY(),
                w = safehouse:getW(),
                h = safehouse:getH(),
            })
        end
    end

    local ui = button.parent and button.parent.ui
    if ui then ui:close() end
end

print("[KIPN] Safehouse panel integration loaded")
