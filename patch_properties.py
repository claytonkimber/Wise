import re

with open("modules/Properties.lua", "r") as f:
    content = f.read()

# We need to insert the "Interface Mode" option in RenderActionProperties
# The code around line 721 looks like:
#         local nestOpts = Wise:GetNestingOptions(action) or {}
#
#         -- Open Button radios

new_code = """        local nestOpts = Wise:GetNestingOptions(action) or {}

        -- Nested Interface Mode radios
        local typeLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        typeLabel:SetPoint("TOPLEFT", 10, y)
        typeLabel:SetText("Nested Interface Mode:")
        tinsert(panel.controls, typeLabel)
        y = y - 20
        local modeTypes = {
            { value = "default", label = "Default (No Override)" },
            { value = "circle", label = "Circle" },
            { value = "button", label = "Button" },
            { value = "box",    label = "Box" },
            { value = "line",   label = "Line" },
            { value = "list",   label = "List" },
        }
        for _, modeInfo in ipairs(modeTypes) do
            local radio = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
            radio:SetPoint("TOPLEFT", 10, y)
            radio:SetChecked(nestOpts.nestedInterfaceType == modeInfo.value)
            radio.text = radio:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            radio.text:SetPoint("LEFT", radio, "RIGHT", 5, 0)
            radio.text:SetText(modeInfo.label)
            radio:SetScript("OnClick", function()
                Wise:SetNestingOption(action, "nestedInterfaceType", modeInfo.value)
                Wise:RefreshPropertiesPanel()
                C_Timer.After(0, function()
                    if not InCombatLockdown() then
                        Wise:UpdateGroupDisplay(Wise.selectedGroup)
                    end
                end)
            end)
            tinsert(panel.controls, radio)
            tinsert(panel.controls, radio.text)
            y = y - 22
        end
        y = y - 8

"""

content = content.replace("        local nestOpts = Wise:GetNestingOptions(action) or {}\n", new_code)

with open("modules/Properties.lua", "w") as f:
    f.write(content)
