import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

content = content.replace("if currentDepth < 5 then", "if currentDepth < 3 then")

with open("core/GUI.lua", "w") as f:
    f.write(content)
