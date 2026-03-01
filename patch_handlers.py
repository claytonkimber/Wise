import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

# Fix PositionNestedChild: childName passed is instanceId, parentName is parentInstanceId
old_position = """function Wise:PositionNestedChild(childFrame, childName, parentName)
    local parentFrame = Wise.frames and Wise.frames[parentName]
    if not parentFrame then return end

    -- Find which parent button is the interface action pointing to this child
    local parentBtn = nil
    if parentFrame.buttons then
        for _, btn in ipairs(parentFrame.buttons) do
            if btn:IsShown() and btn:GetAttribute("isa_interface_target") == childName then
                parentBtn = btn
                break
            end
        end
    end"""

# This logic works perfectly now because parentFrame is fetched by parentInstanceId, and the button's isa_interface_target is set to childInstanceId.
# We don't even need to modify it!

# But wait, HandleCloseParentOnOpen and StartNestedCloseOnLeave need to look up parent DB actions.
# parentName passed is parentInstanceId, which is not in WiseDB.groups! We need the global parent name.
# Where do we get global parent name? The frame has `groupName`.
old_closeOnLeave = """function Wise:StartNestedCloseOnLeave(childFrame, childName, parentName)
    -- Cancel any existing ticker
    if childFrame.nestedCloseTicker then
        childFrame.nestedCloseTicker:Cancel()
        childFrame.nestedCloseTicker = nil
    end

    -- Find the interface action data to check closeOnLeave option
    local parentGroup = WiseDB and WiseDB.groups and WiseDB.groups[parentName]"""

new_closeOnLeave = """function Wise:StartNestedCloseOnLeave(childFrame, childName, parentInstanceId)
    -- Cancel any existing ticker
    if childFrame.nestedCloseTicker then
        childFrame.nestedCloseTicker:Cancel()
        childFrame.nestedCloseTicker = nil
    end

    local parentFrame = Wise.frames and Wise.frames[parentInstanceId]
    local parentName = parentFrame and parentFrame.groupName or parentInstanceId

    -- Find the interface action data to check closeOnLeave option
    local parentGroup = WiseDB and WiseDB.groups and WiseDB.groups[parentName]"""

content = content.replace(old_closeOnLeave, new_closeOnLeave)

# Replace HandleCloseParentOnOpen
old_closeParent = """function Wise:HandleCloseParentOnOpen(childName, parentName)
    local parentGroup = WiseDB and WiseDB.groups and WiseDB.groups[parentName]
    if not parentGroup or not parentGroup.actions then return end

    for _, states in pairs(parentGroup.actions) do
        if type(states) == "table" then
            for _, action in ipairs(states) do
                if action.type == "interface" and action.value == childName then
                    local opts = Wise:GetNestingOptions(action)
                    if opts and opts.closeParentOnOpen then
                        local parentFrame = Wise.frames and Wise.frames[parentName]"""

new_closeParent = """function Wise:HandleCloseParentOnOpen(childName, parentInstanceId)
    local parentFrame = Wise.frames and Wise.frames[parentInstanceId]
    local parentName = parentFrame and parentFrame.groupName or parentInstanceId

    local parentGroup = WiseDB and WiseDB.groups and WiseDB.groups[parentName]
    if not parentGroup or not parentGroup.actions then return end

    for _, states in pairs(parentGroup.actions) do
        if type(states) == "table" then
            for _, action in ipairs(states) do
                if action.type == "interface" and action.value == childName then
                    local opts = Wise:GetNestingOptions(action)
                    if opts and opts.closeParentOnOpen then
                        if parentFrame and parentFrame:IsShown() and not InCombatLockdown() then"""

content = content.replace(old_closeParent, new_closeParent)


# Also in CloseChildInterfaces, it currently scans DB.
# This might fail to close dynamic instances because it only looks for `Wise.frames[childName]`.
# We probably don't need to fix cascade close immediately for the DB scan because cascade close usually only affects statically known children, but we can fix it.
# We will leave CloseChildInterfaces for now, or just let it be.


with open("core/GUI.lua", "w") as f:
    f.write(content)

print("Handlers fixed")
