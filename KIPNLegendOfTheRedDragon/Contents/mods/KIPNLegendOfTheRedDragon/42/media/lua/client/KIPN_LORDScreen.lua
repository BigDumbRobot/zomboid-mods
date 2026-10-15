-- KIPN_LORDScreen.lua
--
-- Terminal child screen for KIPN: Legend of the Red Dragon.
--
-- A CHILD APPLICATION of KIPN_Terminal (KIPN/docs/README-SERVICE-API.md
-- sec 3). It renders the server's game snapshot and sends action
-- requests -- it owns no terminal chrome, navigation or transport.
--
-- Navigation between the town-square locations (Forest, Weapons,
-- Armour, Healer, Bank, Inn, Turgon's Training) is client-side:
-- self.view. Only real transactions round-trip to the server, which
-- returns place = "town" | "fight" | "dead" and the full state.

if isServer() then return end

require "KIPN_UI"
require "KIPN_LORDShared"

local okAPI = KIPN.API and KIPN.API.Require and KIPN.API.Require(KIPN.LORD.API_VERSION)
if not okAPI then
    print("[KIPN LORD] screen disabled: incompatible KIPN")
    return
end

local Commands = KIPN.Shared.Commands
local Events   = KIPN.Shared.ResponseEvents
local A        = KIPN.LORD.Actions
local Theme    = KIPN.UI.Theme

KIPN_LORDScreen = KIPN.UI.CreateScreen("KIPN_LORDScreen")

--------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------

function KIPN_LORDScreen:initialise()
    ISPanel.initialise(self)
    KIPN.UI.SetupScreen(self)
    -- scrollChildren = true: the action buttons below are laid out
    -- inline with the scrolling stat block/journal text (layoutButtons()
    -- positions them using the same unscrolled content-flow y those
    -- draw calls use), so they need to move with the rest of the
    -- content rather than stay glued to a fixed screen position.
    KIPN.UI.EnableScroll(self, { scrollChildren = true })
    self.snap = nil
    self.loading = true
    self.view = "town"
    self.buttons = {}
    self:setWantKeyEvents(true)
end

local function send(action)
    sendClientCommand("KIPN", Commands.LORD_ACTION, { action = action })
end

function KIPN_LORDScreen:go(view)
    self.view = view
end

function KIPN_LORDScreen:mkButton(key, label, fn)
    local b = KIPN.UI.CreateButton(self, 0, 0, 150, 24, label, fn)
    if b and b.setVisible then b:setVisible(false) end
    self.buttons[key] = b
end

function KIPN_LORDScreen:onShow()
    KIPN.UI.EnableScroll(self, { scrollChildren = true })
    if not self._built then
        self._built = true
        local B = function(k, l, f) self:mkButton(k, l, f) end
        -- town
        B("forest",   "THE FOREST",        function() send(A.FOREST) end)
        B("weapons",  "KING ARTHUR'S WEAPONS", function() self:go("weapons") end)
        B("armour",   "ABDUL'S ARMOUR",    function() self:go("armour") end)
        B("healer",   "HEALER'S HUT",      function() self:go("healer") end)
        B("bank",     "YE OLDE BANK",      function() self:go("bank") end)
        B("inn",      "THE RED DRAGON INN",function() self:go("inn") end)
        B("training", "TURGON'S TRAINING", function() self:go("training") end)
        B("dragon",   "* SLAY THE RED DRAGON *", function() send(A.DRAGON) end)
        B("restTown", "REST UNTIL DAWN",   function() send(A.REST) end)
        -- fight
        B("attack",   "ATTACK",            function() send(A.ATTACK) end)
        B("auto",     "AUTO-BATTLE",       function() send(A.AUTO_BATTLE) end)
        B("flee",     "FLEE",              function() send(A.FLEE) end)
        -- old man
        B("gemStr",   "GEMS -> STRENGTH",  function() send(A.GEM_STRENGTH) end)
        B("gemVit",   "GEMS -> VITALITY",  function() send(A.GEM_VITALITY) end)
        B("gemDef",   "GEMS -> DEFENCE",   function() send(A.GEM_DEFENCE) end)
        B("gemNo",    "DECLINE",           function() send(A.GEM_DECLINE) end)
        -- shops
        B("buyWpn",   "BUY NEXT WEAPON",   function() send(A.BUY_WEAPON) end)
        B("buyArm",   "BUY NEXT ARMOUR",   function() send(A.BUY_ARMOUR) end)
        -- healer
        B("healFull", "FULL HEAL",         function() send(A.HEAL_FULL) end)
        B("healSome", "HEAL 25%",          function() send(A.HEAL_SOME) end)
        -- bank
        B("dep",      "DEPOSIT ALL",       function() send(A.BANK_DEPOSIT) end)
        B("wd",       "WITHDRAW ALL",      function() send(A.BANK_WITHDRAW) end)
        B("gamble",   "GAMBLE (25%)",      function() send(A.BANK_GAMBLE) end)
        -- inn
        B("flirt",    "CHAT WITH VIOLET",  function() send(A.FLIRT) end)
        B("restInn",  "REST UNTIL DAWN",   function() send(A.REST) end)
        -- training
        B("challenge","CHALLENGE THE MASTER", function() send(A.CHALLENGE_MASTER) end)
        B("advance",  "ADVANCE A LEVEL",   function() send(A.ADVANCE_LEVEL) end)
        -- dead
        B("resurrect","REST UNTIL DAWN",   function() send(A.RESURRECT) end)
        -- shared
        B("back",     "<- TOWN SQUARE",    function() self:go("town") end)
        B("refresh",  "REFRESH",           function() self:requestState() end)
    end
    self:requestState()
end

function KIPN_LORDScreen:requestState()
    self.loading = true
    sendClientCommand("KIPN", Commands.LORD_GET_STATE, {})
end

function KIPN_LORDScreen:receiveResponse(event, data)
    if event == Events.LORD_STATE and type(data) == "table" then
        self.snap = data
        self.loading = false
        self.errorText = nil
    elseif event == Events.ERROR and type(data) == "table"
        and type(data.code) == "string" and data.code:sub(1, 4) == "LORD" then
        self.loading = false
        self.errorText = data.message or "The realm refused that."
    end
end

function KIPN_LORDScreen:onKeyPress(key)
    if key == Keyboard.KEY_ESCAPE and self.terminal then
        self.terminal:onKeyPress(key); return true
    end
    return false
end

function KIPN_LORDScreen:onMouseWheel(del)
    return KIPN.UI.OnScrollMouseWheel(self, del)
end

--------------------------------------------------------------------
-- EFFECTIVE VIEW
--------------------------------------------------------------------

function KIPN_LORDScreen:effectiveView()
    local snap = self.snap
    if not snap then return "town" end
    if snap.place == "fight" then return "fight" end
    if snap.place == "dead" then return "dead" end
    if snap.oldMan then return "oldman" end
    return self.view or "town"
end

local VIEW_BUTTONS = {
    town   = { "forest", "weapons", "armour", "healer", "bank", "inn", "training", "dragon", "restTown", "refresh" },
    fight  = { "attack", "auto", "flee", "refresh" },
    dead   = { "resurrect", "refresh" },
    oldman = { "gemStr", "gemVit", "gemDef", "gemNo" },
    weapons= { "buyWpn", "back" },
    armour = { "buyArm", "back" },
    healer = { "healFull", "healSome", "back" },
    bank   = { "dep", "wd", "gamble", "back" },
    inn    = { "flirt", "restInn", "back" },
    training= { "challenge", "advance", "back" },
}

function KIPN_LORDScreen:layoutButtons(y)
    for _, b in pairs(self.buttons) do
        if b and b.setVisible then b:setVisible(false) end
    end
    local view = self:effectiveView()
    local keys = VIEW_BUTTONS[view] or { "refresh" }
    local c = self.snap and self.snap.char or {}

    local x, rowY, right = 20, y, self.width - 20
    for _, key in ipairs(keys) do
        if key == "dragon" and not c.canFightDragon then
            -- hidden until eligible
        else
            local b = self.buttons[key]
            if b then
                local w = b.width or 150
                if x + w > right then x = 20; rowY = rowY + 30 end
                b:setX(x); b:setY(rowY)
                if b.setVisible then b:setVisible(true) end
                x = x + w + 8
            end
        end
    end
    return rowY + 34
end

--------------------------------------------------------------------
-- RENDER HELPERS
--------------------------------------------------------------------

local function line(self, text, x, y, col)
    col = col or Theme.text
    self:drawText(tostring(text), x, KIPN.UI.ScrollY(self, y), col.r, col.g, col.b, col.a, Theme.fontBody)
end

local function commas(n)
    n = math.floor(tonumber(n) or 0)
    local s = tostring(math.abs(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (n < 0 and "-" or "") .. out
end

function KIPN_LORDScreen:drawStatBlock(y)
    local c = self.snap.char
    line(self, string.format("%s   Level %d   Dragon kills: %d", c.name, c.level, c.dragonKills), 20, y, Theme.accent)
    y = y + 20
    line(self, string.format("HP  %s / %s        Gold  %s on hand   %s banked   Gems %d",
        commas(c.hp), commas(c.maxHp), commas(c.gold), commas(c.bank), c.gems), 20, y)
    y = y + 18
    local xp = (c.expForNext and c.expForNext >= 0)
        and string.format("XP  %s / %s to advance", commas(c.exp), commas(c.expForNext))
        or  string.format("XP  %s   (peak level)", commas(c.exp))
    line(self, xp, 20, y)
    y = y + 18
    line(self, string.format("Weapon: %s      Armour: %s", c.weapon, c.armour), 20, y)
    y = y + 18
    local bonus = ""
    if (c.bonusAtk or 0) + (c.bonusDef or 0) + (c.bonusHp or 0) > 0 then
        bonus = string.format("   (boons +%d atk / +%d def / +%s hp)", c.bonusAtk, c.bonusDef, commas(c.bonusHp))
    end
    line(self, string.format("Attack %s   Defence %s   Charm %d   Forest turns: %d%s",
        commas(c.attack), commas(c.defence), c.charm, c.forestFights, bonus), 20, y)
    return y + 26
end

function KIPN_LORDScreen:drawShop(y, list, ownedIdx, nextInfo, valueLabel, valueKey)
    line(self, string.format("You carry tier %d.  %s", ownedIdx,
        nextInfo and ("Next: " .. nextInfo.name .. " for " .. commas(nextInfo.cost) .. " gold (after trade-in of your old gear).")
                 or "You already own the finest available."), 20, y, Theme.warning)
    y = y + 24
    local cols = {
        { label = "TIER", width = 55 }, { label = "ITEM", width = 190 },
        { label = "COST", width = 130 }, { label = valueLabel, width = 90 },
    }
    local rows = {}
    for i, it in ipairs(list) do
        local tag = (i == ownedIdx) and " (worn)" or (i == ownedIdx + 1) and " (next)" or ""
        rows[#rows + 1] = { tostring(i) .. tag, it.name, commas(it.cost), tostring(it[valueKey]) }
    end
    KIPN.UI.DrawTable(self, 20, y, cols, rows, 20, { selectedIndex = ownedIdx })
    return y + 20 * (#rows + 1) + 12
end

--------------------------------------------------------------------
-- RENDER
--------------------------------------------------------------------

function KIPN_LORDScreen:prerender()
    ISPanel.prerender(self)
    KIPN.UI.DrawScanlines(self)
    local y = KIPN.UI.DrawBanner(self, "LEGEND OF THE RED DRAGON")

    if self.loading and not self.snap then
        KIPN.UI.DrawStatusMessage(self, "loading", "REACHING THE REALM...", "Waking your adventurer.")
        return
    end
    if not self.snap then
        KIPN.UI.DrawStatusMessage(self, "error", "NO RESPONSE FROM THE REALM", self.errorText or "Try REFRESH.")
        self:layoutButtons(y + 10)
        return
    end

    local snap = self.snap
    local c = snap.char
    local view = self:effectiveView()

    y = self:drawStatBlock(y)

    if view == "fight" and snap.fight then
        line(self, string.format(">> %s  --  %s / %s HP", snap.fight.name, commas(snap.fight.hp), commas(snap.fight.maxHp)),
            20, y, Theme.warning)
        y = y + 20
        if snap.fight.kind == "master" then line(self, "Turgon watches from the edge of the sand.", 20, y, Theme.dimText); y = y + 18
        elseif snap.fight.kind == "dragon" then line(self, "There is no fleeing the lair. Fight or fall.", 20, y, Theme.dimText); y = y + 18 end
        y = y + 6

    elseif view == "dead" then
        line(self, "You have fallen. Your bank, gems and gear are safe.", 20, y, Theme.error)
        y = y + 26

    elseif view == "oldman" then
        line(self, "The old man of the woods will take two gems and grant a permanent boon.", 20, y, Theme.warning)
        y = y + 20
        line(self, string.format("You have %d gems.", c.gems), 20, y, Theme.dimText)
        y = y + 26

    elseif view == "weapons" then
        y = self:drawShop(y, KIPN.LORD.WEAPONS, c.weaponIndex, snap.nextWeapon, "POWER", "power")

    elseif view == "armour" then
        y = self:drawShop(y, KIPN.LORD.ARMOUR, c.armourIndex, snap.nextArmour, "DEF", "def")

    elseif view == "healer" then
        line(self, string.format("The healer charges %s gold per point of health.", commas(snap.healPerHp)), 20, y, Theme.warning)
        y = y + 20
        line(self, string.format("Full heal would cost %s gold.", commas((c.maxHp - c.hp) * snap.healPerHp)), 20, y, Theme.dimText)
        y = y + 26

    elseif view == "bank" then
        line(self, string.format("On hand: %s      Vault: %s", commas(c.gold), commas(c.bank)), 20, y, Theme.warning)
        y = y + 20
        line(self, "Gamble stakes 25% of your on-hand gold at roughly even odds.", 20, y, Theme.dimText)
        y = y + 26

    elseif view == "inn" then
        line(self, "Violet tends the bar. A night here restores you to dawn.", 20, y, Theme.warning)
        y = y + 20
        line(self, string.format("Charm %d  --  raises your critical-hit chance and your luck in the forest.", c.charm), 20, y, Theme.dimText)
        y = y + 26

    elseif view == "training" then
        local m = snap.master
        if not m then
            line(self, "Turgon: \"There is nothing left for me to teach. Face the Dragon.\"", 20, y, Theme.warning); y = y + 26
        else
            line(self, string.format("This level's master: %s  (%s HP)", m.name, commas(m.hp)), 20, y, Theme.warning)
            y = y + 20
            if c.canAdvance then
                line(self, "You have bested the master. Choose ADVANCE A LEVEL.", 20, y, Theme.dimText)
            elseif c.canChallengeMaster then
                line(self, "You have the experience. Heal to full, then CHALLENGE THE MASTER.", 20, y, Theme.dimText)
            elseif c.masterDefeated then
                line(self, "Master defeated -- but you need more experience before advancing.", 20, y, Theme.dimText)
            else
                line(self, string.format("You need %s more experience before Turgon will test you.",
                    commas((c.expForNext >= 0 and c.expForNext or c.exp) - c.exp)), 20, y, Theme.dimText)
            end
            y = y + 26
        end

    else -- town
        if c.canFightDragon then
            line(self, ">> You stand ready. The Red Dragon's lair lies open to the north.", 20, y, Theme.warning); y = y + 22
        elseif c.level >= KIPN.LORD.MAX_LEVEL then
            line(self, "You are level 12. Reach weapon and armour tier 8, heal to full, then face the Dragon.", 20, y, Theme.dimText); y = y + 22
        elseif c.canChallengeMaster then
            line(self, ">> Turgon is ready to test you. Visit TURGON'S TRAINING.", 20, y, Theme.warning); y = y + 22
        end
        line(self, "Town Square. Where to?", 20, y, Theme.dimText)
        y = y + 24
    end

    y = self:layoutButtons(y + 2)

    -- journal
    y = KIPN.UI.DrawSectionHeader(self, y, "JOURNAL")
    for _, entry in ipairs(snap.log or {}) do
        line(self, entry, 24, y)
        y = y + 17
    end
    y = y + 10

    -- hall of honours (town only, keeps the fight screen tight)
    if view == "town" and type(snap.hallOfHonours) == "table" and #snap.hallOfHonours > 0 then
        y = KIPN.UI.DrawSectionHeader(self, y, "HALL OF HONOURS")
        for i, h in ipairs(snap.hallOfHonours) do
            line(self, string.format("%2d.  %s  --  %d dragon kill(s), last wielding %s",
                i, h.name or "?", h.dragonKills or 0, h.weapon or "a stick"), 24, y)
            y = y + 17
        end
        y = y + 10
    end

    KIPN.UI.SetContentHeight(self, y)
end
