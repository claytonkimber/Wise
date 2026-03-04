import re

with open("modules/Options.lua", "r") as f:
    text = f.read()

# look for btn.kbLabel = btn:CreateFontString
for i, line in enumerate(text.split("\n")):
    if "btn.kbLabel = " in line:
        print(f"Line {i+1}: {line}")
