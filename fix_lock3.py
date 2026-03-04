import re
with open("modules/Options.lua", "r") as f:
    text = f.read()

# Fix drag drop
text = text.replace('Wise:ReplaceSlotAction(groupName, slotIndex, "spell", finalSpellID, category, extra)',
                    'if not WiseDB.groups[groupName].isLocked then Wise:ReplaceSlotAction(groupName, slotIndex, "spell", finalSpellID, category, extra) end')
text = text.replace('Wise:ReplaceSlotAction(groupName, slotIndex, "item", id)',
                    'if not WiseDB.groups[groupName].isLocked then Wise:ReplaceSlotAction(groupName, slotIndex, "item", id) end')
text = text.replace('Wise:ReplaceSlotAction(groupName, slotIndex, "macro", name)',
                    'if not WiseDB.groups[groupName].isLocked then Wise:ReplaceSlotAction(groupName, slotIndex, "macro", name) end')
text = text.replace('Wise:ReplaceSlotAction(groupName, slotIndex, "mount", id)',
                    'if not WiseDB.groups[groupName].isLocked then Wise:ReplaceSlotAction(groupName, slotIndex, "mount", id) end')
text = text.replace('Wise:ReplaceSlotAction(groupName, slotIndex, "battlepet", id)',
                    'if not WiseDB.groups[groupName].isLocked then Wise:ReplaceSlotAction(groupName, slotIndex, "battlepet", id) end')
text = text.replace('Wise:ReplaceSlotAction(groupName, slotIndex, "equipmentset", name)',
                    'if not WiseDB.groups[groupName].isLocked then Wise:ReplaceSlotAction(groupName, slotIndex, "equipmentset", name) end')

with open("modules/Options.lua", "w") as f:
    f.write(text)
