-- KIPN_SafehouseOverlayPreference.lua
--
-- Client-local persistence for the administrator Safehouse map-overlay
-- toggle (KIPN_SafehouseOverlayRenderer.lua). This is NOT a server-wide
-- gameplay/sandbox setting -- it is a per-admin, per-client UI
-- preference, stored on the client machine only, the same way vanilla
-- persists admin UI preferences (see ISUI/AdminPanel/ISAdminPowerUI.lua's
-- CheatPanel.ini).
--
-- The stored payload is a single boolean, written as a bare
-- "true" / "false" line rather than JSON because KIPN.Json (cjson) is
-- not reliably available on the client. Load() also accepts the
-- earlier {"enabled":true} JSON form.

require "KIPN_Shared"

KIPN = KIPN or {}
KIPN.Client = KIPN.Client or {}
KIPN.Client.SafehouseOverlayPreference = KIPN.Client.SafehouseOverlayPreference or {}

local Preference = KIPN.Client.SafehouseOverlayPreference

local FALLBACK_FILENAME = "KIPN_SafehouseOverlayPref.json"

local function log(message)
    print("[KIPN SAFEHOUSE OVERLAY PREF] " .. tostring(message))
end

local function logError(message)
    print("[KIPN SAFEHOUSE OVERLAY PREF] ERROR: " .. tostring(message))
end

-- Keyed by username where possible so multiple admins sharing one client
-- machine don't clobber each other's preference. Falls back to a plain
-- filename if the local player isn't available yet (e.g. called very
-- early during load) rather than failing outright.
local function resolveFilename()
    local ok, player = pcall(getSpecificPlayer, 0)

    if ok and player then
        local usernameOk, username = pcall(function() return player:getUsername() end)
        if usernameOk and username and username ~= "" then
            return "KIPN_SafehouseOverlayPref_" .. tostring(username) .. ".json"
        end
    end

    return FALLBACK_FILENAME
end

function Preference.Save(enabled)
    local ok, err = pcall(function()
        local filename = resolveFilename()
        local encoded = (enabled == true) and "true" or "false"
        local writer = getFileWriter(filename, true, false)
        if not writer then
            error("getFileWriter() returned nil for " .. tostring(filename))
        end
        writer:write(encoded)
        writer:close()
    end)

    if not ok then
        logError("Save() failed: " .. tostring(err))
        return false
    end

    log("Saved preference | enabled=" .. tostring(enabled == true))
    return true
end

function Preference.Load()
    local result = false

    local ok, err = pcall(function()
        local filename = resolveFilename()
        local reader = getFileReader(filename, true)
        if not reader then
            return
        end

        local line = reader:readLine()
        reader:close()

        if type(line) ~= "string" or line == "" then
            return
        end

        -- Bare "true" (current format) or a legacy {"enabled":true} JSON
        -- line. A stored "false" / {"enabled":false} contains no "true".
        if string.find(line, "true", 1, true) ~= nil then
            result = true
        end
    end)

    if not ok then
        logError("Load() failed: " .. tostring(err))
        return false
    end

    return result
end

print("[KIPN] Safehouse Overlay Preference loaded")
