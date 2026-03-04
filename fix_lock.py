with open("modules/Options.lua", "r") as f:
    text = f.read()

# I also need to update the binding label to not overlap with the lock icon
# Change SetPoint for kbLabel
text = text.replace('btn.kbLabel:SetPoint("RIGHT", btn.icon, "LEFT", -5, 0)', 'btn.kbLabel:SetPoint("RIGHT", btn, "RIGHT", -25, 0)')

# and I need to set the lock icon desaturated or not based on state
# and I need to add self.groupName = name
def inject_lock_state(text):
    old = "btn.icon:SetTexture(iconTexture)"
    new = """btn.icon:SetTexture(iconTexture)
        btn.groupName = name
        if data.isLocked then
            btn.lockBtn.icon:SetDesaturated(false)
            btn.lockBtn.icon:SetAlpha(1.0)
            btn.lockBtn:Show()
        else
            btn.lockBtn.icon:SetDesaturated(true)
            btn.lockBtn.icon:SetAlpha(0.3)
            btn.lockBtn:Show()
        end
        btn.lockBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(data.isLocked and "Unlock Interface" or "Lock Interface", 1, 1, 1)
            GameTooltip:AddLine("Prevents all changes to this interface, including drag & drop and keybinds.", 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        btn.lockBtn:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
"""
    return text.replace(old, new)

text = inject_lock_state(text)

with open("modules/Options.lua", "w") as f:
    f.write(text)
