import re

with open("modules/Properties.lua", "r") as f:
    text = f.read()

# I need to block changes to properties if it is locked
# and in modules/Actions.lua block adding/removing slots
