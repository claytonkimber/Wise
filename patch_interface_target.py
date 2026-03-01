import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

# I see a bug where `btn:SetAttribute("isa_interface_target", aValue)` is called before the dynamic `childInstanceId` is generated,
# and then it gets overwritten inside `if childGroup then`.
# If `childGroup` is not found, it keeps `aValue`, which is fine, but when setting `target` for `openOnHover`
# it might capture `aValue` instead of `childInstanceId`!
# Let's fix this so `childInstanceId` is generated first and used consistently.

# Find the block:
old_target = """        -- Mark interface buttons with nesting attributes
        if aType == "interface" then
            btn:SetAttribute("isa_is_interface", true)
            btn:SetAttribute("isa_interface_target", aValue)


            local nestOpts = Wise:GetNestingOptions(actionData)"""

new_target = """        -- Mark interface buttons with nesting attributes
        if aType == "interface" then
            local frameKey = instanceId or name
            local childInstanceId = frameKey .. "_" .. tostring(i) .. "_" .. aValue
            btn:SetAttribute("isa_is_interface", true)
            btn:SetAttribute("isa_interface_target", childInstanceId)

            local nestOpts = Wise:GetNestingOptions(actionData)"""

content = content.replace(old_target, new_target)

# Then we must fix the `childGroup` block to just use `childInstanceId`
old_childGroup = """            local childGroup = WiseDB and WiseDB.groups and WiseDB.groups[aValue]
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

new_childGroup = """            local childGroup = WiseDB and WiseDB.groups and WiseDB.groups[aValue]
            if childGroup then
                local childFrame = Wise:CreateGroupFrame(aValue, childInstanceId)
                if childFrame then
                    f.toggleBtn:SetFrameRef("nested_" .. childInstanceId, childFrame)
                end

                -- Recursive update to prepare child layout with overrides
                Wise:UpdateGroupDisplay(aValue, childInstanceId, nestOpts)
            end"""

content = content.replace(old_childGroup, new_childGroup)


# We also need to fix `Wise:PositionNestedChild(self, self.groupName, parentName)`
# Wait, `self.groupName` in `PositionNestedChild` is currently just the global name of the child.
# But now the child frame's name is `childInstanceId`. Let's check `groupName` setting in `CreateGroupFrame`.
# Actually, `f.groupName = name` is still the global name in UpdateGroupDisplay.
# So `self.groupName` inside the child frame is the global name, not the instance ID.
# BUT wait! The secure snippet does:
# `_childGroup:SetAttribute("state-manual", _cTarget)`
# The state driver listens to `state-manual` and toggles `f:Show()`.
# When the child frame is shown, `f:SetScript("OnShow", ...)` runs.
# Inside OnShow:
#   local parentName, parentGroup = Wise:GetParentInfo(self.groupName)
# THIS is problematic! GetParentInfo scans the DB and returns the FIRST parent it finds, which may not be the one that just opened it.
# We no longer need GetParentInfo to position the child if we pass the correct parent context, or we can look up the parent frame using `self:GetParent()`? No, it's anchored.
# How do we know the parentName in `OnShow`? We should store it on the child instance!
# Inside UpdateGroupDisplay recursive call:
# `Wise:UpdateGroupDisplay(aValue, childInstanceId, nestOpts)` we can store `f.parentInstanceId = frameKey`

# Let's add that to UpdateGroupDisplay:
# f.parentInstanceId = instanceId or name
# f.instanceId = instanceId or name

with open("core/GUI.lua", "w") as f:
    f.write(content)

print("Interface target fixed")
