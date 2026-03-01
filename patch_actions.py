import re

with open("modules/Actions.lua", "r") as f:
    content = f.read()

# Instead of hardcoding rules in Actions.lua, we should call Wise:IsNestingAllowed
# Actually, since we now allow overriding the child's type within the parent's action properties,
# filtering out groups in the picker based on their *global* type makes less sense.
# We should allow ANY interface to be picked, because the user can change its mode
# via the Nesting Options override.
# Let's remove the strict type-based filtering from the picker and just allow it if there's no cycle.

# We will replace the whole block:
old_code = """                local allowed = true

                -- Determine if parent is a Line (box with 1 row or 1 column)
                local parentIsLine = (parentGroup.type == "box") and (parentGroup.boxWidth == 1 or parentGroup.boxHeight == 1)

                -- Rule: Circles can only nest into other circles
                if group.type == "circle" and parentType ~= "circle" then
                    allowed = false
                end

                -- Rule: Boxes (grids) can't nest; only Lines (box with 1 dimension) can
                if group.type == "box" then
                    local isLine = (group.boxWidth == 1 or group.boxHeight == 1)

                    if not isLine then
                         -- Grid box: never allowed as child
                         allowed = false
                    elseif parentIsLine then
                         -- Line into Line: must be perpendicular
                         local pAxis = parentGroup.fixedAxis or "x"
                         local cAxis = group.fixedAxis or "x"
                         if pAxis == cAxis then allowed = false end
                    end
                end"""

new_code = """                -- All nesting allowed initially since child mode can be overridden
                local allowed = true"""

if old_code in content:
    content = content.replace(old_code, new_code)
    with open("modules/Actions.lua", "w") as f:
        f.write(content)
else:
    print("Could not find old_code")
