require "LilBubbyShowcase"
-- Client half of the COMPUTER Safehouse and Land Claims suite: the
-- right-click menu, result display, the client-side follow-up checks the
-- server asks for, and tests of the mod's client-only features.
require "GovSvcTest_Checks"
require "LilBubbyCraft"

local T = GovSvcTest
local MODULE = T.MODULE
local ROOT = "lilBubby's Big ol Mod Tester"
local results = {}
local fillingMenu = false

local function show(player, text)
    results[player:getPlayerNum()] = text
    print("[" .. MODULE .. "] " .. text)
    LilBubbyShowcase.Report(player, "government", text)
end

local function modLoaded()
    return KIPN and KIPN.Shared and KIPN.Shared.Commands and KIPN_PropertyClaimAction ~= nil
end

local function has(text, fragment) return type(text) == "string" and string.find(text, fragment, 1, true) ~= nil end

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------

local function carries(player, fullType)
    return player:getInventory():containsTypeRecurse(fullType)
end

-- Fills a throwaway world context menu for the player's square exactly as a
-- right-click would, and returns the options by name.
local function fillContext(player, preset)
    local context = ISContextMenu.get(player:getPlayerNum(), 0, 0)
    for _, name in ipairs(preset or {}) do context:addOption(name) end
    local objects, list = {}, player:getCurrentSquare():getObjects()
    for i = 0, list:size() - 1 do objects[#objects + 1] = list:get(i) end
    fillingMenu = true
    local ok, err = pcall(triggerEvent, "OnFillWorldObjectContextMenu", player:getPlayerNum(), context, objects, false)
    fillingMenu = false
    local options = {}
    for _, option in ipairs(context.options or {}) do
        if option and option.name then options[option.name] = option end
    end
    pcall(function() context:hideAndChildren() end)
    pcall(function() context:setVisible(false) end)
    return options, ok, err
end

-- Delivers a fake server message to this client's own listeners.
local function injectServer(command, args)
    triggerEvent("OnServerCommand", "KIPN", command, args)
end

local function clientSafehouse(rect)
    local ok, safehouse = pcall(function() return SafeHouse.getSafeHouse(rect.x, rect.y, rect.w, rect.h) end)
    return ok and safehouse or nil
end

local function safehouseHere(player)
    local ok, safehouse = pcall(function() return SafeHouse.getSafeHouse(player:getCurrentSquare()) end)
    if ok and safehouse then return safehouse end
    local list = SafeHouse.getSafehouseList()
    for i = 0, list:size() - 1 do
        local candidate = list:get(i)
        if candidate:getOwner() == player:getUsername() then return candidate end
    end
end

local function membersOf(safehouse)
    local out, list = {}, safehouse:getPlayers()
    for i = 0, list:size() - 1 do out[tostring(list:get(i))] = true end
    return out
end

local function uiOfType(typeName)
    local list = UIManager.getUI()
    for i = 0, list:size() - 1 do
        local element = list:get(i)
        local ok, lua = pcall(function() return element:getTable() end)
        if ok and lua and lua.Type == typeName then return lua end
    end
end

-- Runs fn every tick until it returns true or timeoutMs passes.
local function waitFor(timeoutMs, fn, done)
    local deadline = getTimestampMs() + timeoutMs
    local function tick()
        local ok, finished = pcall(fn)
        if (ok and finished) or getTimestampMs() > deadline then
            Events.OnTick.Remove(tick)
            done(ok and finished == true)
        end
    end
    Events.OnTick.Add(tick)
end

-- Opens the vanilla safehouse panel on a safehouse and checks KIPN's
-- additions, then the boundary viewer it opens.
local function panelChecks(player, r, safehouse)
    local ui = ISSafehouseUI:new(0, 0, 500, 450, safehouse, player)
    local ok, err = pcall(function()
        ui:initialise()
        ui:addToUIManager()
        local button = ui.kipnViewBounds
        if not r:check(button ~= nil, "the safehouse panel has a View KIPN Bounds button") then return end
        ui:updateButtons()
        local enabled = not SandboxVars.KIPN or SandboxVars.KIPN.SafehouseClaimsEnabled ~= false
        r:equal(button:getIsVisible(), enabled, "View KIPN Bounds is shown while KIPN claims are on")
        if enabled and ui.changeOwnership then
            r:check(not ui.changeOwnership:getIsVisible(), "vanilla Change Ownership is hidden")
        end
        ISSafehouseUI.onClick(ui, button)
        local viewer = KIPN_SafehouseAreaUI.instance
        if r:check(viewer ~= nil, "View KIPN Bounds opens the boundary viewer") then
            local target = viewer.target
            r:check(target and target.x == safehouse:getX() and target.y == safehouse:getY()
                and target.w == safehouse:getW() and target.h == safehouse:getH(), "the viewer outlines the safehouse area")
            viewer:close()
            r:check(KIPN_SafehouseAreaUI.instance == nil, "the viewer closes")
        end
    end)
    pcall(function() ui:removeFromUIManager() end)
    if not ok then r:fail("safehouse panel check errored: " .. tostring(err)) end
end

------------------------------------------------------------
-- FOLLOW-UP CHECKS REQUESTED BY THE SERVER
------------------------------------------------------------

local checks = {}
GovSvcTest.ClientChecks = checks

checks.tiers = function(player, r, data)
    local config = KIPN.Server and KIPN.Server.ClaimConfig
    if not r:check(config and config.GetExcavationSizeTiers, "client size tier cache loaded") then return end
    local mine = config.GetExcavationSizeTiers()
    for index, tier in ipairs(data.tiers or {}) do
        local row = mine[index] or {}
        r:check(row.id == tier.id and row.widthTiles == tier.widthTiles and row.heightTiles == tier.heightTiles
            and row.price == tier.price, "client knows the server's " .. tier.id .. " size",
            tostring(row.widthTiles) .. "x" .. tostring(row.heightTiles) .. " $" .. tostring(row.price))
    end
end

-- Crafting takes time, so the result handlers start it with finishWithCraft
-- and report when the form exists; this entry only covers other callers.
checks.craft = function(player, r, data)
    r:info("crafting " .. tostring(data.recipe) .. " runs on your client after this report")
end

checks.cash = function(player, r, data)
    local count = KIPN_GovernmentServices and KIPN_GovernmentServices.countInventoryCash
    if not r:check(count ~= nil, "Government Services screen loaded") then return end
    r:equal(count(player), data.total, "the desk counts the same cash as the server wallet")
    r:check(KIPN_GovernmentServices.canAffordInventoryCash(player, data.total), "the desk says you can pay exactly what you hold")
    r:check(not KIPN_GovernmentServices.canAffordInventoryCash(player, data.total + 1), "the desk says you cannot pay more than you hold")
end

checks.house = function(player, r, data)
    for _, house in ipairs(data.houses or {}) do
        local safehouse = clientSafehouse(house)
        if r:check(safehouse ~= nil, "your client has safehouse " .. tostring(house.id)) then
            r:equal(safehouse:getOwner(), house.owner, "client safehouse owner")
            local square = player:getCurrentSquare()
            local x, y = square:getX(), square:getY()
            if x >= house.x and x < house.x + house.w and y >= house.y and y < house.y + house.h then
                local options = fillContext(player)
                r:check(options[getText("ContextMenu_ViewSafehouse")] ~= nil, "right-click offers View Safehouse here")
            else
                r:info("stand inside safehouse " .. tostring(house.id) .. " to check its right-click menu")
            end
            panelChecks(player, r, safehouse)
        end
    end
end

-- The key the running KIPN files this player's claims under: the server
-- account on current KIPN, the Steam ID on older releases.
local function ownerKey(player)
    if KIPN and KIPN.Shared and KIPN.Shared.IsAccountId then return tostring(KIPN.Shared.GetPlayerId(player)) end
    return tostring(player:getSteamID() or "")
end

checks.land = function(player, r, data)
    local mine = ownerKey(player)
    local square = player:getCurrentSquare()
    local x, y, z = square:getX(), square:getY(), square:getZ()
    for _, area in ipairs(data.areas or {}) do
        local cx, cy = math.floor((area.x1 + area.x2) / 2), math.floor((area.y1 + area.y2) / 2)
        if mine ~= "" and mine ~= "0" then
            r:check(not KIPN_ExcavationAccessEnforcement.IsBlocked(cx, cy, area.z, "Loot"), "you may loot on your own claim " .. tostring(area.id))
            r:check(not KIPN_ExcavationAccessEnforcement.IsBlocked(cx, cy, area.z, "Build"), "you may build on your own claim " .. tostring(area.id))
        else
            r:skip("no Steam ID in this session; own-claim access is only checked on Steam servers")
        end
        if x >= area.x1 and x <= area.x2 and y >= area.y1 and y <= area.y2 and z == area.z then
            local options = fillContext(player)
            r:check(options["View Excavation Site"] ~= nil, "right-click offers View Excavation Site here")
            r:check(options["Show Excavation Bounds"] ~= nil or options["Hide Excavation Bounds"] ~= nil,
                "right-click offers the excavation bounds toggle")
        else
            r:info("stand inside excavation claim " .. tostring(area.id) .. " to check its right-click menu")
        end
    end
end

------------------------------------------------------------
-- CLIENT TESTS
------------------------------------------------------------

local tests = {}
GovSvcTest.ClientTests = tests

tests.c_menu = function(player, r, finish)
    local square = player:getCurrentSquare()
    local inside = square:getBuilding() ~= nil
    local options, ok, err = fillContext(player)
    r:check(ok, "the right-click menu builds without errors", err)
    local deed = carries(player, "Base.KIPNPropertyClaimArtifact")
    local claimHere = options["Claim This Location (KIPN)"] ~= nil
    r:equal(claimHere, deed and inside, "Claim This Location appears only with a deed inside a building")
    local permit = carries(player, "Base.KIPNExcavationClaimArtifactSmall") or carries(player, "Base.KIPNExcavationClaimArtifactMedium")
        or carries(player, "Base.KIPNExcavationClaimArtifactLarge") or carries(player, "Base.KIPNExcavationClaimArtifact")
    r:equal(options["Claim Land (KIPN Excavation)"] ~= nil, permit, "Claim Land appears only with a permit")
    if not deed then r:info("hold a Safehouse Deed inside a building to see Claim This Location") end
    if not permit then r:info("hold an Excavation Permit to see Claim Land") end
    finish()
end

tests.c_gate = function(player, r, finish)
    local claimText = getText("ContextMenu_SafehouseClaim")
    local options = fillContext(player, { claimText })
    local option = options[claimText]
    local enabled = not SandboxVars.KIPN or SandboxVars.KIPN.SafehouseClaimsEnabled ~= false
    if r:check(option ~= nil, "the vanilla option is present to test") then
        if enabled then
            r:check(option.notAvailable == true, "vanilla Claim Safehouse is disabled while KIPN claims are on")
            r:check(option.toolTip and has(option.toolTip.description, "Safehouse Deed"), "its tooltip points to the Safehouse Deed")
        else
            r:check(option.notAvailable ~= true, "vanilla Claim Safehouse stays usable when KIPN claims are off")
        end
    end
    finish()
end

tests.c_access = function(player, r, finish)
    local enforcement = KIPN_ExcavationAccessEnforcement
    local sv = SandboxVars.KIPN or {}
    local x, y, z = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local foreign = { x1 = x - 2, y1 = y - 2, x2 = x + 2, y2 = y + 2, z = z, ownerSteamId = "lilbubby-other-owner" }
    injectServer(KIPN.Shared.Commands.SERVER_RESPONSE, { event = "KIPN_ExcavationAreas", data = { areas = { foreign } } })
    r:equal(enforcement.IsBlocked(x, y, z, "Loot"), sv.ExcavationAllowNonOwnerLoot == false, "looting on someone else's claim follows the sandbox")
    r:equal(enforcement.IsBlocked(x, y, z, "Build"), sv.ExcavationAllowNonOwnerBuild == false, "building on someone else's claim follows the sandbox")
    r:check(not enforcement.IsBlocked(x + 10, y, z, "Loot"), "outside the claim nothing is blocked")
    r:check(not enforcement.IsBlocked(x, y, z + 1, "Loot"), "another floor is not blocked")
    local options = fillContext(player)
    if sv.ExcavationAllowNonOwnerBuild == false then
        local stripped = true
        for _, name in ipairs({ "Disassemble", "Dismantle", "Pick Up", "Dig" }) do
            if options[name] then stripped = false end
        end
        r:check(stripped, "dismantle, pick up and dig options are removed on someone else's claim")
    end
    local mine = ownerKey(player)
    if mine ~= "" and mine ~= "0" then
        foreign.ownerSteamId = mine
        injectServer(KIPN.Shared.Commands.SERVER_RESPONSE, { event = "KIPN_ExcavationAreas", data = { areas = { foreign } } })
        r:check(not enforcement.IsBlocked(x, y, z, "Loot"), "your own claim is never blocked")
    end
    sendClientCommand("KIPN", "RequestExcavationAreas", {})
    r:info("real claim areas requested back from the server")
    finish()
end

tests.c_placement = function(player, r, finish)
    local overlay = KIPN_ExcavationPlacementOverlay
    KIPN_ExcavationPlacementOverlay.Activate(player, "huge")
    r:check(uiOfType("KIPN_ExcavationPlacementOverlay") == nil, "an invalid size does not open placement")
    overlay.Activate(player, "small")
    waitFor(5000, function() return uiOfType("KIPN_ExcavationPlacementOverlay") ~= nil end, function(opened)
        local active = uiOfType("KIPN_ExcavationPlacementOverlay")
        if r:check(opened, "placement preview opens for a Small permit") then
            local tier = KIPN.Server.ClaimConfig.GetExcavationSizeTierById("small")
            r:check(active.sizeClass == "small", "the preview uses the Small class")
            r:info("preview label " .. tostring(active.tierLabel) .. " | server size " .. tostring(tier and tier.label))
        end
        overlay.Deactivate("lilbubby_test")
        r:check(uiOfType("KIPN_ExcavationPlacementOverlay") == nil, "placement preview closes")
        finish()
    end)
end

tests.c_panel = function(player, r, finish)
    local safehouse = safehouseHere(player)
    if not safehouse then
        r:skip("stand in a safehouse or run Claim this building first")
    else
        panelChecks(player, r, safehouse)
    end
    finish()
end

------------------------------------------------------------
-- RUNNING
------------------------------------------------------------

local function applyClientCheck(player, r, clientCheck)
    local check = clientCheck and checks[clientCheck.name]
    if not check then return end
    local section = T.NewReport("client")
    local ok, err = pcall(check, player, section, clientCheck.data or {})
    if not ok then section:fail("client check errored: " .. tostring(err)) end
    r.lines[#r.lines + 1] = "-- on your client --"
    r:merge(section)
end

-- Rebuilds a report from the server's text so client checks can be appended.
local function reportFromText(id, text, clientCheck, player)
    local entry = T.CatalogById[id]
    local r = T.NewReport(entry and entry.label or id)
    local body = string.match(text or "", "^[^\n]*\n[^\n]*\n\n(.*)$") or text or ""
    for line in string.gmatch(body, "[^\n]+") do
        local status, label = string.match(line, "^(%u+): (.*)$")
        if status and r.counts[status] then r:add(status, label) else r.lines[#r.lines + 1] = line end
    end
    applyClientCheck(player, r, clientCheck)
    return r
end

local function runClient(player, id)
    local r = T.NewReport(T.CatalogById[id].label)
    if not modLoaded() then
        r:fail("Enable KIP Network Terminal and COMPUTER Safehouse and Land Claims to run this suite.")
        show(player, r:text())
        return
    end
    local ok, err = pcall(tests[id], player, r, function() show(player, r:text()) end)
    if not ok then
        r:fail("test errored: " .. tostring(err))
        show(player, r:text())
    end
end

-- A crafting test ends with the real craft on this client; its report is
-- shown once the crafted form is in the inventory (or the craft fails).
local function finishWithCraft(player, r, clientCheck)
    if not (clientCheck and clientCheck.name == "craft") then return false end
    local data = clientCheck.data or {}
    LilBubbyShowcase.Report(player, "government", "Crafting " .. tostring(data.recipe) .. " with the normal timed action...", true)
    LilBubbyCraft.Craft(player, data.recipe, data.output, function(ok, detail)
        r.lines[#r.lines + 1] = "-- on your client --"
        r:check(ok, "crafted " .. tostring(data.output) .. " from the crafting menu recipe", detail)
        show(player, r:text())
    end)
    return true
end

local function run(player, id)
    local entry = T.CatalogById[id]
    if entry.side == "client" then
        runClient(player, id)
    elseif isClient() then
        sendClientCommand(player, MODULE, "run", { id = id })
        HaloTextHelper.addText(player, "Running: " .. entry.label)
    else
        local r = GovSvcTest.RunServer(player, id)
        if finishWithCraft(player, r, r.clientCheck) then return end
        applyClientCheck(player, r, r.clientCheck)
        show(player, r:text())
    end
end

local function submenu(context, label)
    local existing = context:getOptionFromName(label)
    if existing and existing.subOption then return context:getSubMenu(existing.subOption) end
    local option = context:addOption(label)
    local menu = LilBubbyShowcase.NewMenu()
    context:addSubMenu(option, menu)
    return menu
end

LilBubbyShowcase.Register("government", function(index, context, objects, test)
    if test or fillingMenu then return end
    local player = getSpecificPlayer(index)
    if not player then return end
    local suite = submenu(submenu(context, ROOT), T.SUITE)
    local groups = {}
    for _, entry in ipairs(T.Catalog) do
        local menu = suite
        if entry.group then
            groups[entry.group] = groups[entry.group] or submenu(suite, entry.group)
            menu = groups[entry.group]
        end
        local option = menu:addOption(entry.label, player, run, entry.id)
        -- Desk tests use the designated government zone: the showcase moves you there first.
        if entry.id == "desk_deed" or entry.id:find("^desk_permit_") or entry.id:find("^renew_") then option.site = "government" end
    end
    suite:addOption("Show last result", player, function(p)
        show(p, results[p:getPlayerNum()] or "No result yet. Start with Run every automatic check.")
    end)
end)

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= MODULE or command ~= "result" or type(args) ~= "table" then return end
    for index = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(index)
        if player and player:getOnlineID() == args.playerID then
            if args.clientCheck and args.clientCheck.name == "craft" then
                finishWithCraft(player, reportFromText(args.id, args.text, nil, player), args.clientCheck)
                return
            end
            local r = reportFromText(args.id, args.text, args.clientCheck, player)
            show(player, args.clientCheck and r:text() or (args.text or "No result"))
            return
        end
    end
end)
