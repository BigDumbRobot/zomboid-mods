-- Project Zomboid runs mods on Kahlua, roughly Lua 5.1 without some standard
-- globals. The other checks run on stock Lua, so they would not notice a mod
-- file calling something Kahlua lacks. This scans every mod file instead.
-- Run from this Workshop project directory.
local forbidden = {
    { "[^:%.%w_]next%s*%(", "next() (Kahlua has no next; loop with pairs)" },
    { "^next%s*%(", "next() (Kahlua has no next; loop with pairs)" },
    { "%f[%w_]goto%f[^%w_]", "goto" },
    { "%f[%w_]rawlen%s*%(", "rawlen()" },
    { "table%.move", "table.move" },
    { "table%.pack", "table.pack" },
    { "utf8%.", "utf8 library" },
    { "string%.pack", "string.pack" },
    { "math%.tointeger", "math.tointeger" },
    { "math%.type", "math.type" },
    { "%f[%w_]io%.", "io library" },
    { "%f[%w_]load%s*%(", "load()" },
    { "%f[%w_]debug%.", "debug library" },
    { "<const>", "<const>" },
    { "<close>", "<close>" },
    -- The game calls a UI element's update/render/prerender every frame with no
    -- arguments, so a method of that name expecting one fails every frame.
    { "function%s+[%w_%.]+:update%s*%(%s*[%w_]", "update(...) with arguments (the game calls update() every frame)" },
    { "function%s+[%w_%.]+:render%s*%(%s*[%w_]", "render(...) with arguments (the game calls render() every frame)" },
    { "function%s+[%w_%.]+:prerender%s*%(%s*[%w_]", "prerender(...) with arguments (the game calls prerender() every frame)" },
}
local failures = {}
local list = io.popen('find Contents -name "*.lua"')
local count = 0
for path in list:lines() do
    count = count + 1
    local number = 0
    for line in io.lines(path) do
        number = number + 1
        local code = line:gsub("%-%-.*$", ""):gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")
        for _, rule in ipairs(forbidden) do
            if code:find(rule[1]) then failures[#failures + 1] = path .. ":" .. number .. ": " .. rule[2] end
        end
        if code:find("table%.unpack") and not code:find("unpack or table%.unpack") then
            failures[#failures + 1] = path .. ":" .. number .. ": table.unpack without the unpack fallback"
        end
    end
end
list:close()
assert(count > 0, "no mod files found; run from the project directory")
assert(#failures == 0, "Kahlua-incompatible code:\n" .. table.concat(failures, "\n"))
print("PASS: " .. count .. " mod files use only Lua features Kahlua provides")
