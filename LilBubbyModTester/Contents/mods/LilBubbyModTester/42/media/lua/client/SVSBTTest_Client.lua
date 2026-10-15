require "LilBubbyShowcase"
require "LilBubbyCraft"
require "SVSBTRecipeUI"
require "SVSBTTest_Traps"
require "SVSBTTrapTestUI"

-- Spy vs Spy suite:
--   See all recipes      read-only list of every trap's ingredients
--   <one entry per trap> 1. The recipe and its MAD Magazine (OK/Cancel).
--                        2. The server gives the ingredients, the magazine
--                           (always) and the car, mailbox or skill book the
--                           trap is used on. Unless both this client and the
--                           server already know the recipe, the player reads
--                           the magazine; the test moves on by itself once
--                           both know it. While the player crafts, the window
--                           says what still blocks the craft, and the test
--                           moves on once the trap is crafted (or on OK).
--                           Then they set it and set it off, told each step
--                           in a large message; the server watches the mod's
--                           registry to see each step happen.
--                        3. CLEANUP_TICKS after the detonation a screen covers
--                           the game until the player cleans the test up.
--   Clean up this test   removes everything the test gave or placed
-- Cancel at any step cleans up and returns to the showcase. During Run every
-- test the windows are skipped and the trap is crafted automatically.
local T = SVSBTTest.Traps
local UI = SVSBTTrapTestUI
local ID = "spy"
local REPLY_MS = 30000
local POLL_MS = 1500         -- how often the server is asked about the set trap
local CLEANUP_TICKS = 600    -- from the detonation to the cleanup screen

local active -- the trap test on screen: { playerNum, trap, window }
local pending, nextId = {}, 0

local function show(player, text)
    print("[" .. T.MODULE .. "] " .. text)
    LilBubbyShowcase.Report(player, ID, text)
end

local function progress(player, text)
    print("[" .. T.MODULE .. "] " .. text)
    LilBubbyShowcase.Report(player, ID, text, true)
end

local function knowsHere(player, recipe)
    local ok, known = pcall(function() return player:getKnownRecipes():contains(recipe) end)
    return ok and known == true
end

local function carried(player, fullType)
    local ok, n = pcall(function() return player:getInventory():getCountTypeRecurse(fullType) end)
    return ok and n or 0
end

local function autoRunning()
    return LilBubbyAutoRun and LilBubbyAutoRun.Running and LilBubbyAutoRun.Running() or false
end

-- Runs a server operation (directly in single player); done(reply).
local function op(player, name, args, done)
    args = args or {}
    if not isClient() then
        local ok, result = pcall(T.OPS[name], player, args)
        done(ok and (result or {}) or { error = tostring(result) })
        return
    end
    nextId = nextId + 1
    args.id = nextId
    pending[nextId] = { done = done, deadline = getTimestampMs() + REPLY_MS, name = name }
    sendClientCommand(player, T.MODULE, name, args)
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= T.MODULE or command ~= "reply" or type(args) ~= "table" then return end
    local request = args.id and pending[args.id]
    if not request then return end
    pending[args.id] = nil
    pcall(request.done, args)
end)

Events.OnTick.Add(function()
    local now
    for id, request in pairs(pending) do
        now = now or getTimestampMs()
        if now > request.deadline then
            pending[id] = nil
            pcall(request.done, { error = "no reply from the server (" .. request.name .. ") in " .. (REPLY_MS / 1000) .. " s" })
        end
    end
end)

------------------------------------------------------------
-- The test
------------------------------------------------------------

local function closeWindow()
    if not active then return end
    UI.Close(active.window)
    active.window = nil
    -- The cleanup screen holds the player still; however it closes, let go.
    if active.blocked then
        local held = getSpecificPlayer(active.blocked)
        if held then pcall(function() held:setBlockMovement(false) end) end
        active.blocked = nil
    end
end

-- Ends the test on screen: the result goes to the showcase, which reopens.
local function finish(player, text)
    closeWindow()
    active = nil
    show(player, text)
    if not autoRunning() then LilBubbyShowcase.Open(player) end
end

local function cleanupText(reply, cancelled)
    if reply.error then return "ERROR: cleanup failed: " .. reply.error end
    local parts = { tostring(reply.removed or 0) .. " item(s) removed from your inventory" }
    if (reply.crafted or 0) > 0 then parts[#parts + 1] = "including " .. reply.crafted .. " crafted trap(s)" end
    if (reply.traps or 0) > 0 then parts[#parts + 1] = reply.traps .. " trap(s) you set removed" end
    if (reply.vehicle or 0) > 0 then parts[#parts + 1] = "the test car removed" end
    if (reply.mailbox or 0) > 0 then parts[#parts + 1] = "the test mailbox removed" end
    return (cancelled and "INFO: Test cancelled and cleaned up: " or "PASS: Cleaned up: ")
        .. table.concat(parts, ", ") .. ". Skills raised for a craft are kept."
end

-- Cancel at any phase: back to the showcase straight away; the cleanup
-- result follows when the server has done it.
local function cancel(player, deposited)
    closeWindow()
    local trap = active and active.trap
    active = nil
    LilBubbyShowcase.Open(player)
    if not deposited then
        show(player, "INFO: " .. (trap and trap.name or "Trap") .. " test cancelled. Nothing was given or placed.")
        return
    end
    op(player, "cleanup", {}, function(reply) show(player, cleanupText(reply, true)) end)
end

local function depositDetails(reply)
    local lines = {}
    if reply.magazine then
        lines[#lines + 1] = reply.magazine .. " is in your inventory" .. (reply.readIt and ": read it first." or " (your character already knows the recipe).")
    end
    if reply.raised and #reply.raised > 0 then
        lines[#lines + 1] = "Skills raised so you can craft it: " .. table.concat(reply.raised, ", ") .. "."
    end
    if reply.vehicle then
        lines[#lines + 1] = "A car is parked beside you, full of gas (" .. tostring(reply.vehicle.fuel)
            .. " L); its key is in your inventory."
    end
    if reply.mailbox then lines[#lines + 1] = "A mailbox has been placed beside you." end
    if reply.document then lines[#lines + 1] = "A skill book to contaminate, " .. reply.document .. ", is in your inventory." end
    if reply.given and #reply.given > 0 then
        lines[#lines + 1] = "Given: " .. table.concat(reply.given, ", ") .. "."
    else
        lines[#lines + 1] = "You already carried every ingredient; nothing extra was needed."
    end
    for _, note in ipairs(reply.notes or {}) do lines[#lines + 1] = "Note: " .. note end
    return lines
end

local function verified(trap, reply)
    return "PASS: " .. trap.name .. ": crafted " .. tostring(reply.outputName) .. " (" .. tostring(reply.count)
        .. " in your inventory)."
end

local function instructions(trap)
    return T.INSTRUCTIONS[trap.kind] or { set = "Set it with its normal right-click menu, then walk at least 2 tiles away so it arms.",
        detonate = "Set it off the way it is meant to be set off." }
end

-- The trap would ignore the player (the sandbox protects players).
local function harmless()
    local ok, on = pcall(function() return SVSBT.Config.Get("TargetPlayers") end)
    return ok and on == false
end

-- Step 3: after the detonation, a screen that must be cleaned up.
local function cleanupScreen(player)
    closeWindow()
    local playerNum = active.playerNum
    if player then pcall(function() player:setBlockMovement(true) end) end
    active.blocked = playerNum
    active.window = UI.ShowCleanup(function()
        local me = getSpecificPlayer(playerNum) or player
        closeWindow()
        active = nil
        progress(me, "Removing everything the trap test gave or placed")
        op(me, "cleanup", {}, function(reply) show(me, cleanupText(reply, false)) end)
    end)
end

local function detonated(player, trap, reply)
    active.polling = false
    active.window:change({ headline = { "Congrats! Your trap was detonated." }, warning = false,
        details = { "If you are still alive, you can select another trap from the menu." }, problem = false,
        ok = false, cancel = false })
    show(player, "PASS: " .. trap.name .. ": crafted, set and detonated"
        .. (reply.removed and " (the trap is gone from the mod's registry)" or "") .. ".")
    active.cleanupIn = CLEANUP_TICKS
end

-- Each answer from the server moves the message on to the next step.
local function onStatus(player, trap, reply)
    if not active or active.trap ~= trap then return end
    if reply.error then finish(player, "ERROR: " .. trap.name .. ": " .. reply.error); return end
    local steps = instructions(trap)
    if reply.stage == "detonated" then detonated(player, trap, reply); return end
    if reply.stage == "set" and active.stage ~= "set" then
        active.stage = "set"
        progress(player, trap.name .. ": set. Now set it off")
        local details = { steps.detonate }
        if harmless() then
            details[#details + 1] = "Note: this server's sandbox has TargetPlayers off, so the trap cannot hurt you; a zombie or animal has to set it off."
        end
        active.window:change({ headline = { "Your trap is set.", "Here's how to detonate it." },
            warning = "*Warning - you may die*", details = details, problem = false, ok = false })
    elseif reply.stage == "sealed" and active.stage ~= "sealed" then
        active.stage = "sealed"
        progress(player, trap.name .. ": set, still sealed. Now open it")
        active.window:change({ headline = { "Your sample is set, still sealed.", "Now open it." },
            details = { steps.open or "Open it with its right-click menu." }, problem = false, ok = false })
    elseif reply.stage == "placed" and active.stage ~= "placed" then
        local opened = active.stage == "sealed"
        active.stage = "placed"
        if opened then
            active.window:change({ headline = { "Your sample is open." },
                details = { "Walk at least 2 tiles away from it so it arms." }, problem = false })
        else
            active.window:change({ problem = "Placed. Walk at least 2 tiles away from it so it arms." })
        end
    elseif reply.stage == "none" and active.stage ~= "none" then
        active.stage = "none"
        active.window:change({ problem = false })
    end
end

-- After the craft: set the trap. The server is asked every POLL_MS.
local function setPhase(player, trap, result)
    -- A step, not the result: the test runs on until the detonation.
    progress(player, verified(trap, result):gsub("^PASS: ", "") .. " Now set it.")
    active.window:change({ headline = { "Now set your trap." }, details = { instructions(trap).set },
        problem = false, ok = false })
    active.stage, active.polling, active.nextPoll = "none", true, 0
    active.onStatus = function(reply) onStatus(player, trap, reply) end
end

-- What the craft still needs, as the game's craft window sees it.
local function craftStatus(player, trap, outputName)
    local d = LilBubbyCraft.Diagnose(player, trap.recipe)
    if d.ready then
        return { ready = true, text = "Ready to craft: open the crafting menu, SVSBoobyTraps category, and craft "
            .. tostring(outputName or trap.name) .. "." }
    end
    return { ready = false, text = "Cannot craft it yet: " .. table.concat(d.reasons, "; ") .. "." }
end

-- The player crafts. The window says what still blocks the craft, and the
-- test moves on as soon as the trap is in the inventory (or on OK).
local function craftPhase(player, trap, reply)
    progress(player, trap.name .. ": craft your trap")
    local window, checking
    local before = reply.output and carried(player, reply.output) or 0
    -- quiet: the trap was seen here; the server may not have it yet.
    local function check(quiet)
        if checking then return end
        checking = true
        op(player, "verify", {}, function(result)
            checking = false
            if not active or active.window ~= window or active.polling then return end
            if result.error then finish(player, "ERROR: " .. trap.name .. ": " .. result.error); return end
            if result.crafted then active.tick = nil; setPhase(player, trap, result); return end
            if quiet then return end
            window:setProblem("No " .. tostring(result.outputName) .. " in your inventory yet. Craft it, then click OK.")
        end)
    end
    window = UI.ShowMessage({ headline = { "Items have been deposited into your inventory.", "Craft your trap then click OK." },
        details = depositDetails(reply), status = craftStatus(player, trap, reply.outputName) },
        function() check(false) end, function() cancel(player, true) end)
    active.window = window
    active.tick = function(me)
        if active.window ~= window then return end
        local status = craftStatus(me, trap, reply.outputName)
        if not window.spec.status or window.spec.status.text ~= status.text then window:change({ status = status }) end
        if reply.output and carried(me, reply.output) > before then check(true) end
    end
end

-- The recipe is not known on both sides yet: the player reads the magazine.
-- The server is asked every POLL_MS (bringing the two sides into line, see
-- T.Learned) and the test moves on once both know it; OK asks at once.
local function readPhase(player, trap, reply)
    local magazine = tostring(reply.magazine or "the MAD Magazine")
    progress(player, trap.name .. ": read " .. magazine)
    reply.readIt = true
    local details = { "It is in your inventory: right-click it and choose Read, and let your character finish reading it." }
    for _, line in ipairs(depositDetails(reply)) do details[#details + 1] = line end
    local craftReply = {}
    for key, value in pairs(reply) do craftReply[key] = value end
    craftReply.readIt = nil
    local window, checking
    local function check(me)
        if checking then return end
        checking = true
        local here = knowsHere(me, trap.recipe)
        op(me, "learned", { clientKnows = here }, function(result)
            checking = false
            if not active or active.window ~= window then return end
            if result.error then finish(me, "ERROR: " .. trap.name .. ": " .. result.error); return end
            here = knowsHere(me, trap.recipe)
            if result.known and here then
                active.tick = nil
                closeWindow()
                craftPhase(me, trap, craftReply)
                return
            end
            local status
            if result.known then status = "The server knows the recipe; waiting for your character to learn it by reading " .. magazine .. "."
            elseif here then status = "Your character knows the recipe; waiting for the server to confirm it."
            else status = "Waiting for you to read " .. magazine .. "." end
            if not window.spec.status or window.spec.status.text ~= status then
                window:change({ status = { text = status, ready = false } })
            end
        end)
    end
    window = UI.ShowMessage({ headline = { "Read " .. magazine .. ".", "The test moves on once your character knows the recipe." },
        details = details, status = { text = "Waiting for you to read " .. magazine .. ".", ready = false } },
        function() check(player) end,
        function() cancel(player, true) end)
    active.window = window
    active.tick = check
end

-- The server gives the ingredients.
local function depositPhase(player, trap)
    closeWindow()
    progress(player, trap.name .. ": putting the ingredients in your inventory")
    local mine = active
    op(player, "deposit", { recipe = trap.recipe }, function(reply)
        if active ~= mine then return end
        if reply.error then
            finish(player, (reply.status or "ERROR") .. ": " .. trap.name .. ": " .. reply.error)
            return
        end
        if reply.known and knowsHere(player, trap.recipe) then craftPhase(player, trap, reply)
        else readPhase(player, trap, reply) end
    end)
end

-- Runs the phase's own check every POLL_MS, asks about the set trap, and
-- counts down to the cleanup screen.
Events.OnTick.Add(function()
    if not active then return end
    local player = getSpecificPlayer(active.playerNum)
    if active.tick and player and getTimestampMs() >= (active.nextTick or 0) then
        active.nextTick = getTimestampMs() + POLL_MS
        local ok, err = pcall(active.tick, player)
        if not ok then print("[" .. T.MODULE .. "] " .. tostring(err)) end
    end
    if active.cleanupIn then
        active.cleanupIn = active.cleanupIn - 1
        if active.cleanupIn <= 0 then
            active.cleanupIn = nil
            cleanupScreen(player)
        end
        return
    end
    if not active.polling or active.asking or not player then return end
    local now = getTimestampMs()
    if now < active.nextPoll then return end
    active.asking, active.nextPoll = true, now + POLL_MS
    local mine = active
    op(player, "status", {}, function(reply)
        mine.asking = false
        if active == mine and mine.polling then mine.onStatus(reply) end
    end)
end)

-- Run every test: no windows; the trap is crafted for the player.
local function craftAutomatically(player, trap, reply)
    progress(player, trap.name .. ": crafting it")
    LilBubbyCraft.Craft(player, trap.recipe, reply.output, function(ok, detail)
        if not ok then finish(player, "FAIL: " .. trap.name .. ": " .. tostring(detail)); return end
        op(player, "verify", {}, function(result)
            if result.error then finish(player, "ERROR: " .. trap.name .. ": " .. result.error)
            elseif result.crafted then finish(player, verified(trap, result) .. " Setting and detonating it are left to you: start this trap from the menu.")
            else finish(player, "FAIL: " .. trap.name .. ": the server sees no " .. tostring(result.outputName) .. " in your inventory") end
        end)
    end)
end

local function automatic(player, trap)
    progress(player, trap.name .. ": putting the ingredients in your inventory")
    op(player, "deposit", { recipe = trap.recipe }, function(reply)
        if reply.error then finish(player, (reply.status or "ERROR") .. ": " .. trap.name .. ": " .. reply.error); return end
        -- Brings the server and this client into line on the recipe first.
        op(player, "learned", { clientKnows = knowsHere(player, trap.recipe) }, function(learned)
            if learned.error then finish(player, "ERROR: " .. trap.name .. ": " .. learned.error); return end
            if not learned.known then
                finish(player, "BLOCKED: " .. trap.name .. ": the recipe is not known; preparation should have taught it.")
                return
            end
            craftAutomatically(player, trap, reply)
        end)
    end)
end

local function start(player, trap)
    closeWindow() -- a new trap test replaces one still on screen
    active = { playerNum = player:getPlayerNum(), trap = trap }
    if autoRunning() then automatic(player, trap); return end
    progress(player, trap.name .. ": review the recipe, then click OK")
    active.window = UI.ShowRecipe(player, trap,
        function() depositPhase(player, trap) end,
        function() cancel(player, false) end)
end

local function cleanup(player)
    closeWindow()
    active = nil
    progress(player, "Removing everything the trap test gave or placed")
    op(player, "cleanup", {}, function(reply) show(player, cleanupText(reply, false)) end)
end

-- Read-only: every trap's ingredients and what you carry. During Run every
-- test the window is left closed and only the report is written.
local function showRequirements(player)
    local text = SVSBTRecipeUI.Text(player)
    if not autoRunning() then SVSBTRecipeUI.Show(player) end
    show(player, text)
end

local function submenu(context, label)
    local option = context:addOption(label)
    local menu = LilBubbyShowcase.NewMenu()
    context:addSubMenu(option, menu)
    return menu
end

LilBubbyShowcase.Register(ID, function(index, context, objects, test)
    if test or not T.Available() then return end
    local player = getSpecificPlayer(index)
    if not player then return end
    local label = "lilBubby's Big ol Mod Tester"
    local root = context:getOptionFromName(label)
    local tester = root and root.subOption and context:getSubMenu(root.subOption) or submenu(context, label)
    local suite = submenu(tester, "Spy vs Spy tests")
    suite:addOption("See all recipes", player, showRequirements)
    local traps = submenu(suite, "Trap tests")
    local nameOf = function(kind) return SVSBT.Client and SVSBT.Client.KindName(kind) or kind end
    for _, trap in ipairs(T.List(nameOf)) do
        local option = traps:addOption(trap.name, player, start, trap)
        if not T.Enabled(trap) then
            option.notAvailable = true
            option.unavailableReason = "This trap is switched off in the server's sandbox settings."
        end
    end
    suite:addOption("Clean up this test", player, cleanup)
end)
