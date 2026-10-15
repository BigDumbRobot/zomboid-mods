require "LilBubbyShowcase"
require "CareersTest_Checks"
require "CareersFlyerUI"

-- Careers suite, client side: the showcase menu, the flyer designer and the
-- results. Every step is carried out by the careers' own server commands;
-- this file only asks for them and shows what came back.
local T = CareersTest
local S = LilBubbyShowcase
local results = {}

local function show(player, text)
    results[player:getPlayerNum()] = text
    print("[" .. T.MODULE .. "] " .. tostring(text))
    S.Report(player, "careers", text)
end

local function progress(player, text)
    S.Report(player, "careers", text, true)
end

local function request(player, id, args)
    args = args or {}
    args.id = id
    if isClient() then
        sendClientCommand(player, T.MODULE, "run", args)
    else
        show(player, T.RunServer(player, id, args):text())
    end
end

-- The flyer step collects the details here, then the career saves them.
local function designFlyer(player, entry)
    local career = T.CareerById(entry.careerId)
    if not career then return end
    progress(player, "Careers: fill in your " .. career.name .. " flyer, then press Save to my " .. career.shopWord .. ".")
    CareersFlyerUI.Show(player, career, function(values)
        request(player, entry.id, { fields = values })
    end)
end

local function installed()
    local mods = {}
    for _, career in ipairs(T.Careers) do mods[career.mod] = S.ModActive(career.mod) end
    return mods
end

local function submenu(context, label)
    local existing = context:getOptionFromName(label)
    if existing and existing.subOption then return context:getSubMenu(existing.subOption) end
    local option = context:addOption(label)
    local menu = S.NewMenu()
    context:addSubMenu(option, menu)
    return menu
end

S.Register("careers", function(index, context, objects, test)
    if test then return end
    local player = getSpecificPlayer(index)
    if not player then return end
    local tester = submenu(context, "lilBubby's Big ol Mod Tester")
    local suite = submenu(tester, "Careers tests")
    if not S.ModActive("KIPN") or not S.ModActive(T.FRAMEWORK) then
        suite:addOption("Enable KIPN and the Careers Framework to use this suite").notAvailable = true
        return
    end
    local groups = {}
    for _, entry in ipairs(T.Catalog(installed())) do
        local target = suite
        if entry.group then
            groups[entry.group] = groups[entry.group] or submenu(suite, entry.group)
            target = groups[entry.group]
        end
        if entry.step == "flyer" then
            target:addOption(entry.label, player, designFlyer, entry)
        else
            local option = target:addOption(entry.label, player, request, entry.id)
            -- The terminal stands in the designated Career Services zone: the showcase moves you there first.
            if entry.step == "licence" or entry.step == "fw_zones" then option.site = "career_services" end
        end
    end
    suite:addOption("Show last result", player, function(p)
        show(p, results[p:getPlayerNum()] or "Nothing has run yet. Start with Buy a business licence at a terminal.")
    end)
end)

local function localPlayer(id)
    for index = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(index)
        if player and player:getOnlineID() == id then return player end
    end
    return getSpecificPlayer(0)
end

function T.ClientReceive(args)
    local player = localPlayer(args.playerID)
    if player then show(player, tostring(args.text)) end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= T.MODULE or command ~= "result" or type(args) ~= "table" then return end
    T.ClientReceive(args)
end)

return CareersTest
