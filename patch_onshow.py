import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

# Add f.parentInstanceId and f.instanceId assignments
old_groupName = """    f.groupName = name
    f.visualDisplay.groupName = name"""

new_groupName = """    f.groupName = name
    f.visualDisplay.groupName = name
    f.instanceId = instanceId or name

    if overrideOpts and overrideOpts._parentInstanceId then
        f.parentInstanceId = overrideOpts._parentInstanceId
    end"""

content = content.replace(old_groupName, new_groupName)

# When calling recursive UpdateGroupDisplay, pass parentInstanceId
old_recursive = """                -- Recursive update to prepare child layout with overrides
                Wise:UpdateGroupDisplay(aValue, childInstanceId, nestOpts)"""

new_recursive = """                -- Recursive update to prepare child layout with overrides
                if not nestOpts then nestOpts = {} end
                nestOpts._parentInstanceId = frameKey
                Wise:UpdateGroupDisplay(aValue, childInstanceId, nestOpts)"""

content = content.replace(old_recursive, new_recursive)

# Fix OnShow referencing GetParentInfo
old_onshow_parent = """        if group and group.anchorMode ~= "mouse" and not group.isWiser then
            local parentName, parentGroup = Wise:GetParentInfo(self.groupName)
            if parentName and parentGroup then
                Wise:PositionNestedChild(self, self.groupName, parentName)

                -- closeParentOnOpen: hide parent when child opens
                if not InCombatLockdown() then
                    Wise:HandleCloseParentOnOpen(self.groupName, parentName)
                end

                -- Auto-close on leave: start monitoring mouse proximity
                Wise:StartNestedCloseOnLeave(self, self.groupName, parentName)
            end
        end"""

# Since `self.parentInstanceId` is now available, we can just use that.
# Note: `HandleCloseParentOnOpen` and `StartNestedCloseOnLeave` might still read from WiseDB using the global name,
# so we pass global name for action lookups, but we must use `self.parentInstanceId` for the FRAME lookup.

new_onshow_parent = """        if group and group.anchorMode ~= "mouse" and not group.isWiser then
            if self.parentInstanceId then
                Wise:PositionNestedChild(self, self.instanceId, self.parentInstanceId)

                -- closeParentOnOpen: hide parent when child opens
                if not InCombatLockdown() then
                    Wise:HandleCloseParentOnOpen(self.groupName, self.parentInstanceId)
                end

                -- Auto-close on leave: start monitoring mouse proximity
                Wise:StartNestedCloseOnLeave(self, self.groupName, self.parentInstanceId)
            end
        end"""

content = content.replace(old_onshow_parent, new_onshow_parent)

with open("core/GUI.lua", "w") as f:
    f.write(content)

print("OnShow parent fixed")
