-- KIPN_StatsCatalog.lua
--
-- Single data-driven catalog describing every player/server stat
-- KIPN natively tracks.
--
-- Both the client (KIPN_ServerStats.lua rendering, KIPN_StatsTracker.lua
-- hook installation) and the server (KIPN_LeaderboardService.lua,
-- KIPN_StatsService.lua) loop over this ONE table rather than each
-- hand-listing the same stat set separately. Add a stat once here and
-- it gains a sandbox visibility toggle, a Player tab row, and (if
-- flagged) a Server tab leaderboard/totals row automatically.
--
-- FIELDS per entry:
--   id             Stable identifier. Matches the persisted
--                   playerStats row field UNLESS dataKey overrides it
--                   (kept distinct for the stats KIPN already tracked
--                   before this catalog existed, to avoid a data
--                   migration).
--   dataKey        Optional override for the playerStats row field
--                   name. Defaults to id.
--   label          Display label.
--   tier           "A" (read live off the IsoPlayer server-side, no
--                   client tracking needed) or "B" (needs
--                   KIPN_StatsTracker.lua client-side accumulation).
--   mergeStrategy  How a newly-observed value combines with the
--                   stored value:
--                     "cumulative"  stored = stored + delta
--                     "peak"        stored = max(stored, candidate)
--                     "live"        stored = candidate (overwrite)
--                     "peakPerKey"  like peak, but keyed by a second
--                                   dimension (e.g. weapon name) --
--                                   only favoriteWeapon uses this.
--   format         "count" | "hours" | "meters" | "kg" | "kcal" | "text"
--   sandboxOption  Suffix appended to "KIPN.Stat" + suffix + "Visible"
--                   (see sandbox-options.txt).
--   leaderboard    If true, the Server tab renders a top-5 section
--                   for this stat (kept to a curated headline subset
--                   so the page doesn't grow to 25 sections).
--
-- Entries with mergeStrategy "cumulative" or "peak" also appear in
-- the Server tab's compact totals table (sum for cumulative, a
-- server-wide record/max for peak). Entries with "live" or
-- "peakPerKey" are Player-tab-only -- they're per-life snapshots or
-- non-numeric, and don't aggregate meaningfully across players.

if not KIPN then

    error(
        "[KIPN_StatsCatalog] "
        .. "KIPN core is not initialized."
    )
end

if not KIPN.Shared then

    error(
        "[KIPN_StatsCatalog] "
        .. "KIPN_Shared is not initialized."
    )
end

KIPN.Shared.StatsCatalog = {

    ----------------------------------------------------------------
    -- COMBAT / SURVIVAL (existing, tracked before this catalog)
    ----------------------------------------------------------------

    {
        id = "zombieKills",
        label = "Zombie Kills",
        tier = "A",
        mergeStrategy = "peak",
        format = "count",
        sandboxOption = "ZombieKills",
        leaderboard = true,
    },

    {
        id = "pvpKills",
        label = "PVP Kills",
        tier = "B",
        mergeStrategy = "cumulative",
        format = "count",
        sandboxOption = "PvpKills",
        leaderboard = true,
    },

    {
        id = "hoursSurvived",
        dataKey = "longestAliveHours",
        label = "Longest Alive",
        tier = "A",
        mergeStrategy = "peak",
        format = "hours",
        sandboxOption = "HoursSurvived",
        leaderboard = true,
    },

    {
        id = "deaths",
        label = "Deaths",
        tier = "B",
        mergeStrategy = "cumulative",
        format = "count",
        sandboxOption = "Deaths",
        leaderboard = false,
    },

    ----------------------------------------------------------------
    -- TIER A -- LIVE READS, NO CLIENT TRACKING NEEDED
    ----------------------------------------------------------------

    {
        id = "recipesKnown",
        label = "Recipes Known",
        tier = "A",
        mergeStrategy = "peak",
        format = "count",
        sandboxOption = "RecipesKnown",
        leaderboard = false,
    },

    {
        id = "booksRead",
        label = "Books Read",
        tier = "A",
        mergeStrategy = "peak",
        format = "count",
        sandboxOption = "BooksRead",
        leaderboard = false,
    },

    {
        id = "magazinesRead",
        label = "Magazines Read",
        tier = "A",
        mergeStrategy = "peak",
        format = "count",
        sandboxOption = "MagazinesRead",
        leaderboard = false,
    },

    {
        id = "highestSkill",
        label = "Highest Skill",
        tier = "A",
        mergeStrategy = "live",
        format = "text",
        sandboxOption = "HighestSkill",
        leaderboard = false,
    },

    {
        id = "totalSkillLevels",
        label = "Total Skill Levels",
        tier = "A",
        mergeStrategy = "peak",
        format = "count",
        sandboxOption = "TotalSkillLevels",
        leaderboard = false,
    },

    {
        id = "bodyWeight",
        label = "Body Weight",
        tier = "A",
        mergeStrategy = "live",
        format = "kg",
        sandboxOption = "BodyWeight",
        leaderboard = false,
    },

    {
        id = "carryWeight",
        label = "Carry Weight",
        tier = "A",
        mergeStrategy = "live",
        format = "kg",
        sandboxOption = "CarryWeight",
        leaderboard = false,
    },

    ----------------------------------------------------------------
    -- TIER B -- NEEDS KIPN_StatsTracker.lua (CLIENT-SIDE HOOKS)
    ----------------------------------------------------------------

    {
        id = "distanceTravelled",
        label = "Distance Travelled",
        tier = "B",
        mergeStrategy = "cumulative",
        format = "meters",
        sandboxOption = "DistanceTravelled",
        leaderboard = true,
    },

    {
        id = "vehicleDistance",
        label = "Vehicle Distance",
        tier = "B",
        mergeStrategy = "cumulative",
        format = "meters",
        sandboxOption = "VehicleDistance",
        leaderboard = false,
    },

    {
        id = "caloriesConsumed",
        label = "Calories Consumed",
        tier = "B",
        mergeStrategy = "cumulative",
        format = "kcal",
        sandboxOption = "CaloriesConsumed",
        leaderboard = false,
    },

    {
        id = "heaviestWeight",
        label = "Heaviest Carried",
        tier = "B",
        mergeStrategy = "peak",
        format = "kg",
        sandboxOption = "HeaviestWeight",
        leaderboard = false,
    },

    {
        id = "mostKillsInDay",
        label = "Most Kills In A Day",
        tier = "B",
        mergeStrategy = "peak",
        format = "count",
        sandboxOption = "MostKillsInDay",
        leaderboard = true,
    },

    {
        id = "bulletsFired",
        label = "Bullets Fired",
        tier = "B",
        mergeStrategy = "cumulative",
        format = "count",
        sandboxOption = "BulletsFired",
        leaderboard = false,
    },

    {
        id = "itemsCrafted",
        label = "Items Crafted",
        tier = "B",
        mergeStrategy = "cumulative",
        format = "count",
        sandboxOption = "ItemsCrafted",
        leaderboard = true,
    },

    {
        id = "weaponsRepaired",
        label = "Weapons Repaired",
        tier = "B",
        mergeStrategy = "cumulative",
        format = "count",
        sandboxOption = "WeaponsRepaired",
        leaderboard = false,
    },

    {
        id = "weaponsDestroyed",
        label = "Weapons Destroyed",
        tier = "B",
        mergeStrategy = "cumulative",
        format = "count",
        sandboxOption = "WeaponsDestroyed",
        leaderboard = false,
    },

    {
        id = "treesChopped",
        label = "Trees Chopped",
        tier = "B",
        mergeStrategy = "cumulative",
        format = "count",
        sandboxOption = "TreesChopped",
        leaderboard = false,
    },

    {
        id = "firesLit",
        label = "Fires Lit",
        tier = "B",
        mergeStrategy = "cumulative",
        format = "count",
        sandboxOption = "FiresLit",
        leaderboard = false,
    },

    {
        id = "forageFinds",
        label = "Forage Finds",
        tier = "B",
        mergeStrategy = "cumulative",
        format = "count",
        sandboxOption = "ForageFinds",
        leaderboard = false,
    },

    {
        id = "plantsHarvested",
        label = "Plants Harvested",
        tier = "B",
        mergeStrategy = "cumulative",
        format = "count",
        sandboxOption = "PlantsHarvested",
        leaderboard = false,
    },

    {
        id = "fishCaught",
        label = "Fish Caught",
        tier = "B",
        mergeStrategy = "cumulative",
        format = "count",
        sandboxOption = "FishCaught",
        leaderboard = false,
    },

    {
        id = "trapsCaught",
        label = "Traps Caught",
        tier = "B",
        mergeStrategy = "cumulative",
        format = "count",
        sandboxOption = "TrapsCaught",
        leaderboard = false,
    },

    {
        id = "thingsBuilt",
        label = "Things Built",
        tier = "B",
        mergeStrategy = "cumulative",
        format = "count",
        sandboxOption = "ThingsBuilt",
        leaderboard = false,
    },

    {
        id = "favoriteWeapon",
        label = "Favorite Weapon",
        tier = "B",
        mergeStrategy = "peakPerKey",
        format = "text",
        sandboxOption = "FavoriteWeapon",
        leaderboard = false,
    },
}

--------------------------------------------------------------------
-- LOOKUP BY ID
--------------------------------------------------------------------

KIPN.Shared.StatsCatalog.ById = {}

for _, entry in ipairs(KIPN.Shared.StatsCatalog) do

    entry.dataKey =
        entry.dataKey
        or entry.id

    KIPN.Shared.StatsCatalog.ById[entry.id] =
        entry
end

--------------------------------------------------------------------
-- FORMAT VALUE
--
-- Shared so the Player tab, Server tab, and leaderboard sections all
-- render a given stat identically.
--
-- formatters (optional) maps an entry.format to a function(value)
-- that replaces the built-in metric rendering below -- the client
-- passes KIPN.Client.Preferences.StatsFormatters so distances and
-- weights follow the player's imperial/metric choice without this
-- shared file depending on client code.
--------------------------------------------------------------------

function KIPN.Shared.StatsCatalog.FormatValue(entry, value, formatters)

    if entry == nil then
        return tostring(value)
    end

    if value == nil then

        if entry.format == "text" then
            return "---"
        end

        value = 0
    end

    if entry.format == "text" then
        return tostring(value)
    end

    if formatters
        and formatters[entry.format] then

        return formatters[entry.format](value)
    end

    if entry.format == "count" then

        return string.format(
            "%d",
            tonumber(value) or 0
        )
    end

    if entry.format == "hours" then

        local hours = tonumber(value) or 0
        local days = math.floor(hours / 24)
        local remainingHours = hours - (days * 24)

        if days > 0 then

            return string.format(
                "%dd %.1fh",
                days,
                remainingHours
            )
        end

        return string.format(
            "%.1fh",
            remainingHours
        )
    end

    if entry.format == "meters" then

        local meters = tonumber(value) or 0

        if meters >= 1000 then

            return string.format(
                "%.1f km",
                meters / 1000
            )
        end

        return string.format(
            "%.0f m",
            meters
        )
    end

    if entry.format == "kg" then

        return string.format(
            "%.1f kg",
            tonumber(value) or 0
        )
    end

    if entry.format == "kcal" then

        return string.format(
            "%d kcal",
            tonumber(value) or 0
        )
    end

    return tostring(value)
end
