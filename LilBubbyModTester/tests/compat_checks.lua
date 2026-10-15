-- Offline checks for the Mod Compatibility suite. The hooks below are written
-- here to the pattern each mod documents; no mod source is loaded. The suite
-- must pass well-behaved hooks and catch broken ones.
-- Run from this Workshop project directory.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
local enabled = { SVSBoobyTraps = true, KIPN = true, SpyVsSpySignalTracker = true, SkylightsProbe = true,
    KIPNGovernmentServices = true, KIPNVehicleServices = true, BonkZone = true }
getActivatedMods = function() return { contains = function(_, id) return enabled[id] == true end } end
require = function() end
Events = setmetatable({}, { __index = function(t, key) local e = { Add = function() end }; t[key] = e; return e end })
isClient = function() return true end
dofile(root .. "client/LilBubbyShowcase.lua")
local S = LilBubbyShowcase

------------------------------------------------------------
-- Vanilla stand-ins: reaching these means a hook let the call through.
------------------------------------------------------------
local vanillaCalls = 0
ISEntityUI = {
    HandcraftStart = function() vanillaCalls = vanillaCalls + 1; return "vanilla" end,
    HandcraftStartMultiple = function() vanillaCalls = vanillaCalls + 1; return "vanilla" end,
}
ISHandcraftAction = {
    start = function() vanillaCalls = vanillaCalls + 1; return "vanilla" end,
    getDuration = function() return 100 end,
}
SVSBT = { Client = { Notify = function() end, SendCommand = function() end }, Config = { Get = function() return 2 end } }
SVS = { Signals = { Client = { Notify = function() end }, Commands = { RF_SCAN = "RFScan" } } }

local function hook(prefix, matches, notify)
    local ui, action = ISEntityUI, ISHandcraftAction
    ui[prefix .. "OriginalHandcraftStart"] = ui.HandcraftStart
    ui.HandcraftStart = function(player, logic, force, queue, eat)
        if matches(logic:getRecipe():getName()) and not logic:canPerformCurrentRecipe() then notify(player); return nil end
        return ui[prefix .. "OriginalHandcraftStart"](player, logic, force, queue, eat)
    end
    ui[prefix .. "OriginalHandcraftStartMultiple"] = ui.HandcraftStartMultiple
    ui.HandcraftStartMultiple = function(player, logic, force, qty, queue)
        if matches(logic:getRecipe():getName()) and logic:getPossibleCraftCount(true) < qty then notify(player); return nil end
        return ui[prefix .. "OriginalHandcraftStartMultiple"](player, logic, force, qty, queue)
    end
    action[prefix .. "OriginalStart"] = action.start
    action.start = function(self)
        local result = action[prefix .. "OriginalStart"](self)
        if matches(self.craftRecipe:getName()) and not self.logic:canPerformCurrentRecipe() then
            notify(self.character); self:forceStop()
        end
        return result
    end
end
local function halo(player) player:setHaloNote("missing") end
hook("SVSBT_", function(n) return n:find("SVSBT_", 1, true) ~= nil end, function() SVSBT.Client.Notify("missing", true) end)
hook("KIPN_", function(n) return n:sub(1, 5) == "KIPN." end, halo)
local silent = false
hook("SVS_", function(n) return n:sub(1, 4) == "GPS_" end, function()
    if not silent then SVS.Signals.Client.Notify("missing") end
end)
hook("Skylights", function(n) return n:find("SkylightProbeFloor", 1, true) ~= nil end, halo)
ISHandcraftAction.SVSBT_OriginalGetDuration = ISHandcraftAction.getDuration
ISHandcraftAction.getDuration = function(self)
    local duration = ISHandcraftAction.SVSBT_OriginalGetDuration(self)
    if self.craftRecipe:getName():find("SVSBT_", 1, true) then duration = duration * SVSBT.Config.Get("CraftingTimeMultiplier") end
    return duration
end

-- Timed actions: refuse without the listed items, recheck at start.
local function requirement(needs)
    local class = {}
    function class.CanStart(character, notify)
        for _, fullType in ipairs(needs) do
            if not character:getInventory():containsTypeRecurse(fullType) then
                if notify then character:setHaloNote("missing") end
                return false
            end
        end
        return true
    end
    function class.start(self)
        if not class.CanStart(self.character, true) then self:forceStop(); return end
        self:setActionAnim("Loot")
    end
    return class
end
KIPN_RepairComputerAction = requirement({ "Base.Screwdriver", "Base.KIPNComputerRepairKit" })
KIPN_DisassembleComputerAction = requirement({ "Base.Screwdriver" })
KIPN_PropertyClaimAction = requirement({ "Base.KIPNPropertyClaimArtifact" })
KIPN_VehicleClaimAction = requirement({ "Base.KIPNVehicleClaimArtifact" })
local function device(client, key)
    return { start = function(self)
        if self.args[key] == -1 then client.Notify("gone"); self:forceStop(); return end
        client.SendCommand(self.command, self.args); self:setActionAnim("Craft")
    end }
end
SVSBTDeviceAction = device(SVSBT.Client, "itemId")
SVS.Signals.Client.SendCommand = function() end
SVSDeviceAction = device(SVS.Signals.Client, "detectorItemId")

-- Claim fee cash: bundles are worth 100, the configured currency its value.
SandboxVars = { KIPN = { ClaimCurrencyItemType = "Base.Money", ClaimCurrencyItemValue = 1 } }
local function tally(container, found)
    found = found or { bundles = 0, units = 0 }
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item:getFullType() == "Base.MoneyBundle" then found.bundles = found.bundles + 1
        elseif item:getFullType() == SandboxVars.KIPN.ClaimCurrencyItemType then found.units = found.units + 1 end
        if item.getInventory then tally(item:getInventory(), found) end
    end
    return found
end
KIPN_GovernmentServices = {
    countInventoryCash = function(p)
        local found = tally(p:getInventory())
        return found.bundles * 100 + found.units * SandboxVars.KIPN.ClaimCurrencyItemValue
    end,
    -- Affordable only when bundles and units can pay the amount exactly.
    canAffordInventoryCash = function(p, amount)
        local found, value = tally(p:getInventory()), SandboxVars.KIPN.ClaimCurrencyItemValue
        for bundles = 0, found.bundles do
            local rest = amount - bundles * 100
            if rest >= 0 and rest % value == 0 and rest / value <= found.units then return true end
        end
        return false
    end,
}

dofile(root .. "client/CompatTest_Client.lua")
local C = CompatTest
local player = { getPlayerNum = function() return 0 end, getOnlineID = function() return 1 end }
getSpecificPlayer = function() return player end

local function report(fn)
    local r = C.NewReport("t")
    fn(r)
    return r
end
local function clean(r, label)
    assert((r.counts.FAIL or 0) == 0 and (r.counts.ERROR or 0) == 0 and (r.counts.PASS or 0) > 0,
        label .. " should pass:\n" .. r:text())
end

-- Well-behaved hooks pass, and vanilla is never reached.
vanillaCalls = 0
clean(report(function(r) C.Automatic(r, player) end), "every automatic check")
assert(vanillaCalls == 0, "a check reached vanilla crafting " .. vanillaCalls .. " times")
for _, entry in ipairs(C.HANDCRAFT) do
    assert(type(ISEntityUI[entry.start]) == "function", "fixture restored " .. entry.start)
end
assert(SandboxVars.KIPN.ClaimCurrencyItemType == "Base.Money" and SandboxVars.KIPN.ClaimCurrencyItemValue == 1, "sandbox restored")
local original = SVSBT.Client.Notify
assert(SVSBT.Client.Notify == original, "notifier restored")

-- Menu offers one entry per enabled mod and hides the rest.
local entries = S.Build(player, "compat")
local names = {}
for _, entry in ipairs(entries) do names[#names + 1] = entry.name end
local list = table.concat(names, "\n")
assert(list:find("Skylights: recipe checks", 1, true) and list:find("Zone Editor", 1, true), list)
enabled.SkylightsProbe = nil
list = {}
for _, entry in ipairs(S.Build(player, "compat")) do list[#list + 1] = entry.name end
list = table.concat(list, "\n")
assert(not list:find("Skylights", 1, true), "disabled mod's checks are hidden:\n" .. list)
enabled.SkylightsProbe = true

-- A hook that swallows vanilla recipes is caught.
local good = ISEntityUI.KIPN_OriginalHandcraftStart
local greedy = ISEntityUI.HandcraftStart
ISEntityUI.HandcraftStart = function(p, logic, ...)
    if logic:getRecipe():getName() == C.VANILLA_RECIPE then return nil end
    return greedy(p, logic, ...)
end
local r = report(function(rep) C.CheckHandcraft(rep, player, C.HandcraftFor("KIPN")) end)
assert((r.counts.FAIL or 0) > 0 and r:text():find("Vanilla Base.MakeSoup is passed on untouched", 1, true), r:text())
ISEntityUI.HandcraftStart = greedy
assert(ISEntityUI.KIPN_OriginalHandcraftStart == good)

-- A hook that refuses silently is caught.
silent = true
r = report(function(rep) C.CheckHandcraft(rep, player, C.HandcraftFor("SpyVsSpySignalTracker")) end)
assert((r.counts.FAIL or 0) == 3, "silent refusals must fail:\n" .. r:text())
silent = false

-- A hook the loaded version does not install is a SKIP, not a failure.
local saved = ISEntityUI.SkylightsOriginalHandcraftStart
ISEntityUI.SkylightsOriginalHandcraftStart = nil
r = report(function(rep) C.CheckHandcraft(rep, player, C.HandcraftFor("SkylightsProbe")) end)
assert(r:text():find("SKIP: This version of Skylights does not wrap ISEntityUI.HandcraftStart", 1, true) and (r.counts.FAIL or 0) == 0, r:text())
ISEntityUI.SkylightsOriginalHandcraftStart = saved

-- A timed action that forgets its start recheck is caught.
local start = KIPN_PropertyClaimAction.start
KIPN_PropertyClaimAction.start = function(self) self:setActionAnim("Loot") end
r = report(function(rep) C.CheckRequirement(rep, player, C.REQUIREMENTS[3]) end)
assert((r.counts.FAIL or 0) == 1, r:text())
KIPN_PropertyClaimAction.start = start

-- Zone editor: duplicated modes after a role refresh are caught.
Capability = {}
local combo = { options = {} }
function combo:getOptionCount() return #self.options end
function combo:getOptionData(i) return self.options[i] end
local editor = { modeCombo = combo, mode = { NonPVP = {}, Safehouse = {}, KIPN = {}, Bonk = {} } }
function editor:onSwitchMode(mode) self.currentMode = mode end
function editor:close() self.closed = true end
local duplicate = false
ISMultiplayerZoneEditor = {
    ShowEditor = function() ISMultiplayerZoneEditor_instance = editor end,
    OnRolesReceived = function()
        combo.options = { "NonPVP", "Safehouse", "KIPN", "Bonk" }
        if duplicate then combo.options[#combo.options + 1] = "KIPN" end
    end,
}
ISMultiplayerZoneEditor.OnRolesReceived()
clean(report(function(rep) C.CheckZoneEditor(rep) end), "zone editor")
assert(editor.closed, "an editor the check opened is closed again")
duplicate = true
ISMultiplayerZoneEditor_instance = nil
r = report(function(rep) C.CheckZoneEditor(rep) end)
assert((r.counts.FAIL or 0) > 0 and r:text():find("KIPN", 1, true), r:text())
print("PASS: compatibility checks pass composed hooks without reaching vanilla, restore every swap, hide disabled mods, and catch greedy, silent and missing hooks, missing start rechecks and duplicated zone editor modes")
