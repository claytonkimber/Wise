import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

content = content.replace("Wise.frames[name] = f", "Wise.frames[frameKey] = f")

with open("core/GUI.lua", "w") as f:
    f.write(content)
