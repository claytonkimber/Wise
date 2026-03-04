import re

with open("modules/Actions.lua", "r") as f:
    content = f.read()

# Replace OnDragReceive calls to pass False for regular slot frame drop and True for add state btn drop
content = re.sub(
    r'slotFrame:SetScript\("OnReceiveDrag", function\(self\)\s+Wise:OnDragReceive\(groupName, self.slotID\)\s+end\)',
    r'''slotFrame:SetScript("OnReceiveDrag", function(self)
            Wise:OnDragReceive(groupName, self.slotID, false)
        end)''',
    content
)

content = re.sub(
    r'Wise:OnDragReceive\(groupName, self.slotID\)',
    r'Wise:OnDragReceive(groupName, self.slotID, false)',
    content
)

# For slotFrame.AddStateBtn, we want to add OnReceiveDrag / OnMouseUp to append
# The addStateBtn OnClick is currently:
#         slotFrame.AddStateBtn:SetScript("OnClick", function(self)

add_state_btn_drag_logic = '''
        slotFrame.AddStateBtn:SetScript("OnReceiveDrag", function(self)
            Wise:OnDragReceive(groupName, capturedSlotID, true)
        end)
        slotFrame.AddStateBtn:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" then
                local type = GetCursorInfo()
                if type then
                    Wise:OnDragReceive(groupName, capturedSlotID, true)
                else
                    -- Original click logic
                    Wise.pickingAction = true
                    Wise.PickerCallback = function(type, value, extra)
                        Wise:AddAction(groupName, capturedSlotID, type, value, nil, extra)
                        Wise:RefreshActionsView(container)
                        Wise:RefreshPropertiesPanel()
                        C_Timer.After(0, function()
                           if not InCombatLockdown() then Wise:UpdateGroupDisplay(Wise.selectedGroup) end
                        end)
                    end
                    Wise.PickerCurrentCategory = "Spell"
                    Wise:RefreshPropertiesPanel()
                end
            end
        end)
'''

# Find the existing slotFrame.AddStateBtn:SetScript("OnClick"... block
# and replace it with OnMouseUp/OnReceiveDrag. But wait, OnClick is better for normal click, we can just add OnReceiveDrag and OnMouseUp for drop.
# Actually, the original is:
#         slotFrame.AddStateBtn:SetScript("OnClick", function(self)
#              local capturedSlotID = self.slotID
#              Wise.pickingAction = true
# ...

content = re.sub(
    r'slotFrame\.AddStateBtn:SetScript\("OnClick", function\(self\)\n\s+local capturedSlotID = self\.slotID\n\s+Wise\.pickingAction = true(.*?)\n\s+end\)',
    r'''slotFrame.AddStateBtn:SetScript("OnClick", function(self)
             local capturedSlotID = self.slotID
             local cursorType = GetCursorInfo()
             if cursorType then
                 Wise:OnDragReceive(groupName, capturedSlotID, true)
             else
                 Wise.pickingAction = true\1
             end
        end)
        slotFrame.AddStateBtn:SetScript("OnReceiveDrag", function(self)
             local capturedSlotID = self.slotID
             Wise:OnDragReceive(groupName, capturedSlotID, true)
        end)''',
    content,
    flags=re.DOTALL
)

with open("modules/Actions.lua", "w") as f:
    f.write(content)
