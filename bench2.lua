require("mock_wow_api")

local function run_baseline()
    local val = ""
    for i=1,10000 do
        val = UnitName("player") .. "-" .. GetRealmName()
    end
    return val
end

local playerCharKey = nil
local function run_optimized()
    local val = ""
    for i=1,10000 do
        playerCharKey = playerCharKey or (UnitName("player") .. "-" .. GetRealmName())
        val = playerCharKey
    end
    return val
end

local start = os.clock()
run_baseline()
print("Baseline:", os.clock() - start)

local start2 = os.clock()
run_optimized()
print("Optimized:", os.clock() - start2)
