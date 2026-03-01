import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

old_close = """                        if parentFrame and parentFrame:IsShown() and not InCombatLockdown() then
                        if parentFrame and parentFrame:IsShown() and not InCombatLockdown() then
                            parentFrame:SetAttribute("state-manual", "hide")
                        end"""

new_close = """                        if parentFrame and parentFrame:IsShown() and not InCombatLockdown() then
                            parentFrame:SetAttribute("state-manual", "hide")
                        end"""

content = content.replace(old_close, new_close)

with open("core/GUI.lua", "w") as f:
    f.write(content)
