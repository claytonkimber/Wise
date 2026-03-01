import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

# We need to make sure the tooltip logic isn't broken by replacing OnEnter.
# We should probably use `btn:HookScript("OnEnter", ...)` instead of `btn:SetScript("OnEnter", ...)`
# if there is already an OnEnter script on these buttons (which there usually is for tooltips).
# Let's fix that.

fixed_attr_code = """
            local nestOpts = Wise:GetNestingOptions(actionData)
            if nestOpts then
                btn:SetAttribute("isa_open_button", nestOpts.openNestedButton or "BUTTON1")
                btn:SetAttribute("isa_open_direction", nestOpts.openDirection or "auto")

                if nestOpts.openOnHover then
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
                end
            end
"""

start_marker = "local nestOpts = Wise:GetNestingOptions(actionData)"
end_marker = "-- Set frame ref from parent toggleBtn to child group frame"

start_idx = content.find(start_marker)
end_idx = content.find(end_marker)

if start_idx != -1 and end_idx != -1:
    content = content[:start_idx] + fixed_attr_code + "\n            " + content[end_idx:]

    with open("core/GUI.lua", "w") as f:
        f.write(content)
