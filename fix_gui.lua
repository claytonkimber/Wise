local function fix()
    local f = io.open("core/GUI.lua", "r")
    local lines = {}
    for l in f:lines() do
        table.insert(lines, l)
    end
    f:close()

    local out = io.open("core/GUI.lua", "w")
    for i, line in ipairs(lines) do
        if line == "    elseif aValue:match(\"^spec_\") then" then
            out:write("    elseif aType == \"addonvisibility\" then\n")
            out:write("        -- Addon visibility handled by UpdateAddonVisibility\n")
            out:write(line .. "\n")
        elseif line == "function Wise:UpdateGroupDisplay(name, instanceId, overrideOpts)" then
            out:write("function Wise:UpdateAddonVisibility()\n")
            out:write("    if not WiseDB or not WiseDB.groups then return end\n")
            out:write("    local addonsGroup = WiseDB.groups[\"Addon visibility\"]\n")
            out:write("    if not addonsGroup then return end\n")
            out:write("    local parts = {}\n")
            out:write("    if addonsGroup.visibilitySettings.customShow and addonsGroup.visibilitySettings.customShow ~= \"\" then\n")
            out:write("        table.insert(parts, addonsGroup.visibilitySettings.customShow .. \" show\")\n")
            out:write("    end\n")
            out:write("    if addonsGroup.visibilitySettings.customHide and addonsGroup.visibilitySettings.customHide ~= \"\" then\n")
            out:write("        table.insert(parts, addonsGroup.visibilitySettings.customHide .. \" hide\")\n")
            out:write("    end\n")
            out:write("    table.insert(parts, \"show\")\n")
            out:write("    local driverString = table.concat(parts, \"; \")\n")
            out:write("    for _, action in ipairs(addonsGroup.buttons or {}) do\n")
            out:write("        if action.type == \"addonvisibility\" and action.addonFrame and action.addonFrame ~= \"\" then\n")
            out:write("            local frame = _G[action.addonFrame]\n")
            out:write("            if frame then\n")
            out:write("                RegisterStateDriver(frame, \"visibility\", driverString)\n")
            out:write("            end\n")
            out:write("        end\n")
            out:write("    end\n")
            out:write("end\n\n")
            out:write(line .. "\n")
        elseif line == "    -- Ensure defaults" and lines[i-1] == "    " then
            out:write("    if name == \"Addon visibility\" then\n")
            out:write("        Wise:UpdateAddonVisibility()\n")
            out:write("    end\n\n")
            out:write(line .. "\n")
        else
            out:write(line .. "\n")
        end
    end
    out:close()
end
fix()
