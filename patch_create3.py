import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

# Wait, the previous layout fix checked GetParentInfo which parses ALL groups to find parents.
# Since we are passing overrideOpts directly in the recursive call, we don't need the GetParentInfo lookup!
# Find the new_layout_code I inserted earlier and change it.

old_layout_code = """    local displayType = group.type or "circle"
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
    end"""

new_layout_code = """    local displayType = group.type or "circle"
    if overrideOpts and overrideOpts.nestedInterfaceType and overrideOpts.nestedInterfaceType ~= "default" then
        displayType = overrideOpts.nestedInterfaceType
    end"""

content = content.replace(old_layout_code, new_layout_code)

with open("core/GUI.lua", "w") as f:
    f.write(content)
