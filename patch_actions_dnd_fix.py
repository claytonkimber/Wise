import re

with open("modules/Actions.lua", "r") as f:
    content = f.read()

# Fix the regex mess-up
old_code = '''        slotFrame.AddStateBtn:SetScript("OnClick", function(self)
             local capturedSlotID = self.slotID
             local cursorType = GetCursorInfo()
             if cursorType then
                 Wise:OnDragReceive(groupName, capturedSlotID, true)
             else
                 Wise.pickingAction = true
             Wise.PickerCallback = function(type, value, extra)
                 -- Pass nil for category so Wise:AddAction resolves it from extra (or defaults to global)
                 Wise:AddAction(groupName, capturedSlotID, type, value, nil, extra)
                 Wise:RefreshActionsView(container)
                 Wise:RefreshPropertiesPanel()
                 C_Timer.After(0, function()
                    if not InCombatLockdown() then Wise:UpdateGroupDisplay(Wise.selectedGroup) end
             end
        end)
        slotFrame.AddStateBtn:SetScript("OnReceiveDrag", function(self)
             local capturedSlotID = self.slotID
             Wise:OnDragReceive(groupName, capturedSlotID, true)
        end)
             end
             Wise.PickerCurrentCategory = "Spell"
             Wise:RefreshPropertiesPanel()
        end)'''

new_code = '''        slotFrame.AddStateBtn:SetScript("OnClick", function(self)
             local capturedSlotID = self.slotID
             local type = GetCursorInfo()
             if type then
                 Wise:OnDragReceive(groupName, capturedSlotID, true)
             else
                 Wise.pickingAction = true
                 Wise.PickerCallback = function(type, value, extra)
                     -- Pass nil for category so Wise:AddAction resolves it from extra (or defaults to global)
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
        end)
        slotFrame.AddStateBtn:SetScript("OnReceiveDrag", function(self)
             local capturedSlotID = self.slotID
             Wise:OnDragReceive(groupName, capturedSlotID, true)
        end)'''

content = content.replace(old_code, new_code)

with open("modules/Actions.lua", "w") as f:
    f.write(content)
