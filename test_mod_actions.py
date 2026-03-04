import re

with open("modules/Actions.lua", "r") as f:
    text = f.read()

text = text.replace('function Wise:AddAction(groupName, actionType, value, extra)',
                    '''function Wise:AddAction(groupName, actionType, value, extra)
    if WiseDB.groups[groupName] and WiseDB.groups[groupName].isLocked then return end''')

text = text.replace('function Wise:RemoveActionFromSlot(groupName, slotIndex, stateIndex)',
                    '''function Wise:RemoveActionFromSlot(groupName, slotIndex, stateIndex)
    if WiseDB.groups[groupName] and WiseDB.groups[groupName].isLocked then return end''')

text = text.replace('function Wise:ReplaceSlotAction(groupName, slotIndex, type, value, category, extra)',
                    '''function Wise:ReplaceSlotAction(groupName, slotIndex, type, value, category, extra)
    if WiseDB.groups[groupName] and WiseDB.groups[groupName].isLocked then return end''')

with open("modules/Actions.lua", "w") as f:
    f.write(text)
