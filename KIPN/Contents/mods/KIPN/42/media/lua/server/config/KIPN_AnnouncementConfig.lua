-- KIPN_AnnouncementConfig.lua
--
-- Server-authoritative KIPN announcement configuration.
--
-- The Discord side of announcements is handled entirely outside the
-- game by two optional admin helper programs from the KIPN GitHub
-- page (a config .html tool and a Python poster) -- see the DISCORD
-- FEED CONTRACT comment in KIPN_AnnouncementService.lua. KIPN only
-- reads the plain-text files they produce in Zomboid/Lua/, so there
-- is no in-game / sandbox Discord option to configure any more.
--
-- This module is kept as the config seam for announcements (file
-- names, caps) in case a future option needs a home; today it just
-- exposes the helper file names and a no-op Initialize().

if isClient() then return end

require "KIPN_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.AnnouncementConfig = KIPN.Server.AnnouncementConfig or {}

local AnnouncementConfig = KIPN.Server.AnnouncementConfig

------------------------------------------------------------
-- HELPER FILE NAMES  (in Zomboid/Lua/; must end in .txt)
------------------------------------------------------------

AnnouncementConfig.ChannelsFile = "KIPN_DiscordChannels.txt"
AnnouncementConfig.FeedFile = "KIPN_DiscordFeed.txt"

------------------------------------------------------------
-- INITIALIZE
------------------------------------------------------------

function AnnouncementConfig.Initialize()
    print("[KIPN ANNOUNCEMENT CONFIG] Initialized.")
    return true
end
