-- KIPN_SafehouseClaimGate.lua
-- Keeps vanilla release transport available while preventing ordinary players
-- from using the vanilla Claim Safehouse UI when KIPN property claiming is active.

if isServer() then return end

local function kipnPropertyClaimsEnabled()
    local sv = SandboxVars and SandboxVars.KIPN
    if sv and sv.SafehouseClaimsEnabled ~= nil then
        return sv.SafehouseClaimsEnabled == true
    end
    return true
end

local function onFillWorldObjectContextMenu(_playerNum, context, _worldobjects, test)
    if test or not context or not kipnPropertyClaimsEnabled() then return end
    local claimText = getText and getText("ContextMenu_SafehouseClaim") or "Claim Safehouse"
    for _, option in ipairs(context.options or {}) do
        if option and option.name == claimText then
            option.notAvailable = true
            if ISToolTip then
                local tt = ISToolTip:new()
                tt:initialise()
                tt.description = "KIPN safehouse claims require a Safehouse Deed."
                option.toolTip = tt
            end
        end
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
print("[KIPN] Safehouse vanilla-claim gate loaded")
