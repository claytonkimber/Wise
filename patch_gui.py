import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

# We need to determine the interface mode for nested interfaces dynamically
# In `Wise:UpdateGroupDisplay` around line 2827:

# Find:
#     local group = WiseDB.groups[name]

# Look at the code where ApplyLayout is called
# 2827:         Wise:ApplyLayout(f.visualDisplay, group.type, #actionsToShow, name)
# 2874:    Wise:ApplyLayout(f, group.type, #actionsToShow, name)

# Instead of using group.type, we should use an overridden type.
# We can find this by checking GetParentInfo and fetching the nestedInterfaceType.

new_layout_code = """
    local displayType = group.type or "circle"
    local parentName, parentGroup = Wise:GetParentInfo(name)
    if parentName and parentGroup then
        for _, states in pairs(parentGroup.actions or {}) do
            if type(states) == "table" then
                for _, action in ipairs(states) do
                    if action.type == "interface" and action.value == name then
                        local opts = Wise:GetNestingOptions(action)
                        if opts and opts.nestedInterfaceType and opts.nestedInterfaceType ~= "default" then
                            displayType = opts.nestedInterfaceType
                        end
                    end
                end
            end
        end
    end
"""

# Now replace `Wise:ApplyLayout(f.visualDisplay, group.type, #actionsToShow, name)`
# and `Wise:ApplyLayout(f, group.type, #actionsToShow, name)` with displayType

content = content.replace(
    "Wise:ApplyLayout(f.visualDisplay, group.type, #actionsToShow, name)",
    new_layout_code + "\n        Wise:ApplyLayout(f.visualDisplay, displayType, #actionsToShow, name)"
)

content = content.replace(
    "Wise:ApplyLayout(f, group.type, #actionsToShow, name)",
    "Wise:ApplyLayout(f, displayType, #actionsToShow, name)"
)

with open("core/GUI.lua", "w") as f:
    f.write(content)
