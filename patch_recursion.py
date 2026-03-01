import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

# Find the recursive call:
#                -- Recursive update to prepare child layout with overrides
#                if not nestOpts then nestOpts = {} end
#                nestOpts._parentInstanceId = frameKey
#                Wise:UpdateGroupDisplay(aValue, childInstanceId, nestOpts)

# Replace with logic that enforces max depth
old_code = """                -- Recursive update to prepare child layout with overrides
                if not nestOpts then nestOpts = {} end
                nestOpts._parentInstanceId = frameKey
                Wise:UpdateGroupDisplay(aValue, childInstanceId, nestOpts)"""

new_code = """                -- Recursive update to prepare child layout with overrides
                if not nestOpts then nestOpts = {} end
                nestOpts._parentInstanceId = frameKey

                local currentDepth = (overrideOpts and overrideOpts._depth) or 0
                if currentDepth < 5 then
                    nestOpts._depth = currentDepth + 1
                    Wise:UpdateGroupDisplay(aValue, childInstanceId, nestOpts)
                else
                    Wise:DebugPrint("Max nesting depth reached, aborting recursive instantiation for " .. aValue)
                end"""

content = content.replace(old_code, new_code)

with open("core/GUI.lua", "w") as f:
    f.write(content)
