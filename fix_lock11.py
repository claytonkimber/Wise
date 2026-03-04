import re

with open("modules/Options.lua", "r") as f:
    text = f.read()

text = text.replace('btn.kbLabel:SetPoint("RIGHT", btn, "RIGHT", -25, 0)', 'btn.kbLabel:SetPoint("RIGHT", btn.icon, "LEFT", -5, 0)')

with open("modules/Options.lua", "w") as f:
    f.write(text)
