require "LilBubbyShowcase"
-- Optional integration: do not load another mod when it is disabled.
if getActivatedMods and getActivatedMods():contains("BonkZone") then
    require "BonkZone/BonkZone_Registry"
end
local MODULE = "BonkPvpTest"
local results = {}
local function request(p, command, args) sendClientCommand(p, MODULE, command, args or {}) end
local function show(p, text)
    print("[BonkPvpTest] " .. text)
    LilBubbyShowcase.Report(p, "bonk", text)
end
local function submenu(context, label)
    local existing = context:getOptionFromName(label)
    if existing and existing.subOption then return context:getSubMenu(existing.subOption) end
    local option = context:addOption(label)
    local menu = LilBubbyShowcase.NewMenu()
    context:addSubMenu(option, menu)
    return menu
end
LilBubbyShowcase.Register("bonk", function(index, context, objects, test)
    if test then return end
    local p = getSpecificPlayer(index)
    if not isClient() or not p then return end
    local tester = submenu(context, "lilBubby's Big ol Mod Tester")
    local menu = submenu(tester, "Bonk Zone tests")
    if not BonkZone or not BonkZone.Registry or not BonkZone.Registry.GetZones then
        menu:addOption("Enable BonkZone to use this suite").notAvailable = true
        return
    end
    menu:addOption("Take me to the designated test zone", p, request, "testzone")
    menu:addOption("Teleport me to any Bonk Zone", p, request, "teleport")
    local zones = submenu(menu, "Choose a Bonk Zone")
    for _, zone in ipairs(BonkZone.Registry.GetZones()) do
        zones:addOption(zone.name, p, request, "teleport", {zoneID = zone.id})
    end
    menu:addOption("Return to where I started", p, request, "return")
    for _, choice in ipairs({{"Pistol", "pistol"}, {"Shotgun", "shotgun"}, {"Rifle", "rifle"},
        {"My held ranged weapon", "held"}, {"Every loaded ranged weapon", "all"}}) do
        local shots = submenu(menu, choice[1])
        shots:addOption("Server shoots me once per weapon", p, request, "run", {weapon = choice[2], mode = "single"})
        shots:addOption("Server shoots me 30 times per weapon", p, request, "run", {weapon = choice[2], mode = "burst"})
    end
    menu:addOption("Cancel running test", p, request, "cancel")
    menu:addOption("Show last result", p, function(player)
        show(player, results[player:getOnlineID()] or "No result yet. Teleport to a zone, then choose a server-shot test. A failed block can injure you; testing stops at the first failure.")
    end)
end)
local function localPlayer(id)
    for i = 0, getNumActivePlayers() - 1 do
        local p = getSpecificPlayer(i)
        if p and p:getOnlineID() == id then return p end
    end
end
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= MODULE or type(args) ~= "table" then return end
    local p = localPlayer(args.playerID)
    if not p then return end
    if command == "shot" then
        -- Every server hit is heard where the player stands and named live in
        -- the status banner, so a run is never silent guesswork.
        local square = p:getCurrentSquare()
        if args.sound and square then
            local played = pcall(function() getSoundManager():PlayWorldSound(args.sound, square, 0, 20, 1.0, true) end)
            if not played then pcall(function() p:getEmitter():playSound(args.sound) end) end
        end
        if LilBubbyStatus then
            LilBubbyStatus.Note(p, string.format("Shot %d of %d: %s - %s", tonumber(args.shot) or 0,
                tonumber(args.total) or 0, tostring(args.name),
                args.passed and "blocked by the zone" or "NOT blocked"))
        end
        return
    end
    if command == "result" then
        results[args.playerID] = args.text
        print("[BonkPvpTest] " .. args.text)
        if args.status == "INFO" then
            LilBubbyShowcase.Report(p, "bonk", args.text, true)
            HaloTextHelper.addText(p, args.text)
        else
            if LilBubbyStatus then LilBubbyStatus.Note(p, nil) end
            show(p, args.text)
        end
    end
end)
