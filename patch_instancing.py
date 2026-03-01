import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

# We need to change UpdateGroupDisplay signature:
# function Wise:UpdateGroupDisplay(name) -> function Wise:UpdateGroupDisplay(name, instanceId, overrideOpts)

content = content.replace("function Wise:UpdateGroupDisplay(name)", "function Wise:UpdateGroupDisplay(name, instanceId, overrideOpts)")

# Inside UpdateGroupDisplay:
#    local frameKey = instanceId or name
# Replace instances of Wise.frames[name] and CreateGroupFrame(name) inside this function
# BUT only for the current frame being built.

with open("core/GUI.lua", "w") as f:
    f.write(content)

print("Function signature changed")
