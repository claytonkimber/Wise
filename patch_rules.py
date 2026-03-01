import re

with open("modules/Nesting.lua", "r") as f:
    content = f.read()

# Add list_list to NESTING_LAYOUT_RULES
rule_addition = """
NESTING_LAYOUT_RULES["list_list"] = function(parentGroup, childGroup)
    return true
end
"""

# Find Box -> Box rule and insert after it
insert_point = content.find("NESTING_LAYOUT_RULES[\"box_box\"]")
end_of_box_rule = content.find("end", insert_point) + 4

if insert_point != -1:
    content = content[:end_of_box_rule] + "\n-- List -> List: allowed\n" + rule_addition + "\n" + content[end_of_box_rule:]

# Update the IsNestingAllowed logic to accept anything overridden maybe?
# The task requires "in this way we can at the nesting.lua level, control what is allowed and what isn't"
# We also need to let Lists nest within Lists.

with open("modules/Nesting.lua", "w") as f:
    f.write(content)
