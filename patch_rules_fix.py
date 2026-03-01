import re

with open("modules/Nesting.lua", "r") as f:
    content = f.read()

# Fix the placement of the rule
bad_chunk = """    local childIsLine = (childGroup.boxWidth == 1 or childGroup.boxHeight == 1)
    if not childIsLine then return false end

-- List -> List: allowed

NESTING_LAYOUT_RULES["list_list"] = function(parentGroup, childGroup)
    return true
end

    if not parentIsLine then return false end
    local pAxis = parentGroup.fixedAxis or "x"
    local cAxis = childGroup.fixedAxis or "x"
    return pAxis ~= cAxis
end"""

fixed_chunk = """    local childIsLine = (childGroup.boxWidth == 1 or childGroup.boxHeight == 1)
    if not childIsLine then return false end
    if not parentIsLine then return false end
    local pAxis = parentGroup.fixedAxis or "x"
    local cAxis = childGroup.fixedAxis or "x"
    return pAxis ~= cAxis
end

-- List -> List: allowed
NESTING_LAYOUT_RULES["list_list"] = function(parentGroup, childGroup)
    return true
end
"""

content = content.replace(bad_chunk, fixed_chunk)

with open("modules/Nesting.lua", "w") as f:
    f.write(content)
