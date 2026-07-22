local function UnitName(unit) return "PlayerName" end
local function GetRealmName() return "RealmName" end

local characterInfo = { charKey = "PlayerName-RealmName" }

local function check_tag_concat(tag)
    if tag:match("^char:") then
        local reqChar = tag:sub(6)
        local charKey = UnitName("player") .. "-" .. GetRealmName()
        return charKey == reqChar
    end
    return false
end

local function check_tag_cached(tag)
    if tag:match("^char:") then
        local reqChar = tag:sub(6)
        return characterInfo.charKey == reqChar
    end
    return false
end

local start = os.clock()
for i = 1, 10000000 do
    check_tag_concat("char:PlayerName-RealmName")
end
local t1 = os.clock() - start

start = os.clock()
for i = 1, 10000000 do
    check_tag_cached("char:PlayerName-RealmName")
end
local t2 = os.clock() - start

print(string.format("Concat: %.6f s", t1))
print(string.format("Cached: %.6f s", t2))
print(string.format("Improvement: %.2f%%", (t1 - t2) / t1 * 100))
