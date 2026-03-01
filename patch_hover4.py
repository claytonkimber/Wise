import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

# Since the button only inherits "SecureActionButtonTemplate", it doesn't have SecureHandlerEnterLeaveTemplate.
# So `_onenter` won't run natively.
# We need to change button creation to inherit "SecureActionButtonTemplate, SecureHandlerEnterLeaveTemplate"

content = content.replace(
    'btn = CreateFrame("Button", "WiseGroup_"..name.."_Btn"..i, f, "SecureActionButtonTemplate")',
    'btn = CreateFrame("Button", "WiseGroup_"..name.."_Btn"..i, f, "SecureActionButtonTemplate, SecureHandlerEnterLeaveTemplate")'
)

# Now write the secure _onenter code
old_hover_code = """                if nestOpts.openOnHover then
                    -- If open on hover is enabled, hook OnEnter (or add secure snippet)
                    if not btn.isaHoverWrapped then
                        btn.isaHoverWrapped = true
                        btn:HookScript("OnEnter", function(self)
                            if not InCombatLockdown() then
                                local target = self:GetAttribute("isa_interface_target")
                                if target then
                                    local childGroup = Wise.frames[target]
                                    if childGroup then
                                        -- Manually toggle it show
                                        local _cManual = childGroup:GetAttribute("state-manual") or "hide"
                                        if _cManual == "hide" then
                                            childGroup:SetAttribute("state-manual", "show")
                                            local driver = Wise.WiseStateDriver
                                            if driver then
                                                driver:SetAttribute("wisesetstate", target .. ":active")
                                            end
                                        end
                                    end
                                end
                            end
                        end)
                    end
                end"""

# Since `self` is the button, it has frame refs. But does the button have a frameref to `nested_` child?
# Wait! In `UpdateGroupDisplay`, we set `f.toggleBtn:SetFrameRef("nested_" .. childInstanceId, childFrame)`
# NOT on the button itself!
# Let's also set it on the button so it can reach the child frame in `_onenter`.
# Or we can just set `_onenter` to do a run macro? No, we can just give the button the frameref.

new_hover_code = """                if nestOpts.openOnHover then
                    -- Open on hover via secure snippet
                    btn:SetAttribute("_onenter", [[
                        local target = self:GetAttribute("isa_interface_target")
                        if target then
                            local childGroup = self:GetFrameRef("child_group")
                            if childGroup then
                                local _cManual = childGroup:GetAttribute("state-manual") or "hide"
                                if _cManual == "hide" then
                                    childGroup:SetAttribute("state-manual", "show")
                                    local driver = self:GetFrameRef("WiseStateDriver")
                                    if driver then
                                        driver:RunAttribute("SetState", target, "active")
                                    end
                                end
                            end
                        end
                    ]])
                else
                    btn:SetAttribute("_onenter", nil)
                end"""

content = content.replace(old_hover_code, new_hover_code)


# We need to make sure the button gets `child_group` and `WiseStateDriver` framerefs
# Find the `childGroup` block and add `btn:SetFrameRef`

old_child_group = """            local childGroup = WiseDB and WiseDB.groups and WiseDB.groups[aValue]
            if childGroup then
                local childFrame = Wise:CreateGroupFrame(aValue, childInstanceId)
                if childFrame then
                    f.toggleBtn:SetFrameRef("nested_" .. childInstanceId, childFrame)
                end"""

new_child_group = """            local childGroup = WiseDB and WiseDB.groups and WiseDB.groups[aValue]
            if childGroup then
                local childFrame = Wise:CreateGroupFrame(aValue, childInstanceId)
                if childFrame then
                    f.toggleBtn:SetFrameRef("nested_" .. childInstanceId, childFrame)
                    btn:SetFrameRef("child_group", childFrame)
                    if Wise.WiseStateDriver then
                        btn:SetFrameRef("WiseStateDriver", Wise.WiseStateDriver)
                    end
                end"""

content = content.replace(old_child_group, new_child_group)

with open("core/GUI.lua", "w") as f:
    f.write(content)
