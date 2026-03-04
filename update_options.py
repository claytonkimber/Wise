import re

with open("modules/Options.lua", "r") as f:
    text = f.read()

def inject_lock_button(match):
    return match.group(0) + """
            -- Lock Button
            btn.lockBtn = CreateFrame("Button", nil, btn)
            btn.lockBtn:SetSize(14, 14)
            btn.lockBtn:SetPoint("RIGHT", btn, "RIGHT", -5, 0)

            btn.lockBtn.icon = btn.lockBtn:CreateTexture(nil, "ARTWORK")
            btn.lockBtn.icon:SetAllPoints()
            btn.lockBtn.icon:SetTexture("Interface\\\\PetBattles\\\\PetBattle-LockIcon")

            btn.lockBtn:SetScript("OnClick", function(self)
                local name = self:GetParent().groupName
                local data = WiseDB.groups[name]
                if data then
                    data.isLocked = not data.isLocked
                    Wise:UpdateOptionsUI()
                end
            end)
"""

text = re.sub(r'btn\.kbLabel:SetTextColor\(1, 1, 1, 1\) -- White', inject_lock_button, text)

with open("modules/Options.lua", "w") as f:
    f.write(text)
