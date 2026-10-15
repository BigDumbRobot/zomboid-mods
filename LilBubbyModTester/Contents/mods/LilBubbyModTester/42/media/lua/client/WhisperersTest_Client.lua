require "LilBubbyShowcase"
require "LilBubbyCraft"
require "ISUI/ISContextMenu"
require "WhisperersTest_World"

-- The Whisperers full test: spawns corpses beside the player and works them
-- through the mod's real timed actions -- butchering, beheading with a katana,
-- a machete and a knife, cutting faces, sewing masks through the crafting
-- logic, smearing guts, skinning a suit -- then wears, damages, tears and
-- repairs the gear, checks guts rot, misery and corpse sickness, and has a
-- real zombie notice the player at a full meter and forget them at zero.
-- World changes are made by the server in multiplayer (WhisperersTest_Server.lua).
local MODULE = WhisperersTest.MODULE
local results = {}
local runner = nil
local replies = {}
local nextId = 0
local made = {} -- by player number: IDs of items the mod made during tests, for cleanup

local function show(playerNum, text)
    results[playerNum] = text
    print("[" .. MODULE .. "] " .. text)
    LilBubbyShowcase.ReportIndex(playerNum, "whisperers", text)
end

local function progress(player, text)
    LilBubbyShowcase.Report(player, "whisperers", text, true)
    print("[" .. MODULE .. "] " .. text)
end

local function waitMs(ms)
    local deadline = getTimestampMs() + ms
    while getTimestampMs() < deadline do coroutine.yield() end
end

local function waitFor(ms, fn, what)
    local deadline = getTimestampMs() + ms
    local previous = LilBubbyStatus and LilBubbyStatus.notes[0]
    if what and LilBubbyStatus then LilBubbyStatus.Note(0, what) end
    local value
    while true do
        value = fn()
        if value or getTimestampMs() > deadline then break end
        coroutine.yield()
    end
    if what and LilBubbyStatus then LilBubbyStatus.notes[0] = previous end
    return value or nil
end

local OP_TEXT = { setup = "giving you tools and skills", corpse = "placing a corpse", zombie = "placing a zombie",
    hit = "hitting you", ageGuts = "ageing your guts", wash = "washing you", cleanup = "removing test objects",
    give = "giving you an item", gaitKit = "giving you a face mask and a skin suit", stakeKit = "giving you a head and a stick", placeStakes = "placing a stake" }

-- Runs a world operation where the world is authoritative.
local function op(player, name, args)
    args = args or {}
    if not isClient() then
        local ok, result = pcall(WhisperersTest.World[name], player, args)
        if not ok then return { error = tostring(result) } end
        return result or {}
    end
    nextId = nextId + 1
    args.id = nextId
    sendClientCommand(player, MODULE, name, args)
    local id = nextId
    local reply = waitFor(20000, function() return replies[id] end, OP_TEXT[name] and ("Waiting for the server: " .. OP_TEXT[name]))
    replies[id] = nil
    return reply or { error = "no reply from the server in 20 s" }
end

-- Helpers ----------------------------------------------------------------------

local function G() return Whisperers.Gear end

local function list(player, fullType)
    local items, out = player:getInventory():getAllTypeRecurse(fullType), {}
    for i = 0, items:size() - 1 do out[#out + 1] = items:get(i) end
    return out
end

local function count(player, fullType) return player:getInventory():getCountTypeRecurse(fullType) end

-- The first item of fullType that was not in `before`; remembered for cleanup.
local function newest(player, fullType, before)
    local seen = {}
    for _, it in ipairs(before or {}) do seen[it] = true end
    for _, it in ipairs(list(player, fullType)) do
        if not seen[it] then
            local ids = made[player:getPlayerNum()]
            ids[#ids + 1] = it:getID()
            return it
        end
    end
end

local function tool(player, fullType)
    for _, it in ipairs(list(player, fullType)) do
        if it:hasModData() and it:getModData()[WhisperersTest.MARKER] then return it end
    end
end

local function corpseAt(x, y, z)
    local sq = getCell():getGridSquare(x, y, z)
    local bodies = sq and sq:getDeadBodys()
    for i = 0, (bodies and bodies:size() or 0) - 1 do
        local body = bodies:get(i)
        if body:getModData()[WhisperersTest.MARKER] then return body end
    end
end

local function avgBlood(player)
    local hv, n, sum = player:getHumanVisual(), BloodBodyPartType.MAX:index(), 0
    for i = 0, n - 1 do sum = sum + hv:getBlood(BloodBodyPartType.FromIndex(i)) end
    return sum / n
end

local function worn(player, item)
    local items = player:getWornItems()
    for i = 0, items:size() - 1 do
        if items:get(i):getItem() == item then return true end
    end
    return false
end

local function state() return Whisperers.Client.States[0] end

local function busy(player) return ISTimedActionQueue.isPlayerDoingAction(player) end

local function menuOption(context, name)
    for _, option in ipairs(context.options or {}) do
        if option.name == name then return option end
    end
end

local function subMenu(context, option)
    if option and option.subOption then return context:getSubMenu(option.subOption) end
end

-- Starts recipeName through the game's handcraft logic; waits for fullType.
local function craft(player, report, recipeName, fullType, label)
    local before = list(player, fullType)
    local done, detail
    LilBubbyCraft.Craft(player, recipeName, fullType, function(ok, why) done, detail = ok, why end)
    waitFor(120000, function() return done ~= nil end, label)
    report:check(label, done == true, detail)
    return done and newest(player, fullType, before) or nil
end

local function spawnCorpse(player, report, dx, dy, owner)
    local reply = op(player, "corpse", { dx = dx, dy = dy, owner = owner })
    if not report:check("Corpse placed at " .. dx .. "," .. dy, reply.error == nil, reply.error) then return nil end
    return waitFor(10000, function() return corpseAt(reply.x, reply.y, reply.z) end, "Waiting for the corpse to arrive")
end

local function behead(player, report, body, weapon, owner)
    local G = G()
    local expected = G.headBlows(player, weapon)
    local before = list(player, G.Types.Head)
    ISTimedActionQueue.add(ISEquipWeaponAction:new(player, weapon, 50, true, weapon:isTwoHandWeapon()))
    local action = Whisp_RemoveHeadAction:new(player, body, weapon)
    ISTimedActionQueue.add(action)
    local label = weapon:getDisplayName()
    local head = waitFor(240000, function() return newest(player, G.Types.Head, before) end,
        "Taking a head with the " .. label .. " (" .. expected .. " blows)")
    if not report:check(label .. " takes a head", head ~= nil) then return nil end
    report:check(label .. " blows", isClient() or action.blows == expected, action.blows .. " of " .. expected)
    report:check(label .. " head name", head:getName() == G.headName(owner), head:getName())
    report:check(label .. " marks the corpse headless", body:getModData().WhispHeadless == true)
    -- In MP the client's corpse sweep puts the stump on within a few seconds.
    local stump = waitFor(5000, function()
        local worn = body:getWornItems()
        for i = 0, (worn and worn:size() or 0) - 1 do
            local item = worn:getItemByIndex(i)
            if G.isStump(item) then return item end
        end
    end)
    report:check(label .. " leaves the corpse headless", stump ~= nil)
    report:check(label .. " stump is hidden from looting", stump ~= nil and stump:isHidden())
    report:check(label .. " stump can't be taken", stump ~= nil
        and not ISInventoryTransferAction:new(player, stump, body:getContainer(), player:getInventory(), 1):isValid())
    report:check(label .. " corpse can still be butchered and skinned", G.canButcher(body) and G.canSkin(body))
    return head
end

local function cutFace(player, report, head, knife, owner)
    local G = G()
    local before = list(player, G.Types.Face)
    ISTimedActionQueue.add(Whisp_CutFaceAction:new(player, head, knife))
    local face = waitFor(120000, function() return newest(player, G.Types.Face, before) end, "Cutting off a face")
    if not report:check("Face cut from " .. G.headName(owner), face ~= nil) then return nil end
    report:check("Face name", face:getName():find(G.faceName(owner), 1, true) == 1, face:getName())
    report:check("Face quality stored", type(face:getModData().WhispQuality) == "number", face:getModData().WhispQuality)
    waitFor(5000, function() return head:getModData().WhispFaceless end)
    report:check("Head marked faceless", head:getModData().WhispFaceless == true, head:getName())
    return face
end

-- The full flow -----------------------------------------------------------------

local function flow(player)
    local report = WhisperersTest.newReport("Whisperers full test")
    local W = Whisperers
    local G = W.Gear
    made[player:getPlayerNum()] = made[player:getPlayerNum()] or {}
    player:setSneaking(false)

    progress(player, "Giving you tools and raising Butchering and Tailoring")
    local setup = op(player, "setup")
    if not report:check("Tools and skills", setup.error == nil, setup.error) then return report end
    local knife = waitFor(10000, function() return tool(player, "Base.HuntingKnife") end, "Waiting for the tools to arrive")
    local katana, machete = tool(player, "Base.Katana"), tool(player, "Base.Machete")
    if not report:check("Tools arrived", knife and katana and machete) then return report end
    local butchering = player:getPerkLevel(Perks.Butchering)
    report:info("Skills", "Butchering " .. butchering .. ", Tailoring " .. player:getPerkLevel(Perks.Tailoring))

    -- Registration
    report:check("Sandbox options registered", type(SandboxVars.TheWhisperers) == "table")
    for _, fullType in pairs(G.Types) do
        local item = instanceItem(fullType)
        report:check("Item script " .. fullType, item ~= nil, item and item:getDisplayName())
    end
    report:check("Face mask is clothing", instanceof(instanceItem(G.Types.Mask), "Clothing"))
    report:check("Skin suit is clothing", instanceof(instanceItem(G.Types.Suit), "Clothing"))
    report:check("Recipe Whisp_SewFaceMask", LilBubbyCraft.FindRecipe("Whisp_SewFaceMask") ~= nil)
    report:check("Recipe Whisp_MakeHeadStake", LilBubbyCraft.FindRecipe("Whisp_MakeHeadStake") ~= nil)
    report:check("Recipe Whisp_RemoveBrain", LilBubbyCraft.FindRecipe("Whisp_RemoveBrain") ~= nil)
    report:check("Recipe Whisp_TreatSkinGear", LilBubbyCraft.FindRecipe("Whisp_TreatSkinGear") ~= nil)
    report:check("Recipe Whisp_DisassembleHeadStake", LilBubbyCraft.FindRecipe("Whisp_DisassembleHeadStake") ~= nil)
    report:check("Translations loaded", getText("IGUI_Whisp_Butcher") ~= "IGUI_Whisp_Butcher", getText("IGUI_Whisp_Butcher"))
    report:check("Katana takes a head in one blow", G.bladeClass(katana) == "rare")
    report:check("Machete is a long blade", G.bladeClass(machete) == "long")
    report:check("Hunting knife is a short blade", G.bladeClass(knife) == "short")
    report:check("A butchering blade is found", G.butcherKnife(player) ~= nil)
    report:check("Stat sync available", pcall(function() return SyncPlayerStatsPacket.getBitMaskForStat(CharacterStat.SICKNESS) end))
    report:check("Noise meter HUD created", W.HUD ~= nil and W.HUD[0] ~= nil)

    -- Corpse menu
    progress(player, "Placing corpses beside you")
    local A = spawnCorpse(player, report, 1, 0)
    local B = spawnCorpse(player, report, 0, 1, "Test Player")
    local C = spawnCorpse(player, report, -1, 0)
    if not (A and B and C) then return report end
    local context = ISContextMenu.get(player:getPlayerNum(), 200, 200)
    ISWorldObjectContextMenu.fetchVars.body = A
    triggerEvent("OnFillWorldObjectContextMenu", player:getPlayerNum(), context, { A }, false)
    local root = menuOption(context, getText("IGUI_Whisp_CorpseMenu"))
    local sub = subMenu(context, root)
    report:check("Corpse menu: Whisperer submenu", sub ~= nil)
    report:check("Corpse menu: Butcher for Guts", sub and menuOption(sub, getText("IGUI_Whisp_Butcher")) ~= nil)
    local headOption = sub and menuOption(sub, getText("IGUI_Whisp_RemoveHead"))
    local headSub = subMenu(sub, headOption)
    report:check("Corpse menu: Remove Head lists your blades", headSub and #headSub.options >= 3, headSub and #headSub.options)
    report:check("Corpse menu: Skin into a Suit available", sub and menuOption(sub, getText("IGUI_Whisp_Skin"))
        and not menuOption(sub, getText("IGUI_Whisp_Skin")).notAvailable)
    context:hideAndChildren()

    -- Guts
    progress(player, "Butchering a corpse for guts")
    local low, high = WhisperersTest.gutsRange(butchering, W.Get("GutsBaseYield"), W.Get("GutsYieldPerLevel"))
    local gutsBefore = list(player, G.Types.Guts)
    local started = getTimestampMs()
    ISTimedActionQueue.add(Whisp_ButcherCorpseAction:new(player, A, knife))
    waitFor(120000, function() return count(player, G.Types.Guts) > #gutsBefore and not busy(player) end, "Butchering for guts")
    local gutsGot = count(player, G.Types.Guts) - #gutsBefore
    for _ = 1, gutsGot do newest(player, G.Types.Guts, gutsBefore); gutsBefore = list(player, G.Types.Guts) end
    report:check("Guts yield", gutsGot >= low and gutsGot <= high, gutsGot .. ", expected " .. low .. "-" .. high)
    report:check("Butchering takes animal-butchering time", getTimestampMs() - started > 3000, (getTimestampMs() - started) .. " ms")
    report:check("Corpse marked gutted", A:getModData().WhispGutted == true)
    local gut = list(player, G.Types.Guts)[1]
    report:check("Fresh guts named", gut and gut:getName() == G.text("IGUI_Whisp_GutsName", 100, "Guts (100%)"), gut and gut:getName())
    report:check("Fresh guts weigh GutsWeight", gut and math.abs(gut:getActualWeight() - W.Get("GutsWeight")) < 0.01, gut and gut:getActualWeight())

    -- Heads
    progress(player, "Taking three heads: katana, machete, knife")
    local zombieHead = behead(player, report, A, katana, nil)
    local playerHead = behead(player, report, B, machete, "Test Player")
    local endurance = player:getStats():get(CharacterStat.ENDURANCE)
    local knifeHead = behead(player, report, C, knife, nil)
    report:check("Knife stabs are tiring", player:getStats():get(CharacterStat.ENDURANCE) < endurance,
        string.format("%.3f -> %.3f", endurance, player:getStats():get(CharacterStat.ENDURANCE)))
    if not (zombieHead and playerHead) then return report end

    -- Faces and masks: a nail first (no needle given yet), then a needle.
    progress(player, "Cutting faces and sewing masks")
    local zombieFace = cutFace(player, report, zombieHead, knife, nil)
    local nailMask = zombieFace and craft(player, report, "Whisp_SewFaceMask", G.Types.Mask, "Sew a face mask with a nail")
    if nailMask then
        local expect = WhisperersTest.maskCondition(zombieFace:getModData().WhispQuality, true, W.Get("NailDamage"))
        report:check("Nail mask name", nailMask:getName() == G.maskName(nil), nailMask:getName())
        report:check("Nail costs the mask " .. W.Get("NailDamage") .. "%", math.abs(nailMask:getCondition() - expect) <= 1,
            nailMask:getCondition() .. ", expected " .. expect)
    end
    op(player, "give", { type = "Base.Needle" })
    local needle = waitFor(10000, function() return tool(player, "Base.Needle") end, "Waiting for a needle")
    local playerFace = cutFace(player, report, playerHead, knife, "Test Player")
    local mask = playerFace and needle and craft(player, report, "Whisp_SewFaceMask", G.Types.Mask, "Sew a face mask with a needle")
    if mask then
        local expect = WhisperersTest.maskCondition(playerFace:getModData().WhispQuality, false, 0)
        report:check("Player mask keeps the player's name", mask:getName() == G.maskName("Test Player"), mask:getName())
        report:check("Needle leaves the face's condition", math.abs(mask:getCondition() - expect) <= 1,
            mask:getCondition() .. ", expected " .. expect)
    end

    -- Smearing
    progress(player, "Smearing guts on you")
    local blood = avgBlood(player)
    local gutsLeft = count(player, G.Types.Guts)
    ISTimedActionQueue.add(Whisp_SmearGutsAction:new(player, list(player, G.Types.Guts)[1]))
    waitFor(60000, function() return count(player, G.Types.Guts) < gutsLeft end, "Smearing guts")
    waitFor(5000, function() return avgBlood(player) > blood + 0.1 end)
    report:check("Guts spread blood over your body", avgBlood(player) > blood + 0.1,
        string.format("average blood %.3f -> %.3f", blood, avgBlood(player)))
    if not isClient() then
        report:check("Smeared guts tracked for corpse sickness", (player:getModData().WhispGutsPct or 0) > 0, player:getModData().WhispGutsPct)
    end
    waitMs(2500)
    report:check("Camouflage active", state() and state().active, state() and string.format("gore %.1f", state().gore))
    report:check("Noise meter shown", W.HUD[0] and W.HUD[0]:isVisible())

    if not mask then return report end

    -- Mask on
    progress(player, "Putting on the face mask")
    local cond = mask:getCondition()
    ISTimedActionQueue.add(ISWearClothing:new(player, mask))
    waitFor(30000, function() return worn(player, mask) and not busy(player) end, "Putting on the mask")
    waitMs(2000)
    report:check("Putting a mask on costs " .. W.Get("WearToggleDamage") .. "%", mask:getCondition() == cond - W.Get("WearToggleDamage"),
        cond .. " -> " .. mask:getCondition())
    report:check("Mask multiplies gore", state().multiplier == W.Get("MaskStealthMultiplier"), state().multiplier)

    -- Skin suit
    progress(player, "Skinning a corpse into a suit")
    local D = spawnCorpse(player, report, 0, -1)
    if D then
        local x, y, z = D:getSquare():getX(), D:getSquare():getY(), D:getSquare():getZ()
        local thread = G.totalUses(player, "Base.Thread")
        local before = list(player, G.Types.Suit)
        ISTimedActionQueue.add(Whisp_SkinCorpseAction:new(player, D, knife, needle, "Base.Thread"))
        local suit = waitFor(180000, function() return newest(player, G.Types.Suit, before) end, "Skinning a corpse")
        if report:check("Skin suit made", suit ~= nil) then
            report:check("Suit name", suit:getName() == G.suitName(nil), suit:getName())
            report:check("Suit full condition with a needle", suit:getCondition() == suit:getConditionMax(), suit:getCondition())
            report:check("Suit uses three masks' worth of thread", G.totalUses(player, "Base.Thread") == thread - 6,
                thread .. " -> " .. G.totalUses(player, "Base.Thread"))
            local gone = waitFor(5000, function() return corpseAt(x, y, z) == nil or nil end)
            report:check("Skinned corpse disappears", gone ~= nil)

            progress(player, "Putting on the skin suit")
            ISTimedActionQueue.add(ISWearClothing:new(player, suit))
            waitFor(30000, function() return worn(player, suit) and not busy(player) end, "Putting on the suit")
            waitMs(2000)
            local wrong, items = {}, player:getWornItems()
            for i = 0, items:size() - 1 do
                local item = items:get(i):getItem()
                if not G.allowedWithSuit(item) then wrong[#wrong + 1] = item:getFullType() end
            end
            report:check("Suit strips all but head gear, shoes, socks and bags", #wrong == 0, table.concat(wrong, ", "))
            local both = W.Get("MaskStealthMultiplier") * W.Get("SuitStealthMultiplier")
            report:check("Mask and suit multiply together", state().multiplier == both, state().multiplier)
            op(player, "give", { type = "Base.Tshirt_PoloTINT" })
            local shirt = waitFor(10000, function() return tool(player, "Base.Tshirt_PoloTINT") end)
            report:check("Nothing else goes on over the suit", shirt and not ISWearClothing:new(player, shirt):isValid())

            progress(player, "Hitting you hard enough to tear the suit")
            op(player, "hit", { damage = W.Get("SuitHitDestroyDamage") + 1 })
            waitFor(5000, function() return suit:getCondition() == 0 end)
            waitMs(1500)
            report:check("A big hit tears the suit", suit:getCondition() == 0, suit:getCondition())
            report:check("A torn suit gives no bonus", state().multiplier == W.Get("MaskStealthMultiplier"), state().multiplier)
        end
    end

    -- Mask off and repair
    progress(player, "Taking off and repairing the mask")
    cond = mask:getCondition()
    ISTimedActionQueue.add(ISUnequipAction:new(player, mask, 50))
    waitFor(30000, function() return not worn(player, mask) and not busy(player) end, "Taking off the mask")
    waitMs(1000)
    report:check("Taking a mask off costs " .. W.Get("WearToggleDamage") .. "%", mask:getCondition() == cond - W.Get("WearToggleDamage"),
        cond .. " -> " .. mask:getCondition())
    context = ISContextMenu.get(player:getPlayerNum(), 200, 200)
    triggerEvent("OnFillInventoryObjectContextMenu", player:getPlayerNum(), context, { mask })
    local repair = menuOption(context, getText("IGUI_Whisp_RepairMask"))
    report:check("Repair option offered at Tailoring " .. W.Get("MaskRepairTailoring"), repair ~= nil and not repair.notAvailable)
    context:hideAndChildren()
    ISTimedActionQueue.add(Whisp_RepairMaskAction:new(player, mask, needle, "Base.Thread"))
    waitFor(60000, function() return mask:getCondition() == mask:getConditionMax() end, "Repairing the mask")
    report:check("Needle repair restores the mask", mask:getCondition() == mask:getConditionMax(), mask:getCondition())

    -- Guts rot
    progress(player, "Ageing guts by " .. W.Get("GutsHalfLifeHours") .. " hours")
    local aged = op(player, "ageGuts", { hours = W.Get("GutsHalfLifeHours") })
    report:check("Guts lose half their weight in one half-life", aged.weight and math.abs(aged.weight - W.Get("GutsWeight") / 2) < 0.01,
        aged.error or aged.weight)
    report:check("Guts name shows 50%", aged.name == G.text("IGUI_Whisp_GutsName", 50, "Guts (50%)"), aged.error or aged.name)
    gut = list(player, G.Types.Guts)[1]
    if gut then
        context = ISContextMenu.get(player:getPlayerNum(), 200, 200)
        triggerEvent("OnFillInventoryObjectContextMenu", player:getPlayerNum(), context, { gut })
        report:check("Smear option on guts", menuOption(context, getText("IGUI_Whisp_Smear")) ~= nil)
        context:hideAndChildren()
    end

    -- Misery and corpse sickness
    progress(player, "Waiting 20 s for misery and corpse sickness to build")
    local stats = player:getStats()
    local sick, unhappy = stats:get(CharacterStat.SICKNESS), stats:get(CharacterStat.UNHAPPINESS)
    waitMs(20000)
    report:check("Corpse sickness rises", stats:get(CharacterStat.SICKNESS) > sick,
        string.format("%.4f -> %.4f", sick, stats:get(CharacterStat.SICKNESS)))
    report:check("Unhappiness rises", stats:get(CharacterStat.UNHAPPINESS) > unhappy,
        string.format("%.2f -> %.2f", unhappy, stats:get(CharacterStat.UNHAPPINESS)))
    report:check("Discomfort held high", stats:get(CharacterStat.DISCOMFORT) >= CharacterStat.DISCOMFORT:getMaximumValue() * 0.5,
        stats:get(CharacterStat.DISCOMFORT))

    -- Zombie awareness
    progress(player, "Placing a zombie 7 tiles away")
    player:setSneaking(true)
    local placed = op(player, "zombie", { dx = 7, dy = 0 })
    if report:check("Zombie placed", placed.error == nil, placed.error) then
        local zed = waitFor(10000, function()
            local zombies = getCell():getZombieList()
            for i = 0, zombies:size() - 1 do
                local z = zombies:get(i)
                if math.abs(z:getX() - placed.x) < 2 and math.abs(z:getY() - placed.y) < 2 then return z end
            end
        end, "Waiting for the zombie to arrive")
        if report:check("Zombie arrived", zed ~= nil) then
            local started = getTimestampMs()
            local noticed = waitFor(10000, function()
                state().meter, state().reservoir = 100, 0
                return zed:getTarget() == player
            end, "Meter at 100%: every zombie should come")
            report:check("Zombie comes at a full meter", noticed, (getTimestampMs() - started) .. " ms")
            started = getTimestampMs()
            waitMs(1500)
            local forgot = waitFor(10000, function()
                state().meter, state().reservoir = 0, 0
                return zed:getTarget() == nil
            end, "Meter at 0%: the zombie should forget you")
            report:check("Zombie forgets at a zero meter", forgot, (getTimestampMs() - started) .. " ms")
        end
        op(player, "removeZombies")
    end
    player:setSneaking(false)

    -- Head stake
    local stake = craft(player, report, "Whisp_MakeHeadStake", G.Types.Stake, "Make a head stake")
    report:check("Head stake named", stake and stake:getName():find("Head Stake", 1, true) ~= nil, stake and stake:getName())
    -- The byte data lives on the server's copy in multiplayer; the stakes test checks it there.
    if not isClient() then
        report:check("Head stake carries its 3D head (mannequin byte data)", stake ~= nil and stake:getByteData() ~= nil,
            stake and stake:getModData().WhispLook and stake:getModData().WhispLook.skin)
    end

    -- Washing
    progress(player, "Washing you")
    op(player, "wash")
    waitMs(8000)
    report:check("Washed body carries no blood", avgBlood(player) < 0.01, string.format("%.3f", avgBlood(player)))
    if not isClient() then
        report:check("Washing ends corpse sickness from smeared guts", player:getModData().WhispGutsPct == nil,
            player:getModData().WhispGutsPct)
    end
    report:info("Cleanup", "Clean up my test items and corpses removes everything this test made")
    return report
end

local STAKE_CRAFT_MS = 600000 -- how long each stake waits for you to craft it

-- Ten head stakes, one head at a time, crafted by the player: zombie heads
-- get random looks, player heads keep the tester's own face, faceless heads
-- are flayed. Test only: each is placed in a row two squares south as soon as
-- it is crafted (ten in the bag would pin the player); in play, the player
-- chooses where to place a stake.
local function stakesFlow(player)
    local report = WhisperersTest.newReport("Whisperers head stakes")
    local W = Whisperers
    local G, S = W.Gear, W.Stake
    if not report:check("3D head stakes installed", S ~= nil and S.dress ~= nil) then return report end
    local myLook = S.captureLook(player) or {}
    report:info("Your look", tostring(myLook.skin) .. ", hair " .. tostring(myLook.hair) .. ", beard " .. tostring(myLook.beard))
    local stakes, randomSkins, spots = {}, {}, {}
    for kindIndex, kind in ipairs(WhisperersTest.STAKE_KINDS) do
        local n = "Stake " .. kindIndex .. " (" .. kind.label .. ")"
        progress(player, "Crafting head stake " .. kindIndex .. " of " .. #WhisperersTest.STAKE_KINDS .. ": " .. kind.label)
        local kit = op(player, "stakeKit", { kind = kindIndex })
        if not report:check(n .. ": head and stick given", kit.error == nil, kit.error) then return report end
        -- You craft it: the test waits until the stake is in your inventory.
        local before = list(player, G.Types.Stake)
        progress(player, "Stake " .. kindIndex .. " of " .. #WhisperersTest.STAKE_KINDS .. ": craft a Head Stake now from "
            .. kind.label .. " (Make Head Stake). The test waits for you.")
        local stake = waitFor(STAKE_CRAFT_MS, function() return newest(player, G.Types.Stake, before) end,
            "Stake " .. kindIndex .. ": craft a Head Stake from " .. kind.label .. " (waiting for you)")
        report:check(n .. ": crafted by you", stake ~= nil, stake and stake:getName() or "no stake within "
            .. math.floor(STAKE_CRAFT_MS / 60000) .. " minutes")
        if stake then
            stakes[#stakes + 1] = stake
            local md = stake:getModData()
            local look = md[S.LookKey]
            local script = type(look) == "table" and S.scriptFor(look) or nil
            report:check(n .. ": look reached " .. (isClient() and "your client" or "the item"), type(look) == "table", script)
            report:check(n .. ": look has a real mannequin script", script ~= nil and getScriptManager():getMannequinScript(script) ~= nil, script)
            report:check(n .. ": faceless " .. (kind.faceless and "and flayed" or "no"), (md.WhispFaceless == true) == (kind.faceless == true))
            if kind.owner then
                report:check(n .. ": named for you", md.WhispOwner == kit.owner and stake:getName() == G.stakeName(kit.owner), stake:getName())
                report:check(n .. ": human face", type(look) == "table" and look.human == true and script == S.ScriptPrefix .. look.skin, look and look.skin)
                if kind.look then
                    report:check(n .. ": your own skin, hair and beard", look.skin == myLook.skin and look.hair == myLook.hair
                        and look.beard == myLook.beard, tostring(look.skin) .. " / " .. tostring(look.hair))
                end
            else
                report:check(n .. ": nobody's head", md.WhispOwner == nil, stake:getName())
                if type(look) == "table" then
                    randomSkins[look.skin] = true
                    report:info(n .. ": random look", (look.female and "female, " or "male, ") .. tostring(look.skin)
                        .. ", hair " .. tostring(look.hair) .. ", beard " .. tostring(look.beard))
                end
            end
        end
        waitFor(3000, function() return not busy(player) end)
        if stake then
            local placed = op(player, "placeStakes", { ids = { stake:getID() }, first = kindIndex - 1 })
            local spot = placed.placed and placed.placed[1]
            report:check(n .. ": placed", placed.error == nil and spot ~= nil, placed.error)
            if spot then
                report:check(n .. ": carried its 3D head" .. (isClient() and " on the server" or ""), spot.hadBytes == true)
                report:check(n .. ": placed as a head stake" .. (isClient() and " on the server" or ""), spot.view ~= nil,
                    spot.view and spot.view.script)
            end
            spots[kindIndex] = spot
        end
    end
    local distinct = 0
    for _ in pairs(randomSkins) do distinct = distinct + 1 end
    report:check("Crafted all " .. #WhisperersTest.STAKE_KINDS .. " stakes", #stakes == #WhisperersTest.STAKE_KINDS, #stakes)
    report:check("Strangers' heads look different from each other", distinct >= 2, distinct .. " different skins in 6 heads")

    progress(player, "Checking the stakes in the row two squares south of you")
    for i, kind in ipairs(WhisperersTest.STAKE_KINDS) do
        local spot = spots[i]
        if spot then
            local obj = waitFor(10000, function()
                local sq = getCell():getGridSquare(spot.x, spot.y, spot.z)
                local objects = sq and sq:getObjects()
                for j = 0, (objects and objects:size() or 0) - 1 do
                    if S.isStake(objects:get(j)) then return objects:get(j) end
                end
            end, "Waiting for stake " .. i .. " to appear")
            if report:check("Stake " .. i .. " stands at " .. spot.x .. "," .. spot.y, obj ~= nil) then
                local sq = obj:getSquare()
                report:check("Stake " .. i .. ": solid like furniture (blocks people and cars)",
                    sq ~= nil and (sq:isSolidTrans() or sq:isSolid()))
                local stick, flayed = false, false
                local worn = obj:getWornItems()
                for j = 0, worn:size() - 1 do
                    local item = worn:getItemByIndex(j)
                    if item and item:getFullType() == G.Types.StakeStick then stick = true end
                    if item and item:getFullType() == G.Types.StakeFaceless then flayed = true end
                end
                report:check("Stake " .. i .. ": on a stick, " .. (kind.faceless and "flayed" or "face intact"),
                    stick and flayed == (kind.faceless == true), obj:getMannequinScriptName())
                -- Multiplayer: what this client received must match what the server built.
                if spot.view then
                    local mine = WhisperersTest.describeStake(obj)
                    local diff = WhisperersTest.stakeDiff(spot.view, mine)
                    report:check("Stake " .. i .. ": " .. (isClient() and "you see what the server built" or "matches what was built"),
                        diff == "", diff ~= "" and diff or (mine.script .. ", hair " .. tostring(mine.hair)))
                end
            end
        end
    end
    report:info("Look at them", "The stakes stand two squares south of you. Zombie heads 1-4, faceless zombie heads 5-6, "
        .. "your head 7-8, your faceless head 9, an old player head 10. Clean up my test items and corpses removes them.")
    return report
end

local function cleanupFlow(player)
    local report = WhisperersTest.newReport("Whisperers cleanup")
    local reply = op(player, "cleanup", { ids = made[player:getPlayerNum()] or {} })
    if report:check("Cleanup", reply.error == nil, reply.error) then
        made[player:getPlayerNum()] = {}
        report:info("Removed", (reply.items or 0) .. " item(s), " .. (reply.corpses or 0) .. " corpse(s), "
            .. (reply.stakes or 0) .. " placed stake(s)")
    end
    return report
end

-- Reads the player's Whisperer state without changing anything.
local function inspect(player)
    local report = WhisperersTest.newReport("My Whisperer state")
    local W = Whisperers
    local G = W.Gear
    local st = state() or {}
    local gore, anyGore, raw, multiplier = W.measureGore(player)
    report:info("Gore", string.format("%.1f%% (raw %.1f%%, x%d)", gore, raw, multiplier))
    report:info("Camouflage", st.active and "active" or "inactive")
    report:info("Noise meter", string.format("%.1f%%", st.meter or 0))
    report:info("Miserable", anyGore and "yes: blood, guts or dead skin remain" or "no")
    local kg = 0
    for _, gut in ipairs(list(player, G.Types.Guts)) do kg = kg + gut:getActualWeight() end
    report:info("Guts carried", string.format("%d (%.2f kg)", count(player, G.Types.Guts), kg))
    local items = player:getWornItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i):getItem()
        if G.isGear(item) then
            report:info("Wearing", item:getName() .. " " .. item:getCondition() .. "/" .. item:getConditionMax())
        end
    end
    report:check("Measured gore matches the noise meter's", math.abs((st.gore or gore) - gore) < 5, string.format("%.1f vs %.1f", st.gore or 0, gore))
    show(player:getPlayerNum(), report:text())
end

-- Zombie mannerisms ---------------------------------------------------------------

-- The clip carrying the most weight on the character's base layer right now.
local function mainClip(player)
    local best, bestWeight = nil, -1
    for i = 0, 31 do
        local name = player:dbgGetAnimTrackName(0, i)
        if not name then break end
        local weight = player:dbgGetAnimTrackWeight(0, i) or 0
        if weight > bestWeight then best, bestWeight = name, weight end
    end
    return best
end

-- Watches the player for up to `ms`. While `holds()` has been true for at
-- least SETTLE_MS (past the blend in), tallies the main clip every tick and
-- measures distance and time moved. Stops once the state has been watched for
-- `needMs`, or when `done()` says so.
local SETTLE_MS = 500
local function observe(player, ms, holds, needMs, what, done)
    local tally, dist, secs, watched = {}, 0, 0, 0
    local since, lastT, lastX, lastY
    local deadline = getTimestampMs() + ms
    local previous = LilBubbyStatus and LilBubbyStatus.notes[0]
    if what and LilBubbyStatus then LilBubbyStatus.Note(0, what) end
    while getTimestampMs() < deadline and watched < needMs and not (done and done()) do
        local t, x, y = getTimestampMs(), player:getX(), player:getY()
        if holds() then
            since = since or t
            if t - since >= SETTLE_MS and lastT then
                local clip = mainClip(player)
                if clip then tally[clip] = (tally[clip] or 0) + 1 end
                watched = watched + (t - lastT)
                if player:isPlayerMoving() then
                    dist = dist + math.sqrt((x - lastX) ^ 2 + (y - lastY) ^ 2)
                    secs = secs + (t - lastT) / 1000
                end
            end
        else
            since = nil
        end
        lastT, lastX, lastY = t, x, y
        coroutine.yield()
    end
    if what and LilBubbyStatus then LilBubbyStatus.notes[0] = previous end
    return { tally = tally, speed = secs > 0.5 and dist / secs or nil, watched = watched }
end

local function walkable(sq)
    return sq ~= nil and sq:TreatAsSolidFloor() and not sq:isSolid() and not sq:isSolidTrans() and sq:isFree(false)
end

-- A straight, clear lane of `len` squares from the player, or nil.
local function findLane(player, len)
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local clear = true
        for i = 1, len do
            if not walkable(getCell():getGridSquare(px + d[1] * i, py + d[2] * i, pz)) then clear = false; break end
        end
        if clear then
            return getCell():getGridSquare(px, py, pz), getCell():getGridSquare(px + d[1] * len, py + d[2] * len, pz)
        end
    end
end

-- Walks to sq through the vanilla walk-to action, watching the gait on the
-- way. (It never runs: IsoPlayer:setPathfindRunning had no effect in 42.20.)
local function walkLeg(player, sq, holds, what)
    ISTimedActionQueue.add(ISWalkToTimedAction:new(player, sq))
    local seen = observe(player, 25000, holds, 60000, what, function()
        return not busy(player) and player:getCurrentSquare() == sq
    end)
    waitFor(5000, function() return not busy(player) end)
    return seen
end

-- Checks the clip a movement played, with the share of ticks it led.
local function checkClip(report, label, seen, expected)
    local clip, share = WhisperersTest.dominant(seen.tally)
    report:check(label, clip == expected and share >= 0.6,
        string.format("%s (%d%% of the time)%s", tostring(clip), math.floor(share * 100 + 0.5),
            seen.speed and string.format(", %.2f tiles/s", seen.speed) or ""))
    return clip
end

-- Asks the player to do something the test can't, and watches them do it.
-- A speed is only kept when they got somewhere (not running into a wall).
local function byHand(player, report, label, instruction, holds, expected)
    progress(player, instruction .. " Keep to open ground. The test waits 2 minutes.")
    local seen = observe(player, 120000, holds, 2500, instruction)
    if seen.watched < 1000 then
        report:info(label, "skipped: not done within 2 minutes")
        return nil
    end
    checkClip(report, label, seen, expected)
    if seen.speed and seen.speed < 0.5 then
        report:info(label .. " speed", string.format("%.2f tiles/s: blocked by something, not compared", seen.speed))
        seen.speed = nil
    end
    return seen
end

local function standingStill(player) return not player:isPlayerMoving() and not player:isSitOnGround() end

local function flagOn(player) return player:getVariableBoolean("WhispZombieGait") end

local function standingClip(player, ms)
    return WhisperersTest.dominant(observe(player, ms + 3000, function() return standingStill(player) end, ms).tally)
end

local function wear(player, item, what)
    ISTimedActionQueue.add(ISWearClothing:new(player, item))
    waitFor(30000, function() return worn(player, item) and not busy(player) end, what)
end

local function takeOff(player, item, what)
    ISTimedActionQueue.add(ISUnequipAction:new(player, item, 50))
    waitFor(30000, function() return not worn(player, item) and not busy(player) end, what)
end

-- Checks the flag and the standing clip after a change of gear.
local function checkGear(report, player, label, zombie)
    waitFor(2000, function() return flagOn(player) == zombie or nil end)
    report:check(label .. ": flag " .. (zombie and "on" or "off"), flagOn(player) == zombie, tostring(flagOn(player)))
    local clip = standingClip(player, 1500)
    if zombie then
        report:check(label .. ": stands like a zombie", clip == WhisperersTest.GAIT_CLIPS.idle, clip)
    else
        report:check(label .. ": stands like a human", clip ~= nil and not WhisperersTest.isZombieClip(clip), clip)
    end
end

local function gaitFlow(player)
    local report = WhisperersTest.newReport("Whisperers zombie mannerisms")
    local W = Whisperers
    local G = W.Gear
    local GAIT = WhisperersTest.GAIT_CLIPS
    player:setSneaking(false)

    -- Torn gear (the full test leaves a torn suit on) comes off by itself.
    for _, item in ipairs({ G.wornMask(player), G.wornSuit(player) }) do
        if item and not G.isWorking(item) then takeOff(player, item, "Taking off torn dead skin") end
    end
    if G.wornMask(player) or G.wornSuit(player) then
        report:add("BLOCKED", "Take off your face mask and skin suit first")
        return report
    end
    report:check("Sandbox option registered", SandboxVars.TheWhisperers and SandboxVars.TheWhisperers.ZombieMannerisms ~= nil,
        SandboxVars.TheWhisperers and tostring(SandboxVars.TheWhisperers.ZombieMannerisms))
    if not report:check("Zombie mannerisms enabled", W.Get("ZombieMannerisms") == true) then return report end
    report:check("Mod sets the gait flag", G.updateZombieGait ~= nil)
    local home, far = findLane(player, 8)
    if not report:check("A clear 8-tile lane beside you", home ~= nil, "stand on open, flat ground") then return report end
    local clothes, items = {}, player:getWornItems()
    for i = 0, items:size() - 1 do clothes[#clothes + 1] = items:get(i):getItem() end

    -- As a human
    progress(player, "Watching you stand and walk as a human")
    checkGear(report, player, "No dead skin", false)
    local humanWalk = walkLeg(player, far, function() return player:isPlayerMoving() end, "Walking as a human")
    local clip = WhisperersTest.dominant(humanWalk.tally)
    report:check("Human walk", clip ~= nil and not WhisperersTest.isZombieClip(clip),
        tostring(clip) .. (humanWalk.speed and string.format(", %.2f tiles/s", humanWalk.speed) or ""))
    walkLeg(player, home, function() return false end, "Walking back")

    -- Gear
    progress(player, "Giving you a face mask and a skin suit")
    local kit = op(player, "gaitKit")
    if not report:check("Mask and suit given", kit.error == nil, kit.error) then return report end
    local mask = waitFor(10000, function() return tool(player, G.Types.Mask) end, "Waiting for the mask")
    local suit = waitFor(10000, function() return tool(player, G.Types.Suit) end, "Waiting for the suit")
    if not report:check("Mask and suit arrived", mask and suit) then return report end

    progress(player, "Mask only")
    wear(player, mask, "Putting on the mask")
    checkGear(report, player, "Mask only", false)
    takeOff(player, mask, "Taking off the mask")
    progress(player, "Suit only")
    wear(player, suit, "Putting on the suit")
    checkGear(report, player, "Suit only", false)
    progress(player, "Mask and suit")
    wear(player, mask, "Putting on the mask")
    checkGear(report, player, "Mask and suit", true)

    -- Dead skin can tear at random (BreakChancePerHour), and a torn piece
    -- falls off. Stop rather than blame the gait for it.
    local function dressed(step)
        if worn(player, mask) and worn(player, suit) and G.isWorking(mask) and G.isWorking(suit) then return true end
        report:error(step, "the mask or suit tore or came off mid-test (dead skin tears at random); run the test again")
        return false
    end

    -- Moving in full disguise
    progress(player, "Walking in a full disguise")
    local walk = walkLeg(player, far, function() return player:isPlayerMoving() and not player:isRunning() end, "Shambling")
    if not dressed("Walking") then return report end
    checkClip(report, "Walks like a zombie", walk, GAIT.walk)
    if walk.speed and humanWalk.speed then
        local ratio = walk.speed / humanWalk.speed
        report:check("Shamble is slower than a human walk", ratio >= 0.4 and ratio <= 0.9,
            string.format("%.0f%% of a human walk", ratio * 100))
    end

    progress(player, "Crouch-walking in a full disguise")
    player:setSneaking(true)
    local sneak = walkLeg(player, home, function() return player:isPlayerMoving() and not player:isRunning() end, "Crouch-shambling")
    if not dressed("Crouch-walking") then return report end
    report:check("Still crouching (for the meter)", player:isSneaking())
    checkClip(report, "Crouch-walks with the shamble", sneak, GAIT.sneakWalk)

    local sneakRun = byHand(player, report, "Crouch-runs with a quicker shamble", "Stay crouched and run (hold the run key) for a few seconds.",
        function() return player:isSneaking() and player:isRunning() and player:isPlayerMoving() end, GAIT.sneakRun) or {}
    player:setSneaking(false)
    if not dressed("Crouch-running") then return report end

    local running = function() return player:isRunning() and not player:isSneaking() and player:isPlayerMoving() end
    local run = byHand(player, report, "Runs arms-out like an attacking zombie", "Stand up and run (hold the run key) for a few seconds.", running, GAIT.run)
    if run and run.speed and walk.speed then
        report:check("Run is faster than the shamble", run.speed > walk.speed, string.format("%.2f vs %.2f tiles/s", run.speed, walk.speed))
    end

    if not dressed("Running") then return report end
    local sprinting = function() return player:isSprinting() and player:isPlayerMoving() end
    local sprint = byHand(player, report, "Sprints like a sprinter zombie", "Sprint for a few seconds.", sprinting, GAIT.sprint)
    if sprint and sprint.speed and run and run.speed then
        report:check("Sprint is faster than the run", sprint.speed > run.speed, string.format("%.2f vs %.2f tiles/s", sprint.speed, run.speed))
    end

    if not dressed("Sprinting") then return report end
    progress(player, "Sitting on the ground in a full disguise")
    waitFor(10000, function() return not player:isPlayerMoving() and not busy(player) end)
    player:reportEvent("EventSitOnGround")
    local sat = waitFor(10000, function() return player:isSitOnGround() end, "Sitting down")
    if report:check("Sat down", sat ~= nil) then
        -- The sit-down itself (state sitonground) stays human; the loop after it is the zombie's.
        local sit = observe(player, 10000, function() return player:getAnimationStateName() == "sitonground-sitting" end, 2000, "Sitting")
        checkClip(report, "Sits slumped like a zombie", sit, GAIT.sit)
        player:setVariable("forceGetUp", true)
        waitFor(10000, function() return not player:isSitOnGround() and not busy(player) end, "Getting up")
        waitMs(1500)
    end

    -- Taking it off
    progress(player, "Taking the mask off, then the suit")
    takeOff(player, mask, "Taking off the mask")
    checkGear(report, player, "Suit, mask taken off", false)
    wear(player, mask, "Putting the mask back on")
    checkGear(report, player, "Mask back on", true)
    takeOff(player, suit, "Taking off the suit")
    checkGear(report, player, "Mask, suit taken off", false)
    local afterWalk = walkLeg(player, far, function() return player:isPlayerMoving() end, "Walking as a human again")
    clip = WhisperersTest.dominant(afterWalk.tally)
    report:check("Walks as a human again", clip ~= nil and not WhisperersTest.isZombieClip(clip), clip)
    takeOff(player, mask, "Taking off the mask")

    progress(player, "Putting your clothes back on")
    for _, item in ipairs(clothes) do
        if not worn(player, item) and item:getContainer() == player:getInventory() then wear(player, item) end
    end
    report:info("Speeds (tiles/s)", string.format("human walk %s | shamble %s, crouch %s, crouch-run %s, lunge %s, sprint %s",
        tostring(humanWalk.speed and string.format("%.2f", humanWalk.speed)),
        tostring(walk.speed and string.format("%.2f", walk.speed)), tostring(sneak.speed and string.format("%.2f", sneak.speed)),
        tostring(sneakRun.speed and string.format("%.2f", sneakRun.speed)), tostring(run and run.speed and string.format("%.2f", run.speed)),
        tostring(sprint and sprint.speed and string.format("%.2f", sprint.speed))))
    report:info("Gear left", "the test mask and suit stay in your inventory until Clean up")
    return report
end

-- Runner ------------------------------------------------------------------------

local function stepRunner()
    if not runner then return end
    local ok, result = coroutine.resume(runner.co)
    if not ok then
        runner.report = runner.report or WhisperersTest.newReport("Whisperers test")
        runner.report:error("Test error", tostring(result))
        result = runner.report
    end
    if not ok or coroutine.status(runner.co) == "dead" then
        local playerNum = runner.playerNum
        runner = nil
        show(playerNum, result and result:text() or "Whisperers test ended without a report.")
    end
end

local function start(player, fn)
    if runner then
        show(player:getPlayerNum(), "A Whisperers test is already running.")
        return
    end
    if player:getVehicle() then
        show(player:getPlayerNum(), "BLOCKED: Exit your vehicle first.")
        return
    end
    made[player:getPlayerNum()] = made[player:getPlayerNum()] or {}
    runner = { co = coroutine.create(fn), playerNum = player:getPlayerNum() }
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

LilBubbyShowcase.Register("whisperers", function(index, context, objects, test)
    if test or not WhisperersTest.available() then return end
    local player = getSpecificPlayer(index)
    if not player or player:isDead() then return end
    local tester = submenu(context, "lilBubby's Big ol Mod Tester")
    local suite = submenu(tester, "The Whisperers tests")
    -- Spawns corpses and a zombie, gives items and raises skills.
    suite:addOption("Run full Whisperers test (places corpses and a zombie beside you)", player, function(p) start(p, flow) end)
    -- Gives heads and sticks and places the stakes beside you (test only).
    suite:addOption("Craft 10 head stakes and set them up beside you", player, function(p) start(p, stakesFlow) end)
    -- Gives a mask and suit, walks and sits you, and waits for you to run and sprint.
    suite:addOption("Test zombie mannerisms (gives you a face mask and skin suit)", player, function(p) start(p, gaitFlow) end)
    suite:addOption("Check my Whisperer state", player, inspect)
    suite:addOption("Clean up my test items and corpses", player, function(p) start(p, cleanupFlow) end)
    suite:addOption("Show last result", player, function(p)
        show(p:getPlayerNum(), results[p:getPlayerNum()] or "The full test places corpses beside you and works them "
            .. "through butchering, beheading, face cutting, mask and suit making, then wears, tears and repairs the "
            .. "gear and has a zombie notice you at a full meter and forget you at zero.")
    end)
end)

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= MODULE or command ~= "reply" or type(args) ~= "table" or not args.id then return end
    replies[args.id] = args
end)

Events.OnTickEvenPaused.Add(stepRunner)
Events.OnFETick.Add(stepRunner)
