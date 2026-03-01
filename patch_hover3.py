import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

# Replace the OnEnter hook with a secure snippet `_onenter`
# If we want it to work in combat, we must use SecureHandlerEnterLeaveTemplate on the button
# OR just add the attribute `_onenter` if the button already inherits it.
# The button inherits "SecureActionButtonTemplate, SecureHandlerAttributeTemplate, SecureHandlerEnterLeaveTemplate"?
# Let's check CreateGroupFrame buttons.
