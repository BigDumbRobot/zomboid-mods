require "LilBubbyShowcase"

-- Mod Compatibility: checks that the enabled mods' hooks on shared vanilla
-- entry points compose. Every check calls the live, Workshop-loaded hook
-- through the real outermost entry point (ISEntityUI.HandcraftStart,
-- ISHandcraftAction.start, ...). The mod's own "next in chain" field is
-- swapped for a counter for the duration of one call, so nothing below it —
-- in particular vanilla crafting — ever runs, and it is restored at once.
CompatTest = CompatTest or {}
local C = CompatTest
local S = LilBubbyShowcase
C.SENTINEL = { lilBubbyCompat = true }

------------------------------------------------------------
-- REPORT
------------------------------------------------------------

function C.NewReport(title)
    local r = { title = title, lines = {}, counts = {} }
    function r:add(status, text)
        self.counts[status] = (self.counts[status] or 0) + 1
        self.lines[#self.lines + 1] = status .. ": " .. text
    end
    function r:check(ok, text, detail)
        self:add(ok and "PASS" or "FAIL", text .. ((not ok and detail) and (" (" .. tostring(detail) .. ")") or ""))
        return ok
    end
    function r:equal(actual, expected, text)
        return self:check(actual == expected, text, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
    end
    function r:info(text) self:add("INFO", text) end
    function r:skip(text) self:add("SKIP", text) end
    function r:error(text) self:add("ERROR", text) end
    function r:text()
        local failed = (self.counts.FAIL or 0) + (self.counts.ERROR or 0)
        local verdict = failed > 0 and "FAILED" or ((self.counts.PASS or 0) > 0 and "PASSED" or "NOT RUN")
        return self.title .. " | " .. verdict .. " | pass=" .. (self.counts.PASS or 0) .. " fail=" .. (self.counts.FAIL or 0)
            .. " error=" .. (self.counts.ERROR or 0) .. "\n" .. table.concat(self.lines, "\n")
    end
    return r
end

------------------------------------------------------------
-- STAND-INS
------------------------------------------------------------

local function recipe(name)
    return {
        getName = function() return name end,
        getOriginalname = function() return name end,
        getFullType = function() return name end,
        isAnySurfaceCraft = function() return false end,
    }
end

local function logic(name, canPerform, possible, player)
    local craft = recipe(name)
    return {
        getRecipe = function() return craft end,
        canPerformCurrentRecipe = function() return canPerform end,
        getPossibleCraftCount = function() return possible or (canPerform and 1 or 0) end,
        getPlayer = function() return player end,
        getIsoObject = function() return nil end,
    }
end

-- A character that only records what it is told. The optional item types
-- make up its whole (recursive) inventory.
function C.Proxy(player, itemTypes)
    local proxy = { notices = 0, items = {} }
    for _, fullType in ipairs(itemTypes or {}) do proxy.items[fullType] = true end
    local inventory = {
        containsTypeRecurse = function(_, fullType) return proxy.items[fullType] == true end,
        contains = function(_, fullType) return proxy.items[fullType] == true end,
    }
    function proxy:getInventory() return inventory end
    function proxy:setHaloNote() self.notices = self.notices + 1 end
    function proxy:Say() self.notices = self.notices + 1 end
    function proxy:getPlayerNum() return player and player:getPlayerNum() or 0 end
    function proxy:getUsername() return "LilBubbyCompatProxy" end
    return proxy
end

-- Replaces fields for one call, then restores them even if the call fails.
function C.With(swaps, fn)
    local saved = {}
    for i, swap in ipairs(swaps) do
        saved[i] = swap[1][swap[2]]
        swap[1][swap[2]] = swap[3]
    end
    local ok, a, b = pcall(fn)
    for i, swap in ipairs(swaps) do swap[1][swap[2]] = saved[i] end
    if not ok then error(a, 0) end
    return a, b
end

------------------------------------------------------------
-- HANDCRAFT COMPOSITION
------------------------------------------------------------

-- Each mod's recipe-scoped wrappers and where it sends its notices.
C.HANDCRAFT = {
    { mod = "SVSBoobyTraps", name = "Spy vs Spy Booby Traps", recipe = "SVSBT_CraftNailBoard",
      start = "SVSBT_OriginalHandcraftStart", multiple = "SVSBT_OriginalHandcraftStartMultiple",
      action = "SVSBT_OriginalStart", notifier = function() return SVSBT and SVSBT.Client end },
    { mod = "KIPN", name = "KIP Network Terminal", recipe = "KIPN.CraftComputerRepairKit",
      start = "KIPN_OriginalHandcraftStart", multiple = "KIPN_OriginalHandcraftStartMultiple",
      action = "KIPN_OriginalStart" },
    { mod = "SpyVsSpySignalTracker", name = "Spy vs Spy Signal Tracker", recipe = "GPS_AssembleTracker",
      start = "SVS_OriginalHandcraftStart", multiple = "SVS_OriginalHandcraftStartMultiple",
      action = "SVS_OriginalStart", notifier = function() return SVS and SVS.Signals and SVS.Signals.Client end },
    { mod = "SkylightsProbe", name = "Skylights", recipe = "Base.SkylightProbeFloor",
      start = "SkylightsOriginalHandcraftStart", multiple = "SkylightsOriginalHandcraftStartMultiple",
      action = "SkylightsOriginalStart" },
}
C.VANILLA_RECIPE = "Base.MakeSoup"

function C.HandcraftFor(id)
    for _, entry in ipairs(C.HANDCRAFT) do if entry.mod == id then return entry end end
end

-- Counts one mod's notices: halo notes on the stand-in, plus its notifier.
local function counting(entry, proxy, fn)
    local notifier = entry.notifier and entry.notifier()
    if not notifier then return fn() end
    return C.With({ { notifier, "Notify", function() proxy.notices = proxy.notices + 1 end } }, fn)
end

function C.CheckHandcraft(r, player, entry)
    local ui, action = ISEntityUI, ISHandcraftAction
    if not r:check(ui ~= nil and action ~= nil, "Vanilla ISEntityUI and ISHandcraftAction are loaded") then return end
    -- A hook the loaded version does not install has nothing to compose; that
    -- is the mod's design choice, reported as SKIP rather than a failure.
    local function wraps(target, field, label)
        if type(target[field]) == "function" then
            r:add("PASS", entry.name .. " wraps " .. label)
            return true
        end
        r:skip("This version of " .. entry.name .. " does not wrap " .. label .. " (no " .. field .. "); nothing to compose")
        return false
    end
    local hooked = wraps(ui, entry.start, "ISEntityUI.HandcraftStart")
    local hookedMultiple = wraps(ui, entry.multiple, "ISEntityUI.HandcraftStartMultiple")
    local hookedAction = wraps(action, entry.action, "ISHandcraftAction.start")

    local reached = 0
    local function stub() reached = reached + 1; return C.SENTINEL end

    if hooked then
        local function start(name, canPerform)
            local proxy = C.Proxy(player)
            reached = 0
            local result = C.With({ { ui, entry.start, stub } }, function()
                return counting(entry, proxy, function()
                    return ui.HandcraftStart(proxy, logic(name, canPerform, nil, proxy), false, true, 0)
                end)
            end)
            return result, reached, proxy.notices
        end
        local result, calls, notices = start(entry.recipe, false)
        r:equal(result, nil, entry.recipe .. " without materials is refused")
        r:equal(calls, 0, entry.recipe .. " without materials never reaches vanilla")
        r:equal(notices, 1, entry.recipe .. " without materials tells the player once")
        result, calls = start(entry.recipe, true)
        r:check(result == C.SENTINEL and calls == 1, entry.recipe .. " with materials is passed on unchanged", "calls=" .. calls)
        result, calls, notices = start(C.VANILLA_RECIPE, false)
        r:check(result == C.SENTINEL and calls == 1 and notices == 0, "Vanilla " .. C.VANILLA_RECIPE .. " is passed on untouched",
            "calls=" .. calls .. " notices=" .. notices)
        for _, other in ipairs(C.HANDCRAFT) do
            if other ~= entry and S.ModActive(other.mod) then
                result, calls = start(other.recipe, true)
                r:check(result == C.SENTINEL and calls == 1, other.name .. "'s " .. other.recipe .. " passes through " .. entry.name,
                    "calls=" .. calls)
            end
        end
    end

    if hookedMultiple then
        local function multiple(name, canPerform, possible)
            local proxy = C.Proxy(player)
            reached = 0
            local result = C.With({ { ui, entry.multiple, stub } }, function()
                return counting(entry, proxy, function()
                    return ui.HandcraftStartMultiple(proxy, logic(name, canPerform, possible, proxy), false, 2, true)
                end)
            end)
            return result, reached, proxy.notices
        end
        local result, calls, notices = multiple(entry.recipe, true, 1)
        r:check(result == nil and calls == 0 and notices == 1, "Crafting 2 x " .. entry.recipe .. " with materials for 1 is refused",
            "calls=" .. calls .. " notices=" .. notices)
        result, calls = multiple(C.VANILLA_RECIPE, false, 0)
        r:check(result == C.SENTINEL and calls == 1, "Vanilla multi-craft is passed on untouched", "calls=" .. calls)
    end

    if hookedAction then
        local function queued(name)
            local proxy = C.Proxy(player)
            local fake = { craftRecipe = recipe(name), logic = logic(name, false, 0, proxy), character = proxy,
                forceStop = function(self) self.stopped = true end }
            reached = 0
            local result = C.With({ { action, entry.action, stub } }, function()
                return counting(entry, proxy, function() return action.start(fake) end)
            end)
            return result, fake.stopped == true, proxy.notices
        end
        local result, stopped, notices = queued(entry.recipe)
        r:check(result == C.SENTINEL and reached == 1, "A queued " .. entry.recipe .. " still starts normally first", "calls=" .. reached)
        r:check(stopped and notices == 1, "A queued " .. entry.recipe .. " whose materials vanished is stopped with one notice",
            "stopped=" .. tostring(stopped) .. " notices=" .. notices)
        result, stopped = queued(C.VANILLA_RECIPE)
        r:check(result == C.SENTINEL and not stopped, "A queued vanilla craft is not stopped")
    end

    if entry.mod == "SVSBoobyTraps" and type(action.SVSBT_OriginalGetDuration) == "function" then
        local multiplier = SVSBT and SVSBT.Config and SVSBT.Config.Get("CraftingTimeMultiplier") or 1
        local function duration(name)
            return C.With({ { action, "SVSBT_OriginalGetDuration", function() return 100 end } }, function()
                return action.getDuration({ craftRecipe = recipe(name) })
            end)
        end
        r:equal(duration(entry.recipe), math.max(1, 100 * multiplier), "Trap crafting time follows CraftingTimeMultiplier (" .. tostring(multiplier) .. ")")
        r:equal(duration(C.VANILLA_RECIPE), 100, "Vanilla crafting time is unchanged")
    end
end

------------------------------------------------------------
-- TIMED-ACTION REQUIREMENTS
------------------------------------------------------------

C.REQUIREMENTS = {
    { mod = "KIPN", action = "KIPN_RepairComputerAction", label = "Computer repair",
      needs = { "Base.Screwdriver", "Base.KIPNComputerRepairKit" } },
    { mod = "KIPN", action = "KIPN_DisassembleComputerAction", label = "Computer disassembly",
      needs = { "Base.Screwdriver" } },
    { mod = "KIPNGovernmentServices", action = "KIPN_PropertyClaimAction", label = "Property claim",
      needs = { "Base.KIPNPropertyClaimArtifact" } },
    { mod = "KIPNVehicleServices", action = "KIPN_VehicleClaimAction", label = "Vehicle claim",
      needs = { "Base.KIPNVehicleClaimArtifact" } },
}

local function fakeAction(character, command, args)
    return { character = character, command = command, args = args,
        forceStop = function(self) self.stopped = true end,
        setActionAnim = function(self) self.animated = true end,
        setOverrideHandModels = function() end }
end

function C.CheckRequirement(r, player, entry)
    local class = _G[entry.action]
    if not r:check(class ~= nil and type(class.CanStart) == "function", entry.action .. ".CanStart is loaded") then return end
    local empty = C.Proxy(player)
    r:equal(class.CanStart(empty, false), false, entry.label .. " refuses a character without " .. table.concat(entry.needs, " + "))
    r:equal(class.CanStart(C.Proxy(player, entry.needs), false), true, entry.label .. " accepts a character with " .. table.concat(entry.needs, " + "))
    if type(class.start) == "function" then
        local fake = fakeAction(empty)
        class.start(fake)
        r:check(fake.stopped == true and fake.animated == nil and empty.notices >= 1,
            entry.label .. " rechecks at start: stops before animating and tells the player",
            "stopped=" .. tostring(fake.stopped) .. " animated=" .. tostring(fake.animated) .. " notices=" .. empty.notices)
    end
end

-- Device actions whose target item has vanished must stop before animating
-- and never send their command. A missing item id stands in for the vanished item.
function C.CheckDeviceStart(r, player, label, class, client, command, args)
    if not r:check(class ~= nil and type(class.start) == "function", label .. " timed action is loaded") then return end
    local sent = 0
    local swaps = { { client, "Notify", function() end } }
    if type(client.SendCommand) == "function" then
        swaps[#swaps + 1] = { client, "SendCommand", function() sent = sent + 1; return true end }
    end
    local fake = fakeAction(player, command, args)
    C.With(swaps, function() class.start(fake) end)
    r:check(fake.stopped == true, label .. ": a vanished item stops the action at start")
    r:check(fake.animated == nil, label .. ": the recheck happens before the animation starts")
    r:equal(sent, 0, label .. ": nothing is sent to the server")
end

------------------------------------------------------------
-- CURRENCY
------------------------------------------------------------

local function items(values)
    return { size = function() return #values end, get = function(_, index) return values[index + 1] end }
end
local function cashItem(fullType, nested)
    local item = { getFullType = function() return fullType end }
    if nested then item.getInventory = function() return nested end end
    return item
end
local function container(values)
    return { getItems = function() return items(values) end }
end

function C.CheckCurrency(r)
    local G = KIPN_GovernmentServices
    if not r:check(G ~= nil and type(G.countInventoryCash) == "function" and type(G.canAffordInventoryCash) == "function",
        "KIPN_GovernmentServices cash helpers are loaded") then return end
    SandboxVars.KIPN = SandboxVars.KIPN or {}
    local sandbox = SandboxVars.KIPN
    local inventory
    local stand = { getInventory = function() return inventory end }
    C.With({ { sandbox, "ClaimCurrencyItemType", "Base.Money" }, { sandbox, "ClaimCurrencyItemValue", 1 } }, function()
        inventory = container({ cashItem("Base.MoneyBundle"), cashItem("Base.Money"), cashItem("Base.Money"),
            cashItem("Base.Bag_Schoolbag", container({ cashItem("Base.Money") })) })
        r:equal(G.countInventoryCash(stand), 103, "Default currency: a bundle, two loose bills and one in a bag count 103")
        r:equal(G.canAffordInventoryCash(stand, 102), true, "Default currency: 102 is affordable")
        r:equal(G.canAffordInventoryCash(stand, 104), false, "Default currency: 104 is not")
    end)
    C.With({ { sandbox, "ClaimCurrencyItemType", "LilBubby.Token" }, { sandbox, "ClaimCurrencyItemValue", 3 } }, function()
        inventory = container({ cashItem("Base.MoneyBundle"), cashItem("LilBubby.Token"), cashItem("LilBubby.Token") })
        r:equal(G.countInventoryCash(stand), 106, "Configured currency (worth 3): a bundle and two tokens count 106")
        r:equal(G.canAffordInventoryCash(stand, 103), true, "Configured currency: bundle plus one token pays 103")
        r:equal(G.canAffordInventoryCash(stand, 5), false, "Configured currency: 5 cannot be paid exactly")
    end)
    r:info("Sandbox currency settings restored to " .. tostring(sandbox.ClaimCurrencyItemType) .. " x " .. tostring(sandbox.ClaimCurrencyItemValue))
end

------------------------------------------------------------
-- ZONE EDITOR
------------------------------------------------------------

C.ZONE_MODES = { { mod = "KIPN", mode = "KIPN" }, { mod = "BonkZone", mode = "Bonk" },
    { mod = "SatanicTemples", mode = "SO_SatanicTemples" } }

local function modeCounts(editor)
    local counts, combo = {}, editor.modeCombo
    for index = 1, combo:getOptionCount() do
        local data = combo:getOptionData(index)
        counts[data] = (counts[data] or 0) + 1
    end
    return counts
end

function C.CheckZoneEditor(r)
    if not r:check(ISMultiplayerZoneEditor ~= nil and type(ISMultiplayerZoneEditor.ShowEditor) == "function",
        "Vanilla multiplayer zone editor is loaded") then return end
    local opened = ISMultiplayerZoneEditor_instance == nil
    if opened then ISMultiplayerZoneEditor.ShowEditor() end
    local editor = ISMultiplayerZoneEditor_instance
    if not r:check(editor ~= nil and editor.modeCombo ~= nil, "Zone editor window exists") then return end
    local expected = {}
    for _, entry in ipairs(C.ZONE_MODES) do
        if S.ModActive(entry.mod) then expected[#expected + 1] = entry.mode end
    end
    local previous = editor.currentMode
    local function verify(stage)
        local counts = modeCounts(editor)
        for _, mode in ipairs(expected) do
            r:check(editor.mode and editor.mode[mode] ~= nil and counts[mode] == 1,
                stage .. ": exactly one " .. mode .. " mode", "listed " .. tostring(counts[mode] or 0) .. " times")
        end
        for mode, count in pairs(counts) do
            if count > 1 then r:add("FAIL", stage .. ": " .. tostring(mode) .. " is listed " .. count .. " times") end
        end
    end
    local ok, err = pcall(function()
        verify("Opened")
        for _, mode in ipairs(expected) do
            if editor.mode[mode] then
                editor:onSwitchMode(mode)
                ISMultiplayerZoneEditor.OnRolesReceived()
                r:equal(editor.currentMode, mode, "A role refresh keeps " .. mode .. " selected")
                verify("After a role refresh in " .. mode)
            end
        end
        for _ = 1, 3 do ISMultiplayerZoneEditor.OnRolesReceived() end
        verify("After three more role refreshes")
    end)
    if not ok then r:error("Zone editor check stopped: " .. tostring(err)) end
    pcall(function()
        if previous and editor.mode[previous] then editor:onSwitchMode(previous) end
        if opened then editor:close() end
    end)
end

------------------------------------------------------------
-- MENU
------------------------------------------------------------

local results = {}
local function run(player, title, fn)
    local r = C.NewReport(title)
    local ok, err = pcall(fn, r, player)
    if not ok then r:error(tostring(err)) end
    local text = r:text()
    results[player:getPlayerNum()] = text
    print("[LilBubbyCompat] " .. text)
    S.Report(player, "compat", text)
    return r
end

-- Every automatic check for the enabled mods, in one report.
function C.Automatic(r, player)
    for _, entry in ipairs(C.HANDCRAFT) do
        if S.ModActive(entry.mod) then r:info("Crafting hooks: " .. entry.name); C.CheckHandcraft(r, player, entry) end
    end
    for _, entry in ipairs(C.REQUIREMENTS) do
        if S.ModActive(entry.mod) then r:info("Timed action: " .. entry.label); C.CheckRequirement(r, player, entry) end
    end
    if S.ModActive("SVSBoobyTraps") and SVSBT and SVSBT.Client then
        C.CheckDeviceStart(r, player, "Rig mailbox", SVSBTDeviceAction, SVSBT.Client, "RIG_MAILBOX", { itemId = -1 })
    end
    if S.ModActive("SpyVsSpySignalTracker") and SVS and SVS.Signals and SVS.Signals.Client then
        C.CheckDeviceStart(r, player, "RF scan", SVSDeviceAction, SVS.Signals.Client,
            SVS.Signals.Commands and SVS.Signals.Commands.RF_SCAN or "RFScan", { detectorItemId = -1 })
    end
    if S.ModActive("KIPN") and S.ModActive("KIPNGovernmentServices") then
        r:info("Claim fee cash counting"); C.CheckCurrency(r)
    end
end

local function submenu(context, label)
    local option = context:getOptionFromName(label)
    if option and option.subOption then return context:getSubMenu(option.subOption) end
    option = option or context:addOption(label)
    local menu = S.NewMenu()
    context:addSubMenu(option, menu)
    return menu
end

S.Register("compat", function(index, context, objects, test)
    if test then return end
    local player = getSpecificPlayer(index)
    if not player then return end
    local suite = submenu(submenu(context, "lilBubby's Big ol Mod Tester"), "Mod compatibility")
    suite:addOption("Run every automatic check", player, run, "Every automatic check", C.Automatic)
    local crafting = submenu(suite, "Crafting hooks")
    for _, entry in ipairs(C.HANDCRAFT) do
        if S.ModActive(entry.mod) then
            crafting:addOption(entry.name .. ": recipe checks compose with vanilla and other mods", player, run,
                "Crafting hooks: " .. entry.name, function(r, p) C.CheckHandcraft(r, p, entry) end)
        end
    end
    local actions = submenu(suite, "Timed actions")
    for _, entry in ipairs(C.REQUIREMENTS) do
        if S.ModActive(entry.mod) then
            actions:addOption(entry.label .. ": requirements and start recheck", player, run,
                "Timed action: " .. entry.label, function(r, p) C.CheckRequirement(r, p, entry) end)
        end
    end
    if S.ModActive("SVSBoobyTraps") then
        actions:addOption("Rig mailbox: vanished item stops before animating", player, run, "Timed action: Rig mailbox",
            function(r, p) C.CheckDeviceStart(r, p, "Rig mailbox", SVSBTDeviceAction, SVSBT.Client, "RIG_MAILBOX", { itemId = -1 }) end)
    end
    if S.ModActive("SpyVsSpySignalTracker") then
        actions:addOption("RF scan: vanished detector stops before animating", player, run, "Timed action: RF scan",
            function(r, p) C.CheckDeviceStart(r, p, "RF scan", SVSDeviceAction, SVS.Signals.Client,
                SVS.Signals.Commands and SVS.Signals.Commands.RF_SCAN or "RFScan", { detectorItemId = -1 }) end)
    end
    if S.ModActive("KIPN") and S.ModActive("KIPNGovernmentServices") then
        suite:addOption("Claim fees: cash counting with default and configured currency", player, run,
            "Claim fee cash counting", function(r) C.CheckCurrency(r) end)
    end
    local zoneMods = false
    for _, entry in ipairs(C.ZONE_MODES) do zoneMods = zoneMods or S.ModActive(entry.mod) end
    if zoneMods and isClient() then
        suite:addOption("Zone Editor: each mod's mode is listed once and survives role refreshes", player, run,
            "Zone Editor modes", function(r) C.CheckZoneEditor(r) end)
    end
    suite:addOption("Show last result", player, function(p)
        S.Report(p, "compat", results[p:getPlayerNum()] or "No compatibility result yet. Run every automatic check first.")
    end)
end)

return CompatTest
