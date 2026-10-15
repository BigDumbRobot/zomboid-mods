require "LilBubbyShowcase"
require "ISUI/ISContextMenu"
require "DMMTest_Checks"
require "LilBubbyTeleport"

-- Dead Man's Map death test: writes markings to the personal map, kills the
-- character, checks the dropped Annotated Map and the wipe, respawns through
-- the vanilla death screen, then teleports the new character to the corpse.
-- The flow is a coroutine because it spans the death and respawn; this Lua
-- state survives both.
local MODULE = DMMTest.MODULE
local NEW_LIFE = {forename = "DMM", surname = "New Life"}
local results = {}
local runner = nil
local state = {}

local function show(playerNum, text)
    results[playerNum] = text
    print("[" .. MODULE .. "] " .. text)
    LilBubbyShowcase.ReportIndex(playerNum, "dmm", text)
end

local function progress(player, text)
    if player then LilBubbyShowcase.Report(player, "dmm", text, true) end
    if player and not player:isDead() then HaloTextHelper.addText(player, text) end
    print("[" .. MODULE .. "] " .. text)
end

local function waitFor(ms, fn, what)
    local deadline = getTimestampMs() + ms
    -- what: shown in the status banner while this wait lasts.
    local previous = LilBubbyStatus and LilBubbyStatus.notes[0]
    if what and LilBubbyStatus then LilBubbyStatus.Note(0, what) end
    local value
    while true do
        value = fn()
        if value or getTimestampMs() > deadline then break end
        coroutine.yield()
    end
    if what and LilBubbyStatus then LilBubbyStatus.notes[0] = previous end -- a wait inside another keeps the outer note
    return value or nil
end

local function personalAPI()
    return DeadMansMap.Core.openMapSymbols(MapItem.getSingleton())
end

local function checkGroundMaps(report, label, maps, expectedName, captured, authoritative)
    local side = authoritative and "server" or "client"
    if not report:check(label .. ": exactly one new Annotated Map (" .. side .. ")", #maps == 1, "found " .. #maps) then
        return
    end
    local map = maps[1]
    report:check(label .. ": item is Base.Map (" .. side .. ")", map.fullType == "Base.Map", map.fullType)
    report:check(label .. ": map name (" .. side .. ")", map.name == expectedName, map.name)
    report:check(label .. ": loose world object (" .. side .. ")", map.loose == true)
    report:check(label .. ": marked as wiping the personal map (" .. side .. ")", map.wipedFlag == true)
    if authoritative then
        report:check(label .. ": protected from world-item cleanup (" .. side .. ")", map.ignoreRemove == true)
    end
    local difference = DMMTest.compareSymbols(captured, map.symbols)
    report:check(label .. ": every marking copied (" .. side .. ")", difference == nil,
        difference or (#map.symbols .. " markings match"))
end

local function serverVerify(report, player, label, expectedName, captured)
    if not isClient() then return end
    state.verified[label] = nil
    sendClientCommand(player, MODULE, "verify", {label = label})
    local maps = waitFor(15000, function() return state.verified[label] end, "Asking the server to check the dropped map")
    if not report:check(label .. ": server replied", maps ~= nil, maps and nil or "no reply in 15 s") then return end
    checkGroundMaps(report, label, maps, expectedName, captured, true)
end

local function respawn(report, deadPlayer, playerNum)
    waitFor(15000, function() return ISPostDeathUI.instance and ISPostDeathUI.instance[playerNum] end,
        "Waiting for the death screen to open")
    local ok, err = pcall(function()
        ISPostDeathUI.instance[playerNum]:onRespawn()
    end)
    local creation = ok and waitFor(20000, function() return CoopCharacterCreation.instance end,
        "Pressing Respawn: waiting for character creation to open")
    if creation then
        waitFor(5000, function() return CoopMapSpawnSelect.instance end, "Waiting for the spawn selection")
        ok, err = pcall(function()
            CoopMapSpawnSelect.instance:useDefaultSpawnRegion()
            creation.charCreationMain.forenameEntry:setText(NEW_LIFE.forename)
            creation.charCreationMain.surnameEntry:setText(NEW_LIFE.surname)
            creation:accept()
        end)
    end
    if not ok or not creation then
        report:info("Automatic respawn unavailable", tostring(err or "character creation did not open")
            .. ". Create your new character yourself; the test continues when it spawns.")
    end
    return waitFor(600000, function()
        local candidate = getSpecificPlayer(playerNum)
        return candidate and candidate ~= deadPlayer and not candidate:isDead() and candidate
    end, (ok and creation) and "Creating the new character \"DMM New Life\" and waiting for it to spawn"
        or "Create your new character yourself: the test continues when it spawns")
end

local function teleportToCorpse(report, player, death)
    local expected
    if isClient() then
        state.teleport = nil
        sendClientCommand(player, MODULE, "teleport", {})
        local reply = waitFor(10000, function() return state.teleport end, "Asking the server to send you back to the corpse")
        if not reply or reply.refused then
            report:check("Teleport request accepted", false, reply and reply.refused or "no reply in 10 s")
            return false
        end
        expected = tonumber(reply.expected)
    else
        expected = LilBubbyTeleport.Order(player, death.x, death.y, death.z)
    end
    local arrived = waitFor(expected or LilBubbyTeleport.SETTLE_MS, function()
        return LilBubbyTeleport.Arrived(player, death.x, death.y, death.z)
    end, "Arriving at the corpse (the area is loading)")
    report:check("New character teleported to the corpse", arrived ~= nil,
        arrived and (math.floor(player:getX()) .. "," .. math.floor(player:getY()))
        or ("still at " .. math.floor(player:getX()) .. "," .. math.floor(player:getY())))
    return arrived ~= nil
end

local function checkLootPanel(report, playerNum, expectedName)
    local loot = getPlayerLoot(playerNum)
    loot:refreshBackpacks()
    local names = {}
    for _, button in ipairs(loot.backpacks) do
        local items = button.inventory and button.inventory:getItems()
        for i = 0, (items and items:size() or 0) - 1 do
            names[#names + 1] = items:get(i):getName()
        end
    end
    local listed = false
    for _, name in ipairs(names) do listed = listed or name == expectedName end
    report:check("New character sees the map in the Ground loot panel", listed,
        #names .. " ground items: " .. table.concat(names, ", "))
end

local function flow(player)
    local Core = DeadMansMap.Core
    local playerNum = player:getPlayerNum()
    local report = DMMTest.newReport("Dead Man's Map death test")
    runner.report = report
    state = {verified = {}}
    report:info("Session", (isClient() and "multiplayer" or "single-player") .. ", DeadMansMap " .. tostring(Core.VERSION))

    -- 1. Write markings to the personal map.
    local api = personalAPI()
    if not report:check("Personal map symbols API opened", api ~= nil) then return report end
    local before = DMMTest.userSymbolCount(api)
    local written = DMMTest.writeSeed(api, math.floor(player:getX()), math.floor(player:getY()))
    MapItem.SaveWorldMap()
    local captured = DMMTest.serializeAll(api)
    local after = DMMTest.userSymbolCount(api)
    report:check("Test markings written to the personal map", after == before + #written,
        before .. " existing + " .. #written .. " written = " .. after)
    report:check("Test markings read back", DMMTest.countSeeds(written, captured) == #written,
        DMMTest.countSeeds(written, captured) .. "/" .. #written .. " found")

    -- 2. Kill the character.
    local characterName = Core.getCharacterName(player)
    local expectedName = Core.getDeathMapName(characterName)
    local startAge = DMMTest.worldAge()
    progress(player, "Dead Man's Map test: killing " .. characterName)

    state.watching = player
    if isClient() then
        sendClientCommand(player, MODULE, "kill", {})
    else
        player:setGodMod(false)
        player:Kill(nil)
    end
    local death = waitFor(20000, function() return state.death end, "Waiting for the character to die")
    if not report:check("Character died (OnPlayerDeath)", death ~= nil, death and characterName or "no death in 20 s") then
        return report
    end

    -- 3. The Annotated Map is on the ground and the personal map is wiped.
    progress(player, "Dead Man's Map test: checking the dropped Annotated Map")
    waitFor(30000, function()
        return #DMMTest.findDeathMaps(death.x, death.y, death.z, characterName, startAge) > 0
    end, "Waiting for the Annotated Map to drop beside the body")
    waitFor(3000, function() -- until the map's markings have replicated
        local found = DMMTest.findDeathMaps(death.x, death.y, death.z, characterName, startAge)
        return #found == 1 and DMMTest.compareSymbols(captured, found[1].symbols) == nil
    end, "Waiting for the map's markings to arrive")
    local maps = DMMTest.findDeathMaps(death.x, death.y, death.z, characterName, startAge)
    checkGroundMaps(report, "After death", maps, expectedName, captured, not isClient())
    serverVerify(report, player, "After death", expectedName, captured)
    local remaining = DMMTest.userSymbolCount(personalAPI())
    report:check("Dead character's personal map wiped", remaining == 0, remaining .. " markings left")

    -- 4. Make a new character.
    progress(player, "Dead Man's Map test: respawning a new character")
    local newPlayer = respawn(report, player, playerNum)
    if not report:check("New living character spawned", newPlayer ~= nil,
        newPlayer and Core.getCharacterName(newPlayer) or "no new character within 10 minutes") then
        return report
    end
    waitFor(5000, function() local ok = pcall(personalAPI); return ok end, "Opening the new character's map")
    local newCount = DMMTest.userSymbolCount(personalAPI())
    report:check("New character's personal map is empty", newCount == 0, newCount .. " markings")

    -- 5. Teleport the new character to the corpse.
    progress(newPlayer, "Dead Man's Map test: returning to the corpse")
    if not teleportToCorpse(report, newPlayer, death) then return report end
    progress(newPlayer, "Dead Man's Map test: checking the corpse and its map")
    waitFor(5000, function() return DMMTest.findPlayerCorpse(death.x, death.y, death.z, characterName, death.worldAge) end,
        "Looking for the corpse")
    local corpse = DMMTest.findPlayerCorpse(death.x, death.y, death.z, characterName, death.worldAge)
    report:check("Dead character's corpse is at the death site", corpse ~= nil)
    if corpse then
        local linked = corpse:getModData().DMM_HasDeathMap == true
        if isClient() and not linked then
            report:info("Corpse link", "not visible on this client (the corpse tag is best-effort in multiplayer)")
        else
            report:check("Corpse tagged with its Annotated Map", linked)
        end
    end
    maps = DMMTest.findDeathMaps(death.x, death.y, death.z, characterName, startAge)
    checkGroundMaps(report, "At the corpse", maps, expectedName, captured, not isClient())
    serverVerify(report, newPlayer, "At the corpse", expectedName, captured)
    checkLootPanel(report, playerNum, expectedName)
    local laterCount = DMMTest.userSymbolCount(personalAPI())
    report:check("New character's personal map still empty", laterCount == 0, laterCount .. " markings")
    return report
end

------------------------------------------------------------
-- COPY MARKINGS TEST
------------------------------------------------------------

-- The test map, the pen and the writing tools are handled by the server in
-- multiplayer (DMMTest.copySetup / copyGivePen / copyCleanup), so the client
-- works with real synced items and picks the map up off the ground itself.
local HOLD_MS = 4000 -- each viewer state stays on screen this long for screenshots

local function snapshot(name)
    print("[" .. MODULE .. "] SNAPSHOT " .. name)
    waitFor(HOLD_MS, function() return false end, "Holding for a screenshot: " .. name)
end

-- Sends a copy command to the server (multiplayer) or runs it here, and
-- returns the reply table.
local function copyCommand(player, command, reply, args, local_, noWait)
    if not isClient() then return local_() end
    state.copy[reply] = nil
    sendClientCommand(player, MODULE, command, args)
    if noWait then return {returned = "sent"} end
    return waitFor(15000, function() return state.copy[reply] end, "Waiting for the server: " .. command)
end

local function removeCopies(written)
    local api = personalAPI()
    local removed = 0
    for i = api:getSymbolCount() - 1, 0, -1 do
        local data = DeadMansMap.Core.serializeMapSymbol(api:getSymbolByIndex(i))
        if data and DMMTest.countSeeds(written, {data}) == 1 then
            api:removeSymbolByIndex(i)
            removed = removed + 1
        end
    end
    MapItem.SaveWorldMap()
    return removed
end

local function copiesOnPersonalMap(written)
    local found = 0
    for _, data in ipairs(DMMTest.serializeAll(personalAPI())) do
        found = found + DMMTest.countSeeds(written, {data})
    end
    return found
end

-- The test map as a player reaches it: in the Ground loot panel (a world
-- square's item has no container, so vanilla would not pick it up first;
-- the panel's floor container does), or carried. In multiplayer a picked-up
-- item is a new object, so the carried copy is looked up again each time.
local function groundTestMap(player, stamp)
    local deathId = DMMTest.copyDeathId(stamp)
    local loot = getPlayerLoot(player:getPlayerNum())
    loot:refreshBackpacks()
    for _, button in ipairs(loot.backpacks) do
        local items = button.inventory and button.inventory:getItems()
        for i = 0, (items and items:size() or 0) - 1 do
            local item = items:get(i)
            if item:getModData().DMM_DeathId == deathId then return item end
        end
    end
    return nil
end

local function carriedTestMap(player, stamp)
    local deathId = DMMTest.copyDeathId(stamp)
    return player:getInventory():getFirstEvalRecurse(function(item)
        return item:getModData().DMM_DeathId == deathId
    end)
end

local function queueLength(player)
    local queue = ISTimedActionQueue.getTimedActionQueue(player)
    return queue and queue.queue and #queue.queue or 0
end

-- Grabs the map from the Ground panel, as dragging it to the inventory does.
local function pickUp(player, stamp)
    local item = groundTestMap(player, stamp)
    if not item then return nil end
    ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(player, item, item:getContainer(), player:getInventory()))
    return waitFor(15000, function() return carriedTestMap(player, stamp) end, "Picking up the map")
end

-- Drops the carried map with the vanilla Drop option.
local function dropBack(player, stamp)
    local item = carriedTestMap(player, stamp)
    if not item then return nil end
    ISInventoryPaneContextMenu.dropItem(item, player:getPlayerNum())
    return waitFor(15000, function() return not carriedTestMap(player, stamp) and groundTestMap(player, stamp) end,
        "Dropping the map back on the ground")
end

local function contextOption(playerNum, mapItem)
    local context = ISContextMenu.get(playerNum, 100, 100)
    if not context then return nil, {hideAndChildren = function() end} end
    triggerEvent("OnFillInventoryObjectContextMenu", playerNum, context, {mapItem})
    local option = context:getOptionFromName(getText("ContextMenu_DMM_CopyMarkings"))
    return option, context
end

-- Opens a carried map through the vanilla Check Map option.
local function openViewer(mapItem, playerNum)
    local captured
    local originalNew = ISMap.new
    ISMap.new = function(...)
        local o = originalNew(...)
        captured = o
        return o
    end
    local ok, err = pcall(ISInventoryPaneContextMenu.onCheckMap, mapItem, playerNum)
    ISMap.new = originalNew
    if not ok then return nil, tostring(err) end
    -- updateButtons runs from ISMap:update; let a few frames pass.
    if captured then waitFor(1500, function() return false end, "Opening the map viewer") end
    return captured
end

local function closeViewer(mapUI)
    if mapUI and mapUI.wrap then mapUI.wrap:close() end
end

local function click(button)
    button:onMouseDown(2, 2)
    button:onMouseUp(2, 2)
end

local function isRed(color)
    return color and color.r > 0.5 and color.g < 0.5 and color.b < 0.5
end

local function copyFlow(player)
    local playerNum = player:getPlayerNum()
    local report = DMMTest.newReport("Dead Man's Map copy markings test")
    runner.report = report
    state = {verified = {}, copy = {}}
    report:info("Session", (isClient() and "multiplayer" or "single-player") .. ", DeadMansMap " .. tostring(DeadMansMap.Core.VERSION))
    if not report:check("Map merge module loaded", DeadMansMap.MapMerge ~= nil and DeadMansMap.MapMerge.canWrite ~= nil) then
        return report
    end

    -- Setup: a test Annotated Map on the ground beside you, writing tools set aside.
    local stamp = tostring(getTimestampMs())
    local ready = copyCommand(player, "copySetup", "copyReady", {stamp = stamp}, function()
        local written, stashed = DMMTest.copySetup(player, stamp)
        return {written = written, stashed = stashed, error = not written and tostring(stashed) or nil}
    end)
    if not report:check("Test Annotated Map dropped beside you", ready and ready.written and #ready.written > 0,
        ready and (ready.error or (#ready.written .. " markings")) or "no reply from the server in 15 s") then
        return report
    end
    local written = ready.written
    report:info("Writing tools set aside", tostring(ready.stashed))

    -- Kahlua can't yield inside pcall, so cleanup also runs from step() if
    -- the test errors.
    runner.cleanup = function(noWait)
        local removed = removeCopies(written)
        report:check("Cleanup: copied markings removed from the personal map", copiesOnPersonalMap(written) == 0, removed .. " removed")
        local cleaned = copyCommand(player, "copyCleanup", "copyCleaned", {stamp = stamp}, function()
            return {returned = DMMTest.copyCleanup(player, stamp)}
        end, noWait)
        report:check("Cleanup: test map and pen removed, writing tools returned", cleaned ~= nil,
            cleaned and (tostring(cleaned.returned) .. " returned") or "no reply from the server in 15 s")
    end

    local mapItem = waitFor(10000, function()
        local found = groundTestMap(player, stamp)
        local api = found and DeadMansMap.Core.openMapSymbols(found)
        return api and DMMTest.userSymbolCount(api) == #written and found
    end, "Waiting for the test map and its markings to arrive")
    if report:check("Test map in the Ground loot panel with its markings", mapItem ~= nil,
        mapItem and (mapItem:getName() .. " in " .. tostring(mapItem:getContainer() and mapItem:getContainer():getType()))) then
        -- 1. Nothing to write with.
        progress(player, "Copy markings test: no writing tool")
        report:check("canWrite is false with no writing tool", DeadMansMap.MapMerge.canWrite(player) == false)
        local option, context = contextOption(playerNum, mapItem)
        if report:check("Context menu offers Copy Markings (map on the ground)", option ~= nil) then
            report:check("Context option unavailable (red, not clickable)", option.notAvailable == true)
            report:check("Context option explains why", option.toolTip ~= nil and option.toolTip.description == getText("Tooltip_Map_CantWrite"),
                option.toolTip and option.toolTip.description)
        end
        context:hideAndChildren()

        local carried = pickUp(player, stamp)
        report:check("Map picked up from the ground", carried ~= nil)
        local mapUI = carried and openViewer(carried, playerNum)
        local btn = mapUI and mapUI.dmmCopyBtn
        if report:check("Map viewer has the Copy markings button", btn ~= nil) then
            report:check("Button title", btn.title == getText("IGUI_DMM_CopyMarkings_Button"), btn.title)
            report:check("Button visible", btn:getIsVisible() == true)
            report:check("Button disabled", btn.enable == false)
            report:check("Button text red", isRed(btn.textColor),
                string.format("%.2f,%.2f,%.2f", btn.textColor.r, btn.textColor.g, btn.textColor.b))
            report:check("Button tooltip explains why", btn.tooltip == getText("Tooltip_Map_CantWrite"), btn.tooltip)
            report:check("Button right of the vanilla buttons", btn.x >= mapUI.placeSymbBtn:getRight(),
                btn.x .. " >= " .. mapUI.placeSymbBtn:getRight())
            report:check("Button inside the map window", btn:getRight() <= mapUI.width, btn:getRight() .. " <= " .. mapUI.width)
            snapshot("viewer-no-pen")
            click(btn)
            report:check("Clicking the disabled button copies nothing", copiesOnPersonalMap(written) == 0,
                copiesOnPersonalMap(written) .. " copied")
        end
        closeViewer(mapUI)
        if carried then DeadMansMap.MapMerge.onCopyMarkings(carried, playerNum) end
        report:check("Direct copy call refused without a writing tool", copiesOnPersonalMap(written) == 0,
            copiesOnPersonalMap(written) .. " copied")

        -- 2. A plain map gets no button (viewer built but never shown).
        local plain = instanceItem("Base.Map")
        plain:setMapID("MarchRidgeMap")
        local plainUI = ISMap:new(0, 0, 800, 600, plain, playerNum)
        plainUI:initialise()
        plainUI:instantiate()
        report:check("Ordinary map viewer has no Copy button", plainUI.dmmCopyBtn == nil and plainUI.editSymbolsBtn ~= nil)

        -- 3. With a pen: copy straight from the ground, then from the viewer.
        progress(player, "Copy markings test: with a pen")
        local given = copyCommand(player, "copyGivePen", "copyPen", {}, function()
            DMMTest.copyGivePen(player); return {}
        end)
        report:check("Pen given", given ~= nil, not given and "no reply from the server in 15 s" or nil)
        local canWrite = waitFor(10000, function() return DeadMansMap.MapMerge.canWrite(player) end, "Waiting for the pen to arrive")
        report:check("canWrite is true with a pen", canWrite == true)

        local onGround = dropBack(player, stamp)
        report:check("Map dropped back on the ground", onGround ~= nil)
        option, context = contextOption(playerNum, onGround or mapItem)
        local usable = option ~= nil and not option.notAvailable
        report:check("Context option available with a pen", usable)
        context:hideAndChildren()
        if usable then
            option.onSelect(option.target, option.param1, option.param2)
            local copied = waitFor(20000, function() return copiesOnPersonalMap(written) == #written end,
                "Copy Markings from the ground: picking up and copying")
            report:check("Copy from the ground picks the map up and copies every marking", copied == true,
                copiesOnPersonalMap(written) .. "/" .. #written)
            waitFor(3000, function() return queueLength(player) == 0 end, "Waiting for the action queue to empty")
            report:check("No action left stuck in the queue", queueLength(player) == 0, queueLength(player) .. " queued")
            report:check("Map carried after copying", carriedTestMap(player, stamp) ~= nil)
        end
        removeCopies(written)

        carried = carriedTestMap(player, stamp) or pickUp(player, stamp)
        mapUI = carried and openViewer(carried, playerNum)
        btn = mapUI and mapUI.dmmCopyBtn
        if report:check("Map viewer has the Copy markings button (pen)", btn ~= nil) then
            report:check("Button enabled", btn.enable == true)
            report:check("Button text not red", not isRed(btn.textColor))
            report:check("Button has no tooltip", btn.tooltip == nil, btn.tooltip)
            snapshot("viewer-with-pen")
            click(btn)
            report:check("Clicking the button copies every marking", copiesOnPersonalMap(written) == #written,
                copiesOnPersonalMap(written) .. "/" .. #written)
            click(btn)
            report:check("Clicking again adds no duplicates", copiesOnPersonalMap(written) == #written,
                copiesOnPersonalMap(written) .. "/" .. #written)
            snapshot("viewer-after-copy")
        end
        closeViewer(mapUI)
    end

    report:check("Character alive for the whole test", not player:isDead())
    local cleanup = runner.cleanup
    runner.cleanup = nil
    cleanup()
    return report
end

local function step()
    if not runner then return end
    local ok, result = coroutine.resume(runner.co)
    if not ok then
        runner.report = runner.report or DMMTest.newReport(runner.title)
        runner.report:error("Test error", tostring(result))
        if runner.cleanup then
            local cleaned, err = pcall(runner.cleanup, true)
            if not cleaned then runner.report:error("Cleanup error", tostring(err)) end
        end
        result = runner.report
    end
    if not ok or coroutine.status(runner.co) == "dead" then
        local playerNum, title = runner.playerNum, runner.title
        runner = nil
        state.watching = nil
        show(playerNum, result and result:text() or title .. " ended without a report.")
    end
end

local function start(player, which)
    if runner then
        show(player:getPlayerNum(), "A Dead Man's Map test is already running.")
        return
    end
    if player:getVehicle() then
        show(player:getPlayerNum(), "BLOCKED: Exit your vehicle first.")
        return
    end
    local copy = which == "copy"
    runner = {co = coroutine.create(copy and copyFlow or flow), playerNum = player:getPlayerNum(),
        title = copy and "Dead Man's Map copy markings test" or "Dead Man's Map death test"}
    local ok, result = coroutine.resume(runner.co, player)
    if not ok or coroutine.status(runner.co) == "dead" then
        local playerNum = runner.playerNum
        runner = nil
        show(playerNum, ok and result:text() or ("ERROR: " .. tostring(result)))
    end
end

local function submenu(context, label)
    local option = context:getOptionFromName(label)
    if option and option.subOption then return context:getSubMenu(option.subOption) end
    option = option or context:addOption(label)
    local menu = LilBubbyShowcase.NewMenu()
    context:addSubMenu(option, menu)
    return menu
end

LilBubbyShowcase.Register("dmm", function(index, context, objects, test)
    if test or not DMMTest.available() then return end
    local player = getSpecificPlayer(index)
    if not player or player:isDead() then return end
    local tester = submenu(context, "lilBubby's Big ol Mod Tester")
    local suite = submenu(tester, "Dead Man's Map tests")
    suite:addOption("Run copy markings test", player, start, "copy")
    suite:addOption("Run death test (kills this character)", player, start)
    suite:addOption("Show last result", player, function(p)
        show(p:getPlayerNum(), results[p:getPlayerNum()] or "The death test writes markings to your map, kills this character, "
            .. "respawns a new one and teleports it to the corpse. Your existing markings move to the dropped map, as in normal play.")
    end)
end)

Events.OnPlayerDeath.Add(function(player)
    if not state.watching or player ~= state.watching or state.death then return end
    state.death = {
        x = math.floor(player:getX()), y = math.floor(player:getY()), z = math.floor(player:getZ()),
        worldAge = DMMTest.worldAge(),
    }
end)

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= MODULE or type(args) ~= "table" or not runner then return end
    if command == "verified" and type(args.label) == "string" then
        state.verified[args.label] = args.maps or {}
    elseif command == "teleportPending" then
        state.teleport = {x = args.x, y = args.y, z = args.z, expected = args.expected}
    elseif command == "teleportRefused" then
        state.teleport = {refused = tostring(args.reason)}
    elseif (command == "copyReady" or command == "copyPen" or command == "copyCleaned") and state.copy then
        state.copy[command] = args
    end
end)

Events.OnTickEvenPaused.Add(step)
Events.OnFETick.Add(step)
