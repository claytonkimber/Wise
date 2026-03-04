import re

with open("modules/DragAndDrop.lua", "r") as f:
    content = f.read()

# Change Wise:OnDragReceive signature to include isAppend
content = re.sub(
    r'function Wise:OnDragReceive\(groupName, slotIndex\)',
    r'function Wise:OnDragReceive(groupName, slotIndex, isAppend)',
    content
)

# Function to replace calls inside OnDragReceive
def replace_calls(match):
    return match.group(0).replace('Wise:ReplaceSlotAction', 'if isAppend then Wise:AddAction(groupName, slotIndex, "spell", finalSpellID, category, extra) else Wise:ReplaceSlotAction(groupName, slotIndex, "spell", finalSpellID, category, extra) end')

content = re.sub(
    r'Wise:ReplaceSlotAction\(groupName, slotIndex, "spell", finalSpellID, category, extra\)',
    r'if isAppend then Wise:AddAction(groupName, slotIndex, "spell", finalSpellID, category, extra) Wise:UpdateGroupDisplay(groupName) Wise:UpdateOptionsUI() else Wise:ReplaceSlotAction(groupName, slotIndex, "spell", finalSpellID, category, extra) end',
    content
)

content = re.sub(
    r'Wise:ReplaceSlotAction\(groupName, slotIndex, "item", id\)',
    r'if isAppend then Wise:AddAction(groupName, slotIndex, "item", id) Wise:UpdateGroupDisplay(groupName) Wise:UpdateOptionsUI() else Wise:ReplaceSlotAction(groupName, slotIndex, "item", id) end',
    content
)

content = re.sub(
    r'Wise:ReplaceSlotAction\(groupName, slotIndex, "macro", name\)',
    r'if isAppend then Wise:AddAction(groupName, slotIndex, "macro", name) Wise:UpdateGroupDisplay(groupName) Wise:UpdateOptionsUI() else Wise:ReplaceSlotAction(groupName, slotIndex, "macro", name) end',
    content
)

content = re.sub(
    r'Wise:ReplaceSlotAction\(groupName, slotIndex, "mount", id\)',
    r'if isAppend then Wise:AddAction(groupName, slotIndex, "mount", id) Wise:UpdateGroupDisplay(groupName) Wise:UpdateOptionsUI() else Wise:ReplaceSlotAction(groupName, slotIndex, "mount", id) end',
    content
)

content = re.sub(
    r'Wise:ReplaceSlotAction\(groupName, slotIndex, "battlepet", id\)',
    r'if isAppend then Wise:AddAction(groupName, slotIndex, "battlepet", id) Wise:UpdateGroupDisplay(groupName) Wise:UpdateOptionsUI() else Wise:ReplaceSlotAction(groupName, slotIndex, "battlepet", id) end',
    content
)

content = re.sub(
    r'Wise:ReplaceSlotAction\(groupName, slotIndex, "equipmentset", name\)',
    r'if isAppend then Wise:AddAction(groupName, slotIndex, "equipmentset", name) Wise:UpdateGroupDisplay(groupName) Wise:UpdateOptionsUI() else Wise:ReplaceSlotAction(groupName, slotIndex, "equipmentset", name) end',
    content
)

with open("modules/DragAndDrop.lua", "w") as f:
    f.write(content)
