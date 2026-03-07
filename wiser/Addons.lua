local addonName, Wise = ...

Wise.ADDON_VIS_TEMPLATE = "Addon visibility"

function Wise:EnsureAddonVisGroup()
    if not WiseDB or not WiseDB.groups then return end
    local name = Wise.ADDON_VIS_TEMPLATE
    if not WiseDB.groups[name] then
        Wise:CreateGroup(name, "circle")
        WiseDB.groups[name].enabled = false
    end
    local g = WiseDB.groups[name]
    -- Migration: strip isWiser if it was set previously
    g.isWiser = nil
    g.isAddonVisibility = true
end

function Wise:UpdateAddonsWiserInterface()
    Wise:EnsureAddonVisGroup()
end

-- Addon Frame Resolvers
-- Each resolver returns a table of { displayName = frame } for an addon's controllable windows.
-- Resolvers are keyed by addon name (as returned by C_AddOns.GetAddOnInfo).
Wise.AddonFrameResolvers = {}

Wise.AddonFrameResolvers["AllTheThings"] = function()
    local ATT = _G.AllTheThings
    if not ATT then return {} end
    local frames = {}
    -- Include already-built windows
    if ATT.Windows then
        for suffix, window in pairs(ATT.Windows) do
            if type(window) == "table" and window.IsVisible then
                frames["ATT: " .. suffix] = window
            end
        end
    end
    -- Include defined-but-not-yet-built windows (lazy-loaded)
    if ATT.WindowDefinitions then
        for suffix in pairs(ATT.WindowDefinitions) do
            local key = "ATT: " .. suffix
            if not frames[key] then
                -- Use a sentinel so the selector can list them
                frames[key] = "deferred"
            end
        end
    end
    return frames
end

-- Resolve a frame for an addonvisibility action.
-- First tries _G[addonFrame] (manual/picked frames).
-- Then tries resolvers keyed by addonFrame pattern (e.g. "ATT: Prime").
function Wise:ResolveAddonFrame(action)
    local addonFrame = action and action.addonFrame
    if not addonFrame or addonFrame == "" then return nil end

    -- Direct global lookup (existing behavior)
    local frame = _G[addonFrame]
    if frame then return frame end

    -- Try resolver-based lookup (e.g. "ATT: Prime" -> AllTheThings.Windows.Prime)
    local resolverName, windowKey = addonFrame:match("^(.-):%s*(.+)$")
    if resolverName and windowKey then
        for addonKey, resolver in pairs(Wise.AddonFrameResolvers) do
            local prefix = addonKey:sub(1, 3)
            if resolverName == prefix or resolverName == addonKey then
                local resolved = resolver()
                local result = resolved[addonFrame]
                if result and result ~= "deferred" then
                    return result
                end
                -- Force-build deferred ATT windows
                if result == "deferred" and addonKey == "AllTheThings" then
                    local ATT = _G.AllTheThings
                    if ATT and ATT.GetWindow then
                        local window = ATT:GetWindow(windowKey)
                        if window then return window end
                    end
                end
            end
        end
    end

    return nil
end

-- Get all auto-detected addon frames from all resolvers
function Wise:GetDetectedAddonFrames()
    local results = {}
    for addonKey, resolver in pairs(Wise.AddonFrameResolvers) do
        if C_AddOns and C_AddOns.IsAddOnLoaded(addonKey) then
            local ok, resolved = pcall(resolver)
            if ok and resolved then
                for displayName, frame in pairs(resolved) do
                    local isDeferred = (frame == "deferred")
                    table.insert(results, {
                        name = displayName,
                        frame = not isDeferred and frame or nil,
                        addon = addonKey,
                        deferred = isDeferred,
                    })
                end
            end
        end
    end
    table.sort(results, function(a, b) return a.name < b.name end)
    return results
end

-- Hook ATT's GetWindow so lazy-loaded windows get visibility drivers applied
function Wise:HookAddonWindowCreation()
    local ATT = _G.AllTheThings
    if not ATT or not ATT.GetWindow then return end
    if Wise._hookedATTGetWindow then return end
    Wise._hookedATTGetWindow = true

    hooksecurefunc(ATT, "GetWindow", function(self, suffix, passive)
        -- A window was just accessed (and possibly created).
        -- Re-apply visibility drivers so newly created windows get covered.
        if not InCombatLockdown() then
            C_Timer.After(0.1, function()
                if not InCombatLockdown() then
                    Wise:UpdateAddonVisibility()
                end
            end)
        end
    end)
end
