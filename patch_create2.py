import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

# Fix naming of the toggleBtn inside CreateGroupFrame
# local toggleBtn = CreateFrame("Button", "WiseGroupToggle_"..name, UIParent, ...)
# Should be "WiseGroupToggle_" .. (instanceId and instanceId:gsub("[: ]", "_") or name)

old_toggle = 'local toggleBtn = CreateFrame("Button", "WiseGroupToggle_"..name, UIParent, "SecureActionButtonTemplate, SecureHandlerAttributeTemplate")'
new_toggle = 'local toggleBtn = CreateFrame("Button", "WiseGroupToggle_"..(instanceId and instanceId:gsub("[: ]", "_") or name), UIParent, "SecureActionButtonTemplate, SecureHandlerAttributeTemplate")'

content = content.replace(old_toggle, new_toggle)

# Fix groupName in GUI.lua UpdateGroupDisplay
# Wise:UpdateGroupDisplay(name, instanceId, overrideOpts)
#   local frameKey = instanceId or name
#   local f = Wise:CreateGroupFrame(name, instanceId)
# And make sure group metadata is stored with frameKey

old_update_create = "local f = Wise:CreateGroupFrame(name)"
new_update_create = "local f = Wise:CreateGroupFrame(name, instanceId)"
content = content.replace(old_update_create, new_update_create)

# In UpdateGroupDisplay, we also have:
# f.groupName = name
# Let's keep it as name so we can reference WiseDB.groups[f.groupName]

# Around line 2500 we find:
#             local childGroup = WiseDB and WiseDB.groups and WiseDB.groups[aValue]
#             if childGroup then
#                 -- Ensure child frame exists (CreateGroupFrame is idempotent)
#                 local childFrame = Wise:CreateGroupFrame(aValue)
#                 if childFrame then
#                     f.toggleBtn:SetFrameRef("nested_" .. aValue, childFrame)
#                 end
#             end
#
# We need to change this to:
#             local childGroup = WiseDB and WiseDB.groups and WiseDB.groups[aValue]
#             if childGroup then
#                 local childInstanceId = name .. "_" .. tostring(i) .. "_" .. aValue
#                 btn:SetAttribute("isa_interface_target", childInstanceId)
#                 local childFrame = Wise:CreateGroupFrame(aValue, childInstanceId)
#                 if childFrame then
#                     f.toggleBtn:SetFrameRef("nested_" .. childInstanceId, childFrame)
#                 end
#                 -- We must recursively update the child display so its buttons are generated
#                 Wise:UpdateGroupDisplay(aValue, childInstanceId, nestOpts)
#             end

old_child_setup = """            local childGroup = WiseDB and WiseDB.groups and WiseDB.groups[aValue]
            if childGroup then
                -- Ensure child frame exists (CreateGroupFrame is idempotent)
                local childFrame = Wise:CreateGroupFrame(aValue)
                if childFrame then
                    f.toggleBtn:SetFrameRef("nested_" .. aValue, childFrame)
                end
            end"""

new_child_setup = """            local childGroup = WiseDB and WiseDB.groups and WiseDB.groups[aValue]
            if childGroup then
                local frameKey = instanceId or name
                local childInstanceId = frameKey .. "_" .. tostring(i) .. "_" .. aValue
                btn:SetAttribute("isa_interface_target", childInstanceId)
                local childFrame = Wise:CreateGroupFrame(aValue, childInstanceId)
                if childFrame then
                    f.toggleBtn:SetFrameRef("nested_" .. childInstanceId, childFrame)
                end

                -- Recursive update to prepare child layout with overrides
                Wise:UpdateGroupDisplay(aValue, childInstanceId, nestOpts)
            end"""

content = content.replace(old_child_setup, new_child_setup)

with open("core/GUI.lua", "w") as f:
    f.write(content)
