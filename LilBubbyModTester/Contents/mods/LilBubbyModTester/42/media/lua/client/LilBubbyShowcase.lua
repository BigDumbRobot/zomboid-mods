-- Shared catalog and session state. UI is loaded only when opened.
LilBubbyShowcase = LilBubbyShowcase or { builders = {}, sessions = {}, windows = {} }
local S = LilBubbyShowcase
-- requires: every listed mod ID must be enabled. anyOf: at least one must be.
-- A suite is only listed when its mods are enabled.
local TRAVEL = "Moves use the game's own teleport. On servers with the speed anti-cheat enabled you travel in short hops (about 8 tiles a second) so the server never kicks you."
S.Mods = {
    { id = "all", name = "Run every test", anySuite = true,
      description = "Prepare your character, then run every feature of every enabled suite while you watch.",
      guide = "1. Stand somewhere lit, outdoors near open flat ground, with a vehicle close by if you have the vehicle mods.\n2. Start Run every test. The showcase closes and a small strip in the bottom-left corner shows each step and result while you watch.\n\nPreparation raises the skills the enabled mods need to level " .. 10 .. ", gives you their magazines and has your character read each one; anything still unknown is taught directly, and the magazines are removed afterwards. Every feature then runs in turn through the normal suites, one at a time, with a summary at the end. Features that need a target you do not have (a trap, a post office box) are reported as SKIP with the reason. The run can teleport you, injure you, change the time of day and, last of all, kill your character for the Dead Man's Map test. Stop the run ends it after the current test." },
    { id = "bonk", name = "Bonk Zone", requires = { "BonkZone" },
      description = "Try protected PvP zones with real server hits.",
      guide = "1. Take me to the designated test zone (or teleport to any Bonk Zone).\n2. Try a single shot, then a burst. You hear every shot the server fires at you, and each weapon is reported as it finishes.\n3. Return to where you started.\n\nRequires multiplayer and the designated test zone (see Test sites) or another Bonk Zone. Failed protection can injure you; tests stop at the first failure. Cancel running test stops a shot sequence. " .. TRAVEL },
    { id = "spy", name = "Spy vs Spy", requires = { "SVSBoobyTraps" },
      description = "See every trap's recipe, then craft, set and set off each trap with everything it needs handed to you.",
      guide = "1. See all recipes opens a read-only list of every trap's ingredients, with what you carry.\n2. Choose a trap under Trap tests. You see its ingredients, the MAD Magazine that teaches it and a synopsis of the test; click OK.\n3. The server tops up your inventory with what is missing, always gives you the magazine, and raises skills the recipe needs. Vehicle devices get a car beside you with its key and a full tank; the explosive parcel gets a mailbox; anthrax gets a skill book to contaminate.\n4. Read the magazine unless your character already knows the recipe; the test moves on once both your character and the server know it.\n5. Craft the trap yourself. The window says what still blocks the craft, and the test moves on once the trap is in your inventory.\n6. A large message tells you where and how to set it; once it is armed, the next tells you how to set it off (you may die). The server sees each step happen.\n7. After the detonation a screen covers the game until you click Clean up this test.\n\nClean up this test is also in the list for any time. Cancel at any step cleans up and brings you back here. Starting another trap replaces the last one. Cleanup removes what the test gave or placed and the crafted trap if you still carry it; raised skills are kept." },
    { id = "vehicle", name = "Vehicle Claims", requires = { "KIPN", "KIPNVehicleServices" },
      description = "Try registration, titles, ownership and vehicle access rules.",
      guide = "1. Run every automatic check.\n2. Park a vehicle inside a dealership and try Full flow.\n3. Give the vehicle to the test owner to experience non-owner restrictions.\n4. Clean up when finished.\n\nTarget: your seated vehicle, otherwise the nearest within 12 tiles. Refresh after moving. Actions can give items or change ownership. The seat-ejection test asks you to get in within 30 seconds and counts that down on screen. Cleanup removes this suite's test items and claims." },
    { id = "government", name = "Safehouse & Land Claims", requires = { "KIPN", "KIPNGovernmentServices" },
      description = "Explore property registration, safehouses and excavation claims.",
      guide = "1. Run every automatic check.\n2. Check a building, then try a safehouse claim; try land claims at a suitable outdoor location.\n3. Verify the claim and explore its protection and records.\n4. Clean up my test items and claims when finished.\n\nActions use your current location and normal claim limits. Some give documents, create claims, or change test claim dates. Claims remain so you can explore them. Read each action's full name before starting." },
    { id = "postal", name = "Postal Service", requires = { "KIPN", "ThePostOffice" },
      description = "Set up a post office, rent a box and collect a delivery step by step, and check that bad requests are refused.",
      guide = "Guided post office test: each step tells you what to do; click OK when you have done it and the server checks it before the next step.\n1. You are moved into the designated test post office (see Test sites), and get a computer inside and a running generator outside. You get 10 money bundles and a Blank Key, and an overview of what a post office does.\n2. You place a Small, a Medium and a Large PO Box from the right-click menu. In the game that is admin-only; here the tester places them for you and you are not made an admin. Every box is then checked.\n3. You are shown how Postal Services works on the computer and why the box key matters.\n4. You switch the computer on, open Postal Services and rent a box. Your ownership, key and lock are then checked.\n5. A parcel of 2 sheets of paper is sent to you; you collect it in Postal Services. The server then tries to collect and to send it again, which must give nothing.\n\nCancel at any step cleans up; so does Clean up the post office test (stand in the post office: boxes are removed from within 10 tiles). Check invalid requests sends the services requests they must refuse; it changes nothing, and checks more if you own a box and carry its key." },
    { id = "dmm", name = "Dead Man's Map", requires = { "DeadMansMap" },
      description = "Follow your map markings through death and respawn.",
      guide = "This test kills your current character. It writes map markings, checks the dropped Annotated Map and personal-map wipe, respawns a new character and returns it to the corpse. Existing markings move to the dropped map.\n\nIf automatic respawn fails, create a character yourself; the test waits up to 10 minutes. " .. TRAVEL },
    { id = "skylights", name = "Skylights", requires = { "SkylightsProbe" },
      description = "Build a skylight yourself on a test building's roof.",
      guide = "1. Stand outdoors with open, flat ground nearby.\n2. Start Skylight Test: the server builds a 5x5 wooden room with a door in its west wall and stairs up to the roof on its south side, then deposits a skylight's materials in your inventory (4 planks, 4 screws, a screwdriver and a wooden window). The test ends there.\n3. Go up the stairs and build a Skylight anywhere on the roof from the build menu.\n4. Come down and go in through the door to see the light under it.\n5. Clean up your test room when finished.\n\nRunning the test again replaces your earlier test room. " .. TRAVEL },
    { id = "whisperers", name = "The Whisperers", requires = { "TheWhisperers" },
      description = "Butcher corpses, take heads and faces, sew masks and skin suits, and hide among the dead.",
      guide = "1. Stand outdoors on open, flat ground with a few clear tiles around you.\n2. Run the full test: it places four corpses beside you, gives you a knife, a katana, a machete, thread, nails and a long stick, and raises Butchering to 3 and Tailoring to 5 if they are lower.\n3. It butchers, beheads with each blade, cuts faces, sews a mask with a nail and one with a needle, smears guts on you, skins a suit, then wears, tears and repairs the gear, ages your guts, waits for misery and corpse sickness to build, and has a zombie come for you at a full meter and forget you at zero.\n4. Clean up your test items and corpses when finished.\n\nTest zombie mannerisms gives you a face mask and skin suit (take off your own first) and checks you move as a human in either alone and like a zombie in both: it walks and crouch-walks you along an 8-tile lane and sits you down, and asks you to crouch-run, run and sprint on open ground (2 minutes for each, or it is skipped). It takes the gear off and puts your clothes back on.\n\nThe test bloodies, sickens and saddens your character, spawns one zombie and hits you once to tear the suit. Skill raises are kept. Check my Whisperer state only reads your character." },
    { id = "satanic", name = "Satanic Temples", requires = { "SatanicTemples" },
      description = "Make every kind of sacrifice at the test temple, try to rob the skeletons, and die and recover.",
      guide = "1. Run the full test: it moves you to the designated test temple (see Test sites), lights its campfire and makes every kind of offering in turn - rare items, a weapon recipe, an animal carcass and head, another player's corpse, your own corpse, junk, a zombie corpse, greed past your recovery - and checks that no verdict shows before the ritual ends and that walking away cannot escape wrath. It then tries to take a skeleton's katana, lets the temple repair itself and runs one full ritual through the real Make a Sacrifice button (about a minute: stay put).\n2. Die and recover kills your character with the Dark Lord's wrath, respawns a new one and checks it recovers the lost skill at the altar.\n3. Clean up when finished: it clears the altar; the temple stays for the next player.\n\nThe tests hurt you often (you are healed between cases), give you Carpentry XP and change your recovery ledger. You are hidden from zombies while a test runs. " .. TRAVEL },
    { id = "careers", name = "Careers", requires = { "KIPN", "CareersFramework" },
      anyOf = { "CareersDrugDealer", "CareersMechanic", "CareersBlacksmith" },
      description = "Run a career: buy a licence, open a shop, design its flyer and work a job the server sends you.",
      guide = "1. Buy a business licence: you are moved into the designated Career Services zone (see Test sites), where the tester places a powered KIPN terminal beside you and gives you the money.\n2. Go inside a building you are allowed to use.\n3. Open your shop where you stand, then design your flyer and save it.\n4. Take a job the server sends you, then finish it and watch the payment arrive.\n\nThe careers are server authoritative: every step runs the career's own command, and the server posts walk-in jobs to every open shop on its own timer. The Drug Dealer is paid on delivery at a container, so finish its jobs in its own screen. Cleanup removes the terminal and the money the tester gave you; the careers have no command to close a business, so a test shop stays open." },
    { id = "events", name = "Dynamic Events", requires = { "KIPN", "DynamicEvents" },
      description = "Play every Dynamic Events game mode through as the only participant, and check the Studio, HUD, loadouts, threats and classic scenarios.",
      guide = "Run on a multiplayer test server; every player can run every test. Stand outdoors on open ground with about 30 tiles clear around you. The tests that need an event zone move you into the designated one (see Test sites).\n\n1. Setup: check the event services are running and every loadout and course item exists.\n2. Event Studio: check its checklist and templates, and open it to build every step.\n3. Running events: run one event from draft to finished (you are asked to sign up; the test answers the prompt), check validation, use the Director controls, win a prize.\n4. Game modes: each builds a small test event around you and plays it through with you as the only participant (you are moved to the flag, the hill, the exit, every Olympic station). Rounds start by themselves, so some take a minute.\n5. Players: start with each loadout (your own gear goes into escrow and comes back), find a clue and replay it, check the HUD fade.\n6. Threats: roll the difficulty, sit through a siege and an ambush, start and put out a test fire.\n7. Classic scenario locations: travel to each Pillow scenario's original spot and check it is open floor.\n8. Clean up my test events.\n\nEvents are real: announce shows a message to everyone online, sieges and ambushes spawn zombies (you are hidden from them during tests), and the fire test starts a real fire 10 tiles away and puts it out. Only one event can run at a time; the tests refuse to start over a real one. Every test event is named \"[LilBubby Test] ...\" and is removed afterwards; a test Olympics medal is taken back off the medal table. " .. TRAVEL },
    { id = "sites", name = "Test sites", anySuite = true,
      description = "The designated zones the tests use. Players never create a zone; tests that need one move you there.",
      guide = "Tests that need a zone (a government desk, a dealership, a post office, Career Services, an event zone, a Bonk Zone, a temple) use one designated zone each, and move you into it before they start. You can also go to one yourself from this list.\n\nThe server makes the zones itself. On the vanilla map they are on the north-east edge of West Point: the events zone is the riverside meadow around 12001,6661, with the temple, dealership, government desk and Career Services on the grass beside it, the post office in the small business at 12039,6742 and the Bonk Zone in the car park at 12059,6820.\n\nAdmins can move them: stand at the north-west corner of open, flat ground about 110 tiles wide and 115 deep, with a building within 60 tiles for the post office, and choose Move the test sites here. That is also how a server on another map gets its sites. " .. TRAVEL },
    { id = "compat", name = "Mod Compatibility",
      anyOf = { "SVSBoobyTraps", "SpyVsSpySignalTracker", "SkylightsProbe", "KIPN", "BonkZone", "SatanicTemples" },
      description = "Check that enabled mods share vanilla crafting, timed actions and the zone editor without breaking each other.",
      guide = "1. Run every automatic check.\n2. Run the Zone Editor check.\n\nOnly checks for enabled mods are offered. The checks call the live mods' own hooks with stand-in recipes, actions and characters. While a check runs, the next hook down the chain is briefly replaced by a counter, so nothing is crafted, queued, claimed or spent. It is restored immediately. The Zone Editor check opens the admin zone editor if it is closed and closes it again." },
}

-- Build 42 can list mod IDs with a leading backslash (\ModID).
function S.ModActive(id)
    local ok, active = pcall(function()
        local mods = getActivatedMods()
        return mods:contains(id) or mods:contains("\\" .. id)
    end)
    return ok and active == true
end

function S.Installed(mod)
    if mod.anySuite then
        for _, other in ipairs(S.Mods) do
            if not other.anySuite and S.Installed(other) then return true end
        end
        return false
    end
    for _, id in ipairs(mod.requires or {}) do
        if not S.ModActive(id) then return false end
    end
    if mod.anyOf then
        for _, id in ipairs(mod.anyOf) do
            if S.ModActive(id) then return true end
        end
        return false
    end
    return true
end

function S.InstalledMods()
    local mods = {}
    for _, mod in ipairs(S.Mods) do
        if S.Installed(mod) then mods[#mods + 1] = mod end
    end
    return mods
end

function S.ModById(id)
    for _, mod in ipairs(S.Mods) do if mod.id == id then return mod end end
end

-- A data-only menu keeps the existing suite callbacks and dynamic targets in
-- one place, without constructing hidden game menus or firing world events.
function S.NewMenu()
    local menu = { options = {}, submenus = {} }
    function menu:addOption(name, target, callback, ...)
        local option = { name = name, target = target, onSelect = callback,
            args = { ... }, argCount = select("#", ...) }
        self.options[#self.options + 1] = option
        return option
    end
    function menu:getOptionFromName(name)
        for _, option in ipairs(self.options) do if option.name == name then return option end end
    end
    function menu:addSubMenu(option, child)
        self.submenus[#self.submenus + 1] = child
        option.subOption = #self.submenus
    end
    function menu:getSubMenu(index) return self.submenus[index] end
    return menu
end

function S.Register(id, builder) S.builders[id] = builder end

function S.Session(player, id)
    local index = player:getPlayerNum()
    S.sessions[index] = S.sessions[index] or {}
    local sessions = S.sessions[index]
    sessions[id] = sessions[id] or { history = {}, tried = {} }
    return sessions[id]
end

-- Every feature is open to every player: the server makes whatever a test
-- needs, so nobody has to be an admin to try a mod.
function S.Build(player, id)
    local entries, notes = {}, {}
    local builder = S.builders[id]
    if not builder then return entries, "This suite is unavailable." end
    local mod = S.ModById(id)
    if mod and not S.Installed(mod) then return entries, "The mods this suite tests are not enabled." end
    local root = S.NewMenu()
    local ok, err = pcall(builder, player:getPlayerNum(), root, {}, false)
    if not ok then return entries, "Unable to load features: " .. tostring(err) end
    local function visit(menu, path, depth)
        for _, option in ipairs(menu.options) do
            if option.subOption then
                local nextPath = depth < 2 and "" or (path == "" and option.name or path .. " / " .. option.name)
                visit(menu:getSubMenu(option.subOption), nextPath, depth + 1)
            elseif option.onSelect then
                option.path = path
                option.key = option.path .. " / " .. option.name
                entries[#entries + 1] = option
            else
                notes[#notes + 1] = (path ~= "" and path .. ": " or "") .. option.name
            end
        end
    end
    visit(root, "", 0)
    if #entries == 0 and #notes == 0 then
        notes[1] = id == "bonk" and "Join the multiplayer test server to use this suite."
            or "Required mod is not enabled or its services are not ready."
    end
    return entries, table.concat(notes, "\n")
end

-- progress = true marks an interim message (a step, a notice, "moving you");
-- anything else is a feature's result. Listeners (the Run every test
-- sequencer) are told which it was.
function S.Report(player, id, text, progress)
    S.ReportIndex(player:getPlayerNum(), id, text, progress)
end

S.listeners = S.listeners or {}
function S.OnReport(fn) S.listeners[#S.listeners + 1] = fn end

-- Debug console: every report line and every tester command to or from the
-- server, per local player, across all mods. Kept for this client session.
S.CONSOLE_LIMIT = 500
S.consoles = S.consoles or {}
S.consoleWindows = S.consoleWindows or {}
S.ModuleSuites = {
    BonkPvpTest = "bonk", LilBubbySVSBTTest = "spy", LilBubbyVehSvcTest = "vehicle",
    LilBubbyGovSvcTest = "government", LilBubbyPostalTest = "postal",
    LilBubbyDMMTest = "dmm", LilBubbySkylightsTest = "skylights", LilBubbyWhisperersTest = "whisperers",
    LilBubbySatanicTemplesTest = "satanic", LilBubbyDynamicEventsTest = "events",
}
S.ModuleSuites.LilBubbyTeleport = "Travel"
local LEVELS = { PASS = true, FAIL = true, ERROR = true, BLOCKED = true, ABORTED = true,
    SKIP = true, READY = true, STARTED = true, INFO = true, SEND = true, RECV = true }
local consoleStart
local function nowMs()
    local ok, ms = pcall(function() return getTimestampMs() end)
    if ok and type(ms) == "number" then return ms end
    return os.time() * 1000
end

function S.Console(index)
    S.consoles[index] = S.consoles[index] or {}
    return S.consoles[index]
end

function S.Log(index, id, text, level)
    local lines = S.Console(index)
    local now = nowMs()
    consoleStart = consoleStart or now
    for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        if line:find("%S") then
            local status = level or line:match("^%s*(%u+):") or line:match("^%s*(%u+) |")
            if line:find("ATTEMPT FAILED", 1, true) then status = "FAIL" end
            lines[#lines + 1] = { time = now - consoleStart, id = id,
                level = LEVELS[status] and status or "INFO", text = line }
        end
    end
    while #lines > S.CONSOLE_LIMIT do table.remove(lines, 1) end
    local console = S.consoleWindows[index]
    if console then console.dirty = true end
end

-- Scalar arguments only, so a command line stays one readable line.
local function describe(args)
    if type(args) ~= "table" then return "" end
    local parts = {}
    for key, value in pairs(args) do
        local kind = type(value)
        if key ~= "text" and (kind == "string" or kind == "number" or kind == "boolean") then
            parts[#parts + 1] = tostring(key) .. "=" .. tostring(value)
        end
    end
    table.sort(parts)
    local text = table.concat(parts, " ")
    return #text > 160 and text:sub(1, 157) .. "..." or text
end

function S.LogTraffic(direction, index, module, command, args)
    local id = S.ModuleSuites[module]
    if not id then return end
    if LilBubbyStatus and module ~= "LilBubbyTeleport" then
        if direction == "SEND" then LilBubbyStatus.Sent(index, module, command) else LilBubbyStatus.Received(index) end
    end
    local label = direction == "SEND" and "to server: " or "from server: "
    S.Log(index, id, label .. tostring(command) .. "  " .. describe(args), direction)
end

-- Server replies carry no local player number; match playerID when present.
local function localIndex(args)
    local wanted = type(args) == "table" and (args.playerID or args.playerId)
    if wanted and getSpecificPlayer then
        for index = 0, 3 do
            local player = getSpecificPlayer(index)
            if player and player.getOnlineID and player:getOnlineID() == wanted then return index end
        end
    end
    return 0
end

if type(sendClientCommand) == "function" and not S.originalSendClientCommand then
    S.originalSendClientCommand = sendClientCommand
    sendClientCommand = function(first, ...)
        pcall(function(...)
            if type(first) == "string" then
                S.LogTraffic("SEND", 0, first, ...)
            else
                S.LogTraffic("SEND", first and first.getPlayerNum and first:getPlayerNum() or 0, ...)
            end
        end, ...)
        return S.originalSendClientCommand(first, ...)
    end
end
if Events.OnServerCommand then
    Events.OnServerCommand.Add(function(module, command, args)
        if S.ModuleSuites[module] then pcall(S.LogTraffic, "RECV", localIndex(args), module, command, args) end
    end)
end

function S.ReportIndex(index, id, text, progress)
    S.Log(index, id, text)
    if LilBubbyStatus then
        if progress == true then pcall(LilBubbyStatus.Step, index, id, text)
        else pcall(LilBubbyStatus.End, index, id, text) end
    end
    for _, fn in ipairs(S.listeners) do pcall(fn, index, id, tostring(text or ""), progress == true) end
    local state = S.Session({ getPlayerNum = function() return index end }, id)
    table.insert(state.history, 1, tostring(text or "No result"))
    if #state.history > 40 then table.remove(state.history) end
    local window = S.windows[index]
    if window and window.mod and window.mod.id == id then
        window.historyIndex = 1
        window:showResult()
    end
end

-- Rebuild immediately before dispatch: expired trap targets and newly blocked
-- actions cannot be run from stale rows. A changed target requires a new review.
function S.Run(player, id, selected, previousNotes)
    local entries, notes = S.Build(player, id)
    if notes ~= previousNotes then return false, "Your target or available features changed. Review the refreshed list and start again." end
    for _, option in ipairs(entries) do
        if option.key == selected.key then
            if option.notAvailable then
                return false, option.unavailableReason or "This action is currently unavailable. Check the instructions and target state."
            end
            local state = S.Session(player, id)
            state.tried[option.key] = true
            if LilBubbyStatus then LilBubbyStatus.Begin(player:getPlayerNum(), id, option.name) end
            S.Report(player, id, "STARTED: " .. option.name .. "\nFollow any in-game prompts. Results will appear here; some actions take time.", true)
            local function begin()
                local unpackArgs = unpack or table.unpack
                local ok, err = pcall(option.onSelect, option.target, unpackArgs(option.args, 1, option.argCount))
                if not ok then S.Report(player, id, "ERROR: " .. tostring(err)) end
                return ok, err
            end
            -- shared/LilBubbySites.lua loads before client files in game; test fixtures may omit it.
            if not option.site or not LilBubbySites then return begin() end
            -- The test needs a designated zone: the player is moved into it first.
            S.Report(player, id, "Moving you to the " .. LilBubbySites.Label(option.site) .. " test zone", true)
            LilBubbySites.Travel(player, option.site, function(arrived, why)
                if arrived then begin() else S.Report(player, id, "BLOCKED: " .. tostring(why)) end
            end)
            return true
        end
    end
    return false, "This target is no longer available. Refresh and select a nearby target."
end

-- Keep failure/blocking details visible even when they occur late in a report.
function S.Summarize(text)
    local intro, issues, counts = {}, {}, {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        if #intro < 3 and line ~= "" then intro[#intro + 1] = line end
        local status = line:match("^%s*(%u+):") or line:match("^%s*(%u+) |")
        if status then counts[status] = (counts[status] or 0) + 1 end
        if status == "FAIL" or status == "ERROR" or status == "BLOCKED" or status == "ABORTED"
            or line:find("ATTEMPT FAILED", 1, true) then
            issues[#issues + 1] = line
        end
    end
    local totals = {}
    for _, status in ipairs({ "PASS", "FAIL", "ERROR", "BLOCKED", "ABORTED", "SKIP", "READY" }) do
        if counts[status] then totals[#totals + 1] = status .. ": " .. counts[status] end
    end
    local result = table.concat(intro, "\n")
    if #totals > 0 then result = result .. "\n\nReported checks: " .. table.concat(totals, " | ") end
    if #issues > 0 then
        result = result .. "\n\nNeeds attention:\n" .. table.concat(issues, "\n", 1, math.min(5, #issues))
        if #issues > 5 then result = result .. "\nMore issues are listed in the full report." end
    end
    return result .. "\n\nOpen the full report for all checks and details."
end

function S.Open(player)
    require "LilBubbyShowcaseUI"
    local index = player:getPlayerNum()
    if LilBubbyMiniUI then LilBubbyMiniUI.Hide(index) end
    local window = S.windows[index]
    if not window then
        window = LilBubbyShowcaseUI:new(player)
        window:initialise()
        S.windows[index] = window
        window:addToUIManager()
    else
        window.player = player
        window:setVisible(true)
        window:refresh()
    end
    window:bringToTop()
end

-- Test sites: go to any designated zone; admins lay them out.
local siteList = {}
local function showSites(player, reply)
    local lines = {}
    for _, line in ipairs(reply.lines or {}) do lines[#lines + 1] = line end
    if reply.error then lines[#lines + 1] = (reply.status or "ERROR") .. ": " .. tostring(reply.error) end
    for _, site in ipairs(reply.sites or {}) do
        lines[#lines + 1] = (site.ready and "PASS: " or "BLOCKED: ") .. site.label .. " test zone "
            .. (site.ready and ("is set up near " .. site.x .. "," .. site.y) or "is not set up yet")
    end
    if reply.sites then siteList[player:getPlayerNum()] = reply.sites end
    S.Report(player, "sites", "Test sites\n" .. table.concat(lines, "\n"))
end
S.Register("sites", function(index, context)
    local player = getSpecificPlayer(index)
    if not player or not LilBubbySites then return end
    context:addOption("Show which test zones are set up", player, function(p)
        LilBubbySites.Ask(p, "list", {}, function(reply) showSites(p, reply) end)
    end)
    for _, site in ipairs(siteList[index] or {}) do
        if site.ready then
            context:addOption("Take me to the " .. site.label .. " test zone", player, function(p)
                S.Report(p, "sites", "PASS: You are in the " .. site.label .. " test zone")
            end).site = site.key
        end
    end
    -- Not a test: laying the zones out is the one thing only an admin does.
    if LilBubbySites.IsAdmin(player) then
        context:addOption("Move the test sites here (admins)", player, function(p)
            LilBubbySites.Ask(p, "setup", {}, function(reply)
                showSites(p, reply)
                LilBubbySites.Ask(p, "list", {}, function(listed) siteList[p:getPlayerNum()] = listed.sites or {} end)
            end)
        end)
    end
end)

Events.OnFillWorldObjectContextMenu.Add(function(index, context, objects, test)
    if test then return end
    local player = getSpecificPlayer(index)
    if player and not context:getOptionFromName("Open Mod Showcase") then
        context:addOption("Open Mod Showcase", player, S.Open)
    end
end)
