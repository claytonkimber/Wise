import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

# We need to set up "openOnHover" on buttons that are interfaces
# First, look around line 2500 where nesting attributes are set

#         -- Mark interface buttons with nesting attributes
#         if aType == "interface" then
#             btn:SetAttribute("isa_is_interface", true)
#             btn:SetAttribute("isa_interface_target", aValue)
#             local nestOpts = Wise:GetNestingOptions(actionData)
#             if nestOpts then
#                 btn:SetAttribute("isa_open_button", nestOpts.openNestedButton or "BUTTON1")
#                 btn:SetAttribute("isa_open_direction", nestOpts.openDirection or "auto")
#                 btn:SetAttribute("isa_open_on_hover", nestOpts.openOnHover or false)

new_attr_code = """
            local nestOpts = Wise:GetNestingOptions(actionData)
            if nestOpts then
                btn:SetAttribute("isa_open_button", nestOpts.openNestedButton or "BUTTON1")
                btn:SetAttribute("isa_open_direction", nestOpts.openDirection or "auto")

                if nestOpts.openOnHover then
                    -- If open on hover is enabled, hook OnEnter (or add secure snippet)
                    if not btn.isaHoverWrapped then
                        btn.isaHoverWrapped = true
                        btn:SetScript("OnEnter", function(self)
                            -- Call original logic if needed
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
                else
                    if btn.isaHoverWrapped then
                        btn:SetScript("OnEnter", nil)
                        btn.isaHoverWrapped = false
                    end
                end
            end
"""

# replace the block
# Find:
#            local nestOpts = Wise:GetNestingOptions(actionData)
#            if nestOpts then
#                btn:SetAttribute("isa_open_button", nestOpts.openNestedButton or "BUTTON1")
#                btn:SetAttribute("isa_open_direction", nestOpts.openDirection or "auto")
#            end

old_attr_block = """            local nestOpts = Wise:GetNestingOptions(actionData)
            if nestOpts then
                btn:SetAttribute("isa_open_button", nestOpts.openNestedButton or "BUTTON1")
                btn:SetAttribute("isa_open_direction", nestOpts.openDirection or "auto")
            end"""

if old_attr_block in content:
    content = content.replace(old_attr_block, new_attr_code)
    with open("core/GUI.lua", "w") as f:
        f.write(content)
else:
    print("Could not find old_attr_block")
