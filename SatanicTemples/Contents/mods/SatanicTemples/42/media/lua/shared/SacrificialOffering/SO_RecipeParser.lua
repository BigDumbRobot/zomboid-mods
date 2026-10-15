require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"

local SO = SacrificialOffering
SO.RecipeParser = SO.RecipeParser or {}
local Parser = SO.RecipeParser

local function split(value, separatorPattern)
    local result = {}
    for part in tostring(value or ""):gmatch("([^" .. separatorPattern .. "]+)") do
        table.insert(result, SO.Util.Trim(part))
    end
    return result
end

function Parser.ParsePart(rawPart)
    local part = SO.Util.Trim(rawPart)
    if part == "" then return nil end
    local countText, fullType = part:match("^(%d+)%s*%*%s*([%w_%-]+%.[%w_%-]+)$")
    local count = tonumber(countText)
    if not fullType then
        fullType = part:match("^([%w_%-]+%.[%w_%-]+)$")
        count = 1
    end
    if not fullType or not count or count < 1 or count > 1000 then return nil end
    return { fullType = fullType, count = math.floor(count) }
end

function Parser.Parse(rawRecipes)
    local recipes = {}
    for _, rawRecipe in ipairs(split(rawRecipes, ";")) do
        local recipe = { parts = {}, source = rawRecipe }
        local valid = true
        for _, rawPart in ipairs(split(rawRecipe, "+")) do
            local parsed = Parser.ParsePart(rawPart)
            if not parsed then
                valid = false
                break
            end
            table.insert(recipe.parts, parsed)
        end
        if valid and #recipe.parts > 0 then table.insert(recipes, recipe) end
    end
    return recipes
end

function Parser.CountItems(items)
    local counts = {}
    if items then
        for _, item in ipairs(items) do
            local fullType = item
            if type(item) ~= "string" and item and item.getFullType then fullType = item:getFullType() end
            if fullType then counts[fullType] = (counts[fullType] or 0) + 1 end
        end
    end
    return counts
end

function Parser.MatchesCounts(recipes, counts)
    for _, recipe in ipairs(recipes or {}) do
        local matches = true
        for _, part in ipairs(recipe.parts) do
            if (counts[part.fullType] or 0) < part.count then
                matches = false
                break
            end
        end
        if matches then return true, recipe end
    end
    return false, nil
end

function Parser.MatchesItems(rawRecipes, items)
    return Parser.MatchesCounts(Parser.Parse(rawRecipes), Parser.CountItems(items))
end

return Parser
