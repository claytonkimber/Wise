import re

with open("modules/DragAndDrop.lua", "r") as f:
    content = f.read()

# I already modified Wise:OnDragReceive earlier but let's just make sure it's correct.
print(content[:1500])
