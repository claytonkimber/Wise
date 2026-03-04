with open("modules/Properties.lua", "r") as f:
    text = f.read()

def insert_lock_check(match):
    return """
    local group = Wise.selectedGroup and WiseDB.groups[Wise.selectedGroup]

    if group and group.isLocked then
        Wise.OptionsFrame.Right.Title:SetText("Interface Locked")
        local lockedLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lockedLabel:SetPoint("TOPLEFT", 10, -30)
        lockedLabel:SetWidth(200)
        lockedLabel:SetJustifyH("LEFT")
        lockedLabel:SetText("This interface is locked. Click the lock icon in the sidebar to unlock it.")
        tinsert(panel.controls, lockedLabel)
        return
    end
""" + match.group(0)

import re
text = re.sub(r"    local group = Wise.selectedGroup and WiseDB.groups\[Wise.selectedGroup\]\n\n    -- Check Validation\n", insert_lock_check, text)

with open("modules/Properties.lua", "w") as f:
    f.write(text)
