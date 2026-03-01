import re

with open("modules/Properties.lua", "r") as f:
    content = f.read()

# We need to insert the "Open on hover" checkbox
# Since the checkboxes list is at the bottom of the nesting section:
#        local checkboxes = {
#            { key = "closeParentOnOpen",  label = "Close parent on open" },

new_code = """        local checkboxes = {
            { key = "openOnHover",        label = "Open on hover (instead of click)" },
            { key = "closeParentOnOpen",  label = "Close parent on open" },"""

content = content.replace('        local checkboxes = {\n            { key = "closeParentOnOpen",  label = "Close parent on open" },', new_code)

with open("modules/Properties.lua", "w") as f:
    f.write(content)
