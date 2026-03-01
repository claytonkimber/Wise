import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

# Change CreateGroupFrame signature
new_create = """function Wise:CreateGroupFrame(name, instanceId)
    local frameKey = instanceId or name
    if Wise.frames[frameKey] then return Wise.frames[frameKey] end

    local uiName = "WiseGroup_" .. (instanceId and instanceId:gsub("[: ]", "_") or name)
    local f = CreateFrame("Frame", uiName, UIParent, "SecureHandlerStateTemplate, SecureHandlerShowHideTemplate")
    f:SetSize(50, 50)
    f:EnableMouse(false) -- Default to click-through (enabled only in Edit Mode)
"""

old_create = """function Wise:CreateGroupFrame(name)
    if Wise.frames[name] then return Wise.frames[name] end

    local f = CreateFrame("Frame", "WiseGroup_"..name, UIParent, "SecureHandlerStateTemplate, SecureHandlerShowHideTemplate")
    f:SetSize(50, 50)
    f:EnableMouse(false) -- Default to click-through (enabled only in Edit Mode)
"""

content = content.replace(old_create, new_create)

with open("core/GUI.lua", "w") as f:
    f.write(content)

print("CreateGroupFrame changed")
