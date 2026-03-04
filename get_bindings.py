import re

with open("core/Bindings.lua", "r") as f:
    text = f.read()

if "SetBinding" in text:
    print("SetBinding found in core/Bindings.lua")
