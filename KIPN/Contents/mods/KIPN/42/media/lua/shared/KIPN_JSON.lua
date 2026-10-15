-- KIPN_JSON.lua
--
-- Safe JSON encode / decode + optional file persistence for KIPN.
--
-- Hotfix context:
--   Project Zomboid Build 42's Lua sandbox (Kahlua) does NOT ship a
--   usable `cjson` module -- `require "cjson"` throws -- so the old
--   detection block always failed and every KIPN.Json.WriteFile call
--   spammed the log with "JSON library unavailable" and wrote nothing.
--
--   This module now carries a small pure-Lua JSON implementation that
--   is used whenever a native library is absent, so encode / decode
--   and the diagnostic file export actually work on a stock B42 server.
--
--   File I/O goes through B42's getFileWriter / getFileReader (the same
--   API KIPN_Logger uses). Those only work with a `.txt` filename and
--   are rooted at Zomboid/Lua/, so a caller path like "kipn_data.json"
--   is written to  Zomboid/Lua/kipn_data.json.txt .
--
-- IMPORTANT:
--   * ModData remains the AUTHORITATIVE persistence store.
--   * The exported file is a DIAGNOSTIC / BACKUP artifact, never a
--     substitute for the ModData database.
--   * All file access is guarded with pcall so a missing/renamed
--     filesystem API can never crash KIPN.
--
-- SERVER AUTHORITY:
--   Persistent file writes are server-only. Clients may still use
--   Encode()/Decode() for UI formatting.

KIPN = KIPN or {}
KIPN.Json = KIPN.Json or {}

------------------------------------------------------------
-- LOGGING (quiet by default)
------------------------------------------------------------
--
-- Everything routine goes through the KIPN logger at DEBUG, which is
-- below the default INFO threshold and therefore silent -- that is the
-- whole point of this rewrite. Only genuine failures reach WARN/ERROR.
-- Before the logger module has loaded (shared files load alphabetically
-- and KIPN_Logger sorts after KIPN_JSON) we simply stay quiet unless it
-- is a hard error.

local function jlog(level, message)
    if KIPN and KIPN.Logger and type(KIPN.Logger.Log) == "function" then
        KIPN.Logger.Log(level, "[JSON] " .. tostring(message))
        return
    end

    if level == "ERROR" or level == "WARN" then
        print("[KIPN JSON] " .. tostring(message))
    end
end

------------------------------------------------------------
-- NATIVE JSON LIBRARY DETECTION (best effort)
------------------------------------------------------------
--
-- If a future build (or another mod) provides a real cjson-style
-- module, prefer it. Otherwise fall through to the pure-Lua codec
-- below. Either way KIPN.Json.Available() returns true.

local native = nil

do
    -- Single quiet probe. Kahlua's own require() logs a WARN when the
    -- module is missing (it always is on B42), so probing a list of
    -- names would just multiply that one-time boot warning.
    local ok, value = pcall(require, "cjson")
    if ok and type(value) == "table"
        and type(value.encode) == "function"
        and type(value.decode) == "function"
    then
        native = value
    end
end

------------------------------------------------------------
-- PURE-LUA JSON CODEC
------------------------------------------------------------
--
-- Small, dependency-free, and careful about the Kahlua runtime
-- (no `next`, patterns kept simple). Not a spec-perfect parser, but
-- correct for the round-trip of KIPN's plain data tables.

local pureEncode
local pureDecode

do
    ----------------------------------------------------------
    -- ENCODE
    ----------------------------------------------------------

    local ESCAPES = {
        ['"']  = '\\"',
        ['\\'] = '\\\\',
        ['\b'] = '\\b',
        ['\f'] = '\\f',
        ['\n'] = '\\n',
        ['\r'] = '\\r',
        ['\t'] = '\\t',
    }

    local function encodeString(s)
        local out = s:gsub('[%c\\"]', function(c)
            return ESCAPES[c] or string.format('\\u%04x', string.byte(c))
        end)
        return '"' .. out .. '"'
    end

    local function encodeNumber(n)
        -- Kahlua numbers are all doubles. Reject non-finite values
        -- (JSON has no representation) and emit a compact form.
        if n ~= n or n == math.huge or n == -math.huge then
            return "null"
        end

        if n == math.floor(n) and math.abs(n) < 1e15 then
            return string.format("%d", n)
        end

        return string.format("%.14g", n)
    end

    -- Returns true if t is a 1..n integer-keyed sequence.
    local function isArray(t)
        local count = 0
        for _ in pairs(t) do
            count = count + 1
        end

        if count == 0 then
            return false, 0
        end

        for i = 1, count do
            if t[i] == nil then
                return false, count
            end
        end

        return true, count
    end

    local function encodeValue(value, seen, depth, parts)
        local vt = type(value)

        if value == nil then
            parts[#parts + 1] = "null"

        elseif vt == "boolean" then
            parts[#parts + 1] = value and "true" or "false"

        elseif vt == "number" then
            parts[#parts + 1] = encodeNumber(value)

        elseif vt == "string" then
            parts[#parts + 1] = encodeString(value)

        elseif vt == "table" then
            if seen[value] then
                error("cannot encode a table that refers to itself")
            end

            if depth > 200 then
                error("JSON structure nested too deep (>200)")
            end

            seen[value] = true

            local array, count = isArray(value)

            if array then
                parts[#parts + 1] = "["
                for i = 1, count do
                    if i > 1 then
                        parts[#parts + 1] = ","
                    end
                    encodeValue(value[i], seen, depth + 1, parts)
                end
                parts[#parts + 1] = "]"
            else
                parts[#parts + 1] = "{"
                local first = true
                for k, v in pairs(value) do
                    local kt = type(k)
                    if kt == "string" or kt == "number" then
                        if not first then
                            parts[#parts + 1] = ","
                        end
                        first = false
                        parts[#parts + 1] = encodeString(tostring(k))
                        parts[#parts + 1] = ":"
                        encodeValue(v, seen, depth + 1, parts)
                    end
                end
                parts[#parts + 1] = "}"
            end

            seen[value] = nil

        else
            -- function / userdata / thread have no JSON form. This
            -- module's writers are diagnostic snapshots, so degrade to
            -- a readable placeholder rather than aborting the whole
            -- dump over one stray value.
            parts[#parts + 1] = encodeString("<" .. vt .. ">")
        end
    end

    function pureEncode(value)
        local parts = {}
        encodeValue(value, {}, 0, parts)
        return table.concat(parts)
    end

    ----------------------------------------------------------
    -- DECODE
    ----------------------------------------------------------

    local DECODE_ESCAPES = {
        ['"']  = '"',
        ['\\'] = '\\',
        ['/']  = '/',
        ['b']  = '\b',
        ['f']  = '\f',
        ['n']  = '\n',
        ['r']  = '\r',
        ['t']  = '\t',
    }

    -- Minimal BMP code point -> UTF-8 (surrogate pairs handled
    -- best-effort as their raw code units).
    local function codepointToUtf8(cp)
        if cp < 0x80 then
            return string.char(cp)
        elseif cp < 0x800 then
            return string.char(
                0xC0 + math.floor(cp / 0x40),
                0x80 + (cp % 0x40)
            )
        else
            return string.char(
                0xE0 + math.floor(cp / 0x1000),
                0x80 + (math.floor(cp / 0x40) % 0x40),
                0x80 + (cp % 0x40)
            )
        end
    end

    local parseValue

    local function skipWhitespace(s, i)
        local _, j = s:find("^[ \t\r\n]*", i)
        return (j or i - 1) + 1
    end

    local function parseString(s, i)
        -- s:sub(i) == '"'
        i = i + 1
        local buf = {}

        while true do
            local c = s:sub(i, i)

            if c == "" then
                error("unterminated string in JSON")
            elseif c == '"' then
                return table.concat(buf), i + 1
            elseif c == '\\' then
                local e = s:sub(i + 1, i + 1)

                if e == "u" then
                    local hex = s:sub(i + 2, i + 5)
                    if not hex:find("^%x%x%x%x$") then
                        error("bad \\u escape in JSON")
                    end
                    buf[#buf + 1] = codepointToUtf8(tonumber(hex, 16))
                    i = i + 6
                elseif DECODE_ESCAPES[e] then
                    buf[#buf + 1] = DECODE_ESCAPES[e]
                    i = i + 2
                else
                    error("bad escape '\\" .. e .. "' in JSON")
                end
            else
                buf[#buf + 1] = c
                i = i + 1
            end
        end
    end

    local function parseNumber(s, i)
        local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
        if not num or num == "" then
            error("invalid number in JSON")
        end
        local value = tonumber(num)
        if value == nil then
            error("invalid number '" .. num .. "' in JSON")
        end
        return value, i + #num
    end

    local function parseArray(s, i)
        i = i + 1
        local arr = {}
        local n = 0
        i = skipWhitespace(s, i)

        if s:sub(i, i) == "]" then
            return arr, i + 1
        end

        while true do
            local value
            value, i = parseValue(s, i)
            n = n + 1
            arr[n] = value

            i = skipWhitespace(s, i)
            local c = s:sub(i, i)

            if c == "," then
                i = skipWhitespace(s, i + 1)
            elseif c == "]" then
                return arr, i + 1
            else
                error("expected ',' or ']' in JSON array")
            end
        end
    end

    local function parseObject(s, i)
        i = i + 1
        local obj = {}
        i = skipWhitespace(s, i)

        if s:sub(i, i) == "}" then
            return obj, i + 1
        end

        while true do
            i = skipWhitespace(s, i)
            if s:sub(i, i) ~= '"' then
                error("expected string key in JSON object")
            end

            local key
            key, i = parseString(s, i)

            i = skipWhitespace(s, i)
            if s:sub(i, i) ~= ":" then
                error("expected ':' in JSON object")
            end

            local value
            value, i = parseValue(s, skipWhitespace(s, i + 1))
            obj[key] = value

            i = skipWhitespace(s, i)
            local c = s:sub(i, i)

            if c == "," then
                i = i + 1
            elseif c == "}" then
                return obj, i + 1
            else
                error("expected ',' or '}' in JSON object")
            end
        end
    end

    function parseValue(s, i)
        i = skipWhitespace(s, i)
        local c = s:sub(i, i)

        if c == '"' then
            return parseString(s, i)
        elseif c == "{" then
            return parseObject(s, i)
        elseif c == "[" then
            return parseArray(s, i)
        elseif c == "-" or c:find("%d") then
            return parseNumber(s, i)
        elseif s:sub(i, i + 3) == "true" then
            return true, i + 4
        elseif s:sub(i, i + 4) == "false" then
            return false, i + 5
        elseif s:sub(i, i + 3) == "null" then
            return nil, i + 4
        end

        error("unexpected character '" .. c .. "' in JSON")
    end

    function pureDecode(text)
        local value, i = parseValue(text, 1)
        i = skipWhitespace(text, i)
        if i <= #text then
            error("trailing content after JSON value")
        end
        return value
    end
end

------------------------------------------------------------
-- PUBLIC ENCODE / DECODE
------------------------------------------------------------

local usingNative = native ~= nil

function KIPN.Json.Available()
    return true
end

-- True when a compiled JSON module is in use rather than the built-in
-- pure-Lua codec. Informational only.
function KIPN.Json.IsNative()
    return usingNative
end

function KIPN.Json.Encode(value)
    local ok, result = pcall(function()
        if native then
            return native.encode(value)
        end
        return pureEncode(value)
    end)

    if not ok then
        return nil, false, tostring(result)
    end

    return result, true, nil
end

function KIPN.Json.Decode(text)
    if type(text) ~= "string" or text == "" then
        return nil, false, "empty or non-string JSON input"
    end

    local ok, result = pcall(function()
        local value
        if native then
            value = native.decode(text)
        else
            value = pureDecode(text)
        end

        if value == nil then
            error("JSON decoded to nil")
        end

        return value
    end)

    if not ok then
        return nil, false, tostring(result)
    end

    return result, true, nil
end

------------------------------------------------------------
-- FILESYSTEM ACCESS (GUARDED)
------------------------------------------------------------
--
-- B42 exposes getFileWriter(name, createIfNull, append) and
-- getFileReader(name, createIfNull). Both are rooted at Zomboid/Lua/
-- and only accept a filename ending in `.txt` -- anything else makes
-- them return nil silently. So a logical path like "KIPN/kipn_data.json"
-- is flattened to its basename and given a `.txt` suffix.

local function toDiskName(relativePath)
    local name = tostring(relativePath or "")

    -- Keep only the final path segment; the API has one flat root.
    name = name:match("[^/\\]+$") or name

    if name == "" then
        name = "kipn_data.json"
    end

    if name:sub(-4):lower() ~= ".txt" then
        name = name .. ".txt"
    end

    return name
end

-- Expose the resolved on-disk name so callers / docs can point at it.
function KIPN.Json.DiskName(relativePath)
    return toDiskName(relativePath)
end

-- Writes a Lua value to Zomboid/Lua/<basename>.txt as JSON.
--
-- Server-only by design: persistent files are server-authoritative.
-- Returns true on success, false otherwise (never throws).
function KIPN.Json.WriteFile(relativePath, value)
    if isClient and isClient() then
        jlog("DEBUG", "WriteFile skipped on client (server-authoritative).")
        return false
    end

    if type(getFileWriter) ~= "function" then
        jlog("WARN", "WriteFile skipped: getFileWriter() unavailable in this build.")
        return false
    end

    local encoded, encodeOk, encodeErr = KIPN.Json.Encode(value)

    if not encodeOk then
        jlog("WARN", "WriteFile encode failed: " .. tostring(encodeErr))
        return false
    end

    local diskName = toDiskName(relativePath)
    local writer = nil

    local writeOk, writeErr = pcall(function()
        -- createIfNull = true, append = false  (overwrite each save)
        writer = getFileWriter(diskName, true, false)

        if not writer then
            error("getFileWriter() returned nil for " .. diskName)
        end

        writer:write(encoded)
        writer:close()
        writer = nil
    end)

    if not writeOk then
        if writer then
            pcall(function() writer:close() end)
        end
        jlog("WARN", "WriteFile failed for " .. diskName .. ": " .. tostring(writeErr))
        return false
    end

    jlog("DEBUG", "Wrote " .. diskName .. " (" .. tostring(#encoded) .. " bytes).")
    return true
end

-- Reads and decodes Zomboid/Lua/<basename>.txt.
--
-- Returns (value, true, nil) on success, (nil, false, error) on failure.
function KIPN.Json.ReadFile(relativePath)
    if type(getFileReader) ~= "function" then
        return nil, false, "getFileReader() unavailable in this build"
    end

    local diskName = toDiskName(relativePath)
    local reader = nil

    local readOk, text = pcall(function()
        reader = getFileReader(diskName, false)

        if not reader then
            return nil
        end

        local lines = {}
        while true do
            local line = reader:readLine()
            if line == nil then
                break
            end
            lines[#lines + 1] = line
        end

        reader:close()
        reader = nil

        return table.concat(lines, "\n")
    end)

    if reader then
        pcall(function() reader:close() end)
    end

    if not readOk then
        jlog("WARN", "ReadFile failed for " .. diskName .. ": " .. tostring(text))
        return nil, false, tostring(text)
    end

    if text == nil or text == "" then
        return nil, false, "file is empty or missing: " .. diskName
    end

    local value, decodeOk, decodeErr = KIPN.Json.Decode(text)

    if not decodeOk then
        jlog("WARN", "ReadFile decode failed for " .. diskName .. ": " .. tostring(decodeErr))
        return nil, false, decodeErr
    end

    return value, true, nil
end

jlog("INFO", usingNative
    and "Module loaded (native JSON library in use)."
    or  "Module loaded (pure-Lua codec).")
