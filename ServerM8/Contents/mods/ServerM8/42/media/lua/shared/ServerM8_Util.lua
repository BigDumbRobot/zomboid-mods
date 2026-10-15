-- ServerM8 shared helpers. Nothing in here touches vanilla tables.

ServerM8 = ServerM8 or {}
ServerM8.MODULE = "ServerM8"

ServerM8.Theme = {
    bg       = { r = 0.06, g = 0.07, b = 0.09 },
    panel    = { r = 0.11, g = 0.13, b = 0.16 },
    border   = { r = 0.26, g = 0.30, b = 0.36 },
    accent   = { r = 0.36, g = 0.78, b = 0.55 },
    text     = { r = 0.95, g = 0.96, b = 0.97 },
    muted    = { r = 0.60, g = 0.66, b = 0.72 },
    good     = { r = 0.40, g = 0.82, b = 0.50 },
    warn     = { r = 0.95, g = 0.72, b = 0.30 },
    bad      = { r = 0.92, g = 0.38, b = 0.36 },
    info     = { r = 0.45, g = 0.68, b = 0.95 },
    discord  = { r = 0.345, g = 0.396, b = 0.949 },
}

local INVITE_PATTERNS = {
    "[Dd][Ii][Ss][Cc][Oo][Rr][Dd]%.[Gg][Gg]/([%w%-]+)",
    "[Dd][Ii][Ss][Cc][Oo][Rr][Dd]%.[Cc][Oo][Mm]/[Ii][Nn][Vv][Ii][Tt][Ee]/([%w%-]+)",
    "[Dd][Ii][Ss][Cc][Oo][Rr][Dd][Aa][Pp][Pp]%.[Cc][Oo][Mm]/[Ii][Nn][Vv][Ii][Tt][Ee]/([%w%-]+)",
}

local function trim(text)
    return (string.gsub(tostring(text or ""), "^%s*(.-)%s*$", "%1"))
end
ServerM8.trim = trim

-- Returns the invite code from any Discord invite link found in text, or nil.
function ServerM8.findDiscordInvite(text)
    if not text or text == "" then return nil end
    for _, pattern in ipairs(INVITE_PATTERNS) do
        local code = string.match(text, pattern)
        if code and code ~= "" then return code end
    end
    return nil
end

-- Accepts a full invite link or a bare invite code. Returns the code, or nil.
function ServerM8.normalizeInvite(value)
    value = trim(value)
    if value == "" then return nil end
    local code = ServerM8.findDiscordInvite(value)
    if code then return code end
    if string.match(value, "^[%w%-]+$") then return value end
    return nil
end

-- Discord server IDs are digits only.
function ServerM8.normalizeGuildID(value)
    value = trim(value)
    if string.match(value, "^%d+$") then return value end
    return nil
end

function ServerM8.normalizeWebsite(value)
    value = trim(value)
    if string.match(value, "^https?://[%w%-%._~:/%?#@!%$&%+,;=%%]+$") then return value end
    return nil
end

function ServerM8.inviteUrl(code)
    return "https://discord.gg/" .. code
end

function ServerM8.widgetUrl(guildID)
    return "https://discord.com/widget?id=" .. guildID .. "&theme=dark"
end

-- Pulls #hashtags out of a server description so the browser can show them as chips.
function ServerM8.findHashtags(text, limit)
    local tags, seen = {}, {}
    if not text or text == "" then return tags end
    limit = limit or 6
    for tag in string.gmatch(text, "#(%a[%w_]+)") do
        local key = string.lower(tag)
        if not seen[key] and #tag <= 16 then
            seen[key] = true
            table.insert(tags, tag)
            if #tags >= limit then break end
        end
    end
    return tags
end

-- Makes untrusted text safe to place inside an ISRichTextPanel.
function ServerM8.escape(text)
    text = tostring(text or "")
    text = string.gsub(text, "<", "&lt")
    text = string.gsub(text, ">", "&gt")
    return text
end

-- Turns a plain multi-line string into rich text line breaks.
function ServerM8.toRichText(text)
    text = tostring(text or "")
    text = string.gsub(text, "\r", "")
    text = string.gsub(text, "\n", " <LINE> ")
    return text
end

function ServerM8.rgb(c)
    return string.format(" <RGB:%.2f,%.2f,%.2f> ", c.r, c.g, c.b)
end

function ServerM8.ago(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    if seconds < 60 then return "just now" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
    return math.floor(seconds / 86400) .. "d ago"
end

function ServerM8.duration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if days > 0 then return days .. "d " .. hours .. "h" end
    if hours > 0 then return hours .. "h " .. minutes .. "m" end
    return minutes .. "m"
end
