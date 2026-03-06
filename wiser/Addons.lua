local addonName, Wise = ...

local function EnsureWiserGroup(name, defaultType, defaults)
    local created = false
    if not WiseDB.groups[name] then
        Wise:CreateGroup(name, defaultType or "circle")
        WiseDB.groups[name].enabled = false -- Default to unchecked for Wiser interfaces
        created = true
    end
    local g = WiseDB.groups[name]

    if created and defaults then
        if type(defaults) == "function" then
            defaults(g)
        else
            for k,v in pairs(defaults) do g[k] = v end
        end
    end

    g.isWiser = true -- Mark as Wiser
    g.buttons = {} -- Clear for rebuild
    g.actions = nil -- Clear actions to force migration from new buttons list

    return g
end

function Wise:UpdateAddonsWiserInterface()
    if not WiseDB or not WiseDB.groups then return end

    -- Preserve user-configured addon frames before clearing
    local existingFrames = {}
    local existingGroup = WiseDB.groups["Addon visibility"]
    if existingGroup then
        -- Check buttons list (unmigrated)
        if existingGroup.buttons then
            for _, btn in ipairs(existingGroup.buttons) do
                if btn.type == "addonvisibility" and btn.addonFrame then
                    existingFrames[btn.value] = btn.addonFrame
                end
            end
        end
        -- Check actions list (migrated)
        if existingGroup.actions then
            for _, slotActions in pairs(existingGroup.actions) do
                for _, action in ipairs(slotActions) do
                    if action.type == "addonvisibility" and action.addonFrame then
                        existingFrames[action.value] = action.addonFrame
                    end
                end
            end
        end
    end

    local addonsGroup = EnsureWiserGroup("Addon visibility", "circle")

    -- Check known addons and interfaces
    local numAddons = C_AddOns.GetNumAddOns()
    for i = 1, numAddons do
        local name, title, notes, loadable, reason, security, newVersion = C_AddOns.GetAddOnInfo(i)
        if C_AddOns.IsAddOnLoaded(i) and name ~= addonName then
            table.insert(addonsGroup.buttons, {
                type = "addonvisibility",
                value = name,
                name = title or name,
                icon = "Interface\\Icons\\INV_Misc_Book_09",
                category = "global",
                addonFrame = existingFrames[name]
            })
        end
    end

    if Wise.frames["Addon visibility"] and Wise.frames["Addon visibility"]:IsShown() then
        Wise:UpdateGroupDisplay("Addon visibility")
    end
end
