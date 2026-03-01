import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

old_code = 'driver:RunAttribute("SetState", target, "active")'
new_code = 'driver:SetAttribute("wisesetstate", target .. ":active")'

content = content.replace(old_code, new_code)

with open("core/GUI.lua", "w") as f:
    f.write(content)
