import re

with open("modules/Options.lua", "r") as f:
    text = f.read()

# check if the lock script was injected
print("isLocked" in text)
