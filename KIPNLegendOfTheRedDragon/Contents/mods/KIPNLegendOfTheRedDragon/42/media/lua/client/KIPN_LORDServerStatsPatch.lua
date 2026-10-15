-- KIPN_LORDServerStatsPatch.lua
--
-- Adds a "Legend of the Red Dragon" panel to KIPN Terminal's built-in
-- Server Statistics screen -- but only when this mod is installed.
--
-- KIPN's Server Stats screen has no formal "add a section" hook, so
-- this wraps three methods on the KIPN_ServerStats class (the same
-- technique companion mods use to extend the Zone Editor):
--
--   * requestStatistics()  -> also ask the server for the LORD board
--     (fires on open and on the screen's own 30s refresh)
--   * receiveResponse()    -> capture LORD_LEADERBOARD_DATA
--   * renderServerTab()    -> draw the panel below KIPN's own content
--
-- If KIPN_ServerStats is missing or shaped differently, this bails
-- quietly and the rest of the mod is unaffected.

if isServer() then return end

require "KIPN_UI"
require "KIPN_LORDShared"

local okAPI = KIPN.API and KIPN.API.Require and KIPN.API.Require(KIPN.LORD.API_VERSION)
if not okAPI then return end

local SS = _G.KIPN_ServerStats
if type(SS) ~= "table" then
    print("[KIPN LORD] KIPN_ServerStats not found -- leaderboard panel not attached")
    return
end

local Cmds   = KIPN.Shared.Commands
local Events  = KIPN.Shared.ResponseEvents
local Theme   = KIPN.UI.Theme

local function txt(self, s, x, y, col)
    col = col or Theme.text
    self:drawText(tostring(s), x, KIPN.UI.ScrollY(self, y), col.r, col.g, col.b, col.a, Theme.fontBody)
end

--------------------------------------------------------------------
-- 1. also request the LORD board whenever the screen (re)loads stats
--------------------------------------------------------------------

local _requestStatistics = SS.requestStatistics
function SS:requestStatistics(...)
    if _requestStatistics then _requestStatistics(self, ...) end
    if Cmds and Cmds.LORD_LEADERBOARD then
        pcall(sendClientCommand, "KIPN", Cmds.LORD_LEADERBOARD, {})
    end
end

--------------------------------------------------------------------
-- 2. capture the response, then hand off to KIPN's own router
--------------------------------------------------------------------

local _receiveResponse = SS.receiveResponse
function SS:receiveResponse(event, data)
    if event == Events.LORD_LEADERBOARD_DATA and type(data) == "table" then
        self._lordBoard = data
    end
    if _receiveResponse then return _receiveResponse(self, event, data) end
end

--------------------------------------------------------------------
-- 3. draw the panel under KIPN's own SERVER-tab content
--------------------------------------------------------------------

local _renderServerTab = SS.renderServerTab
function SS:renderServerTab(y)
    local endY = y
    if _renderServerTab then
        local r = _renderServerTab(self, y)
        if type(r) == "number" then endY = r end
    end

    local board = self._lordBoard
    if type(board) ~= "table" then return endY end
    local slayers = type(board.slayers) == "table" and board.slayers or {}
    local advs    = type(board.adventurers) == "table" and board.adventurers or {}
    if #slayers == 0 and #advs == 0 then return endY end

    local yy = KIPN.UI.DrawSectionHeader(self, endY + 6, "LEGEND OF THE RED DRAGON")

    if #slayers > 0 then
        txt(self, "DRAGON SLAYERS", 25, yy, Theme.accent); yy = yy + 20
        for i, h in ipairs(slayers) do
            if i > 10 then break end
            txt(self, string.format("%d. %s  -  %d dragon kill(s), last wielding %s",
                i, tostring(h.name or "?"), tonumber(h.dragonKills) or 0, tostring(h.weapon or "a stick")),
                30, yy)
            yy = yy + 18
        end
        yy = yy + 8
    end

    if #advs > 0 then
        txt(self, "TOP ADVENTURERS", 25, yy, Theme.accent); yy = yy + 20
        for i, a in ipairs(advs) do
            local kills = tonumber(a.dragonKills) or 0
            txt(self, string.format("%d. %s  -  level %d%s",
                i, tostring(a.name or "?"), tonumber(a.level) or 1,
                kills > 0 and string.format("  (%d dragon)", kills) or ""),
                30, yy)
            yy = yy + 18
        end
    end

    return yy + 10
end

print("[KIPN] Legend of the Red Dragon -- Server Stats panel attached")
