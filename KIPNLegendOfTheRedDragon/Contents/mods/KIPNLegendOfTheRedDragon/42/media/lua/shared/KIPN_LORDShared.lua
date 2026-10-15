-- KIPN_LORDShared.lua
--
-- Shared contract for KIPN: Legend of the Red Dragon.
--
-- Loads on BOTH realms before any LORD server/client file. It extends
-- KIPN's shared enums with this add-on's wire names (via the
-- KIPN.Shared.RegisterX helpers -- no edit to KIPN_Shared.lua) and
-- publishes the static game tables (weapons, armour, masters, the
-- experience ladder) so the client can show prices and requirements
-- without a round trip. The server is still the only authority on
-- what actually happens.

require "KIPN_Shared"

if not KIPN or not KIPN.Shared then
    error("[KIPN_LORD] KIPN.Shared unavailable -- is KIP Network Terminal installed and loaded first?")
end

KIPN.LORD = KIPN.LORD or {}
KIPN.LORD.API_VERSION = 1
KIPN.LORD.MAX_LEVEL   = 12

--------------------------------------------------------------------
-- WIRE NAMES
--------------------------------------------------------------------

KIPN.Shared.RegisterCommand("LORD_GET_STATE", "lordGetState")
KIPN.Shared.RegisterCommand("LORD_ACTION",    "lordAction")
KIPN.Shared.RegisterCommand("LORD_LEADERBOARD", "lordLeaderboard")   -- read-only, no character side effects
KIPN.Shared.RegisterResponseEvent("LORD_STATE", "lordState")
KIPN.Shared.RegisterResponseEvent("LORD_LEADERBOARD_DATA", "lordLeaderboardData")

--------------------------------------------------------------------
-- ACTION IDS  (args.action for the LORD_ACTION command)
--------------------------------------------------------------------

KIPN.LORD.Actions = {
    -- forest
    FOREST        = "forest",
    ATTACK        = "attack",        -- one combat round
    AUTO_BATTLE   = "autoBattle",    -- resolve the fight to its conclusion
    FLEE          = "flee",          -- normal monsters only
    -- old man of the woods (only while state.oldMan is set)
    GEM_STRENGTH  = "gemStrength",
    GEM_VITALITY  = "gemVitality",
    GEM_DEFENCE   = "gemDefence",
    GEM_DECLINE   = "gemDecline",
    -- shops
    BUY_WEAPON    = "buyWeapon",
    BUY_ARMOUR    = "buyArmour",
    -- healer
    HEAL_FULL     = "healFull",
    HEAL_SOME     = "healSome",
    -- bank
    BANK_DEPOSIT  = "bankDeposit",
    BANK_WITHDRAW = "bankWithdraw",
    BANK_GAMBLE   = "bankGamble",
    -- inn
    FLIRT         = "flirt",
    REST          = "rest",          -- rest until dawn (new day)
    -- Turgon's warrior training
    CHALLENGE_MASTER = "challengeMaster",
    ADVANCE_LEVEL    = "advanceLevel",
    -- the dragon
    DRAGON        = "dragon",
    -- after death
    RESURRECT     = "resurrect",
}

--------------------------------------------------------------------
-- EXPERIENCE LADDER
--------------------------------------------------------------------
-- Experience the player must accumulate WHILE AT level N to be
-- eligible to advance to N+1 (running total, never spent). Flattened
-- from the 1989 curve so a casual player can reach the Dragon in a
-- handful of in-game days rather than real weeks.

KIPN.LORD.EXP_NEEDED = {
    [1] = 100,     [2] = 400,      [3] = 1200,     [4] = 3000,
    [5] = 7000,    [6] = 16000,    [7] = 35000,    [8] = 70000,
    [9] = 130000,  [10] = 230000,  [11] = 400000,  [12] = -1,   -- -1 = max level
}

--------------------------------------------------------------------
-- HIT POINTS BY LEVEL
--------------------------------------------------------------------
-- Set (not added) on each advance, so gear and level -- not lucky
-- rolls -- decide whether a master or the Dragon is survivable.

KIPN.LORD.MAX_HP_BY_LEVEL = {
    [1] = 30,    [2] = 55,     [3] = 100,    [4] = 180,
    [5] = 330,   [6] = 620,    [7] = 1200,   [8] = 2300,
    [9] = 4400,  [10] = 8500,  [11] = 16000, [12] = 30000,
}

--------------------------------------------------------------------
-- KING ARTHUR'S WEAPONS   { name, cost, power }
--------------------------------------------------------------------

KIPN.LORD.WEAPONS = {
    { name = "Stick",           cost = 200,       power = 6 },
    { name = "Dagger",          cost = 1000,      power = 12 },
    { name = "Short Sword",     cost = 3000,      power = 30 },
    { name = "Long Sword",      cost = 10000,     power = 60 },
    { name = "Huge Axe",        cost = 30000,     power = 90 },
    { name = "Bone Cruncher",   cost = 100000,    power = 145 },
    { name = "Twin Swords",     cost = 150000,    power = 190 },
    { name = "Power Axe",       cost = 200000,    power = 275 },
    { name = "Able's Sword",    cost = 400000,    power = 350 },
    { name = "Hattori's Blade", cost = 1000000,   power = 500 },
    { name = "Blessed Sword",   cost = 4000000,   power = 800 },
    { name = "Death Sword",     cost = 10000000,  power = 1500 },
}

--------------------------------------------------------------------
-- ABDUL'S ARMOUR   { name, cost, defence }
--------------------------------------------------------------------

KIPN.LORD.ARMOUR = {
    { name = "Cloth Coat",        cost = 200,       def = 6 },
    { name = "Heavy Coat",        cost = 1000,      def = 12 },
    { name = "Leather Vest",      cost = 3000,      def = 25 },
    { name = "Bronze Armour",     cost = 10000,     def = 40 },
    { name = "Iron Armour",       cost = 30000,     def = 70 },
    { name = "Graphite Armour",   cost = 100000,    def = 110 },
    { name = "Erdrick's Armour",  cost = 150000,    def = 150 },
    { name = "Armour of Death",   cost = 200000,    def = 225 },
    { name = "Full Body Armour",  cost = 400000,    def = 350 },
    { name = "Blessed Armour",    cost = 1000000,   def = 500 },
    { name = "Ebony Armour",      cost = 4000000,   def = 800 },
    { name = "Golden Armour",     cost = 10000000,  def = 1200 },
}

--------------------------------------------------------------------
-- TURGON'S MASTERS  (one per level 1..11; level 12 fights the Dragon)
--------------------------------------------------------------------

KIPN.LORD.MASTER_NAMES = {
    "Halder", "Barius", "Aragorn", "Olodrin", "Sensei Kensai",
    "Aldaron", "Turgon", "Haldir", "Gandolf", "Mistress Ravenna",
    "King Alaric",
}

print("[KIPN] Legend of the Red Dragon shared contract loaded")
