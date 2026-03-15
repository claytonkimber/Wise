local addonName, Wise = ...

-- Locals First
local _G = _G
local print = print
local pairs = pairs
local type = type
local string = string
local ipairs = ipairs
local tostring = tostring
local C_AddOns = C_AddOns
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local hooksecurefunc = hooksecurefunc
local EnumerateFrames = EnumerateFrames

-- Namespace
Wise.AddonVisibility = {}
local AddonVisibility = Wise.AddonVisibility

-- Tracking table for status reporting
local HookStatus = {}

local function EnsureData()
    if not WiseDB then return end
    WiseDB.addonVisibilityMap = WiseDB.addonVisibilityMap or {}
end

-- ============================================================================
-- Core Hooking Logic
-- ============================================================================

local function AttemptHook(addon, config)
    local parentName = config.parentFrameName
    local childName = config.childFrameName

    local parentFrame = _G[parentName]
    local childFrame = _G[childName]

    if not parentFrame then
        HookStatus[addon] = "Failed (Parent not found: " .. tostring(parentName) .. ")"
        return
    end

    if not childFrame then
        HookStatus[addon] = "Failed (Child not found: " .. tostring(childName) .. ")"
        return
    end

    if InCombatLockdown() then
        -- Wait until out of combat to attempt again?
        -- For now, just mark it. We shouldn't really be loading addons in combat.
        HookStatus[addon] = "Failed (In Combat)"
        return
    end

    local originalParent = childFrame:GetParent()

    -- If the child is already parented to something other than UIParent, use the fallback
    if originalParent and originalParent ~= UIParent and originalParent ~= parentFrame then
        -- Fallback: Use HookScript to sync visibility
        if parentFrame:HasScript("OnShow") then
            parentFrame:HookScript("OnShow", function()
                if not InCombatLockdown() then
                    childFrame:Show()
                end
            end)
        else
            -- If the frame doesn't have an OnShow script, we might need hooksecurefunc on its Show method
            hooksecurefunc(parentFrame, "Show", function()
                 if not InCombatLockdown() then
                    childFrame:Show()
                end
            end)
        end

        if parentFrame:HasScript("OnHide") then
            parentFrame:HookScript("OnHide", function()
                 if not InCombatLockdown() then
                    childFrame:Hide()
                end
            end)
        else
             hooksecurefunc(parentFrame, "Hide", function()
                 if not InCombatLockdown() then
                    childFrame:Hide()
                end
            end)
        end

        -- Sync initial state
        if parentFrame:IsShown() and not InCombatLockdown() then
            childFrame:Show()
        elseif not parentFrame:IsShown() and not InCombatLockdown() then
            childFrame:Hide()
        end

        HookStatus[addon] = "Success (Fallback: HookScript used)"
    else
        -- Attempt SetParent
        childFrame:SetParent(parentFrame)

        -- Sync initial state
        if parentFrame:IsShown() and not InCombatLockdown() then
            childFrame:Show()
        elseif not parentFrame:IsShown() and not InCombatLockdown() then
            childFrame:Hide()
        end

        HookStatus[addon] = "Success (SetParent)"
    end
end

local function ProcessAddon(addon)
    EnsureData()
    local config = WiseDB.addonVisibilityMap[addon]
    if config then
        -- Small delay to let internal frames initialize
        C_Timer.After(0.1, function()
            AttemptHook(addon, config)
        end)
    end
end

-- ============================================================================
-- Initialization & Event Handling
-- ============================================================================

local EventFrame = CreateFrame("Frame")
EventFrame:RegisterEvent("ADDON_LOADED")
EventFrame:SetScript("OnEvent", function(self, event, addon)
    if event == "ADDON_LOADED" then
        EnsureData()
        if WiseDB.addonVisibilityMap[addon] then
             ProcessAddon(addon)
        end
    end
end)

function AddonVisibility:Initialize()
    EnsureData()
    -- Immediate check for already loaded addons
    for addon, config in pairs(WiseDB.addonVisibilityMap) do
        if C_AddOns.IsAddOnLoaded(addon) then
            ProcessAddon(addon)
        else
            HookStatus[addon] = "Pending (Not Loaded)"
        end
    end
end

function AddonVisibility:ProcessAll()
    EnsureData()
    for addon, config in pairs(WiseDB.addonVisibilityMap) do
        if C_AddOns.IsAddOnLoaded(addon) then
            AttemptHook(addon, config)
        else
            HookStatus[addon] = "Pending (Not Loaded)"
        end
    end
end

-- ============================================================================
-- Slash Commands & Utilities
-- ============================================================================

function AddonVisibility:ListHooks()
    EnsureData()
    print("|cff00ccff[Wise: AddonVisibility]|r Status Report:")
    local count = 0
    for addon, config in pairs(WiseDB.addonVisibilityMap) do
        local status = HookStatus[addon] or "Unknown"
        print(string.format("- %s: %s", addon, status))
        count = count + 1
    end
    if count == 0 then
        print("  No addons configured in AddonVisibility.")
    end
end

function AddonVisibility:Inspect(prefix)
    if not prefix or prefix == "" then
        print("|cff00ccff[Wise: AddonVisibility]|r Usage: /av inspect [prefix]")
        return
    end

    print(string.format("|cff00ccff[Wise: AddonVisibility]|r Scanning for frames containing '%s'...", prefix))
    local count = 0
    local currentFrame = EnumerateFrames()

    -- Case-insensitive search
    local lowerPrefix = string.lower(prefix)

    while currentFrame do
        local name = currentFrame:GetName()
        if type(name) == "string" and string.find(string.lower(name), lowerPrefix, 1, true) then
            print("  - " .. name)
            count = count + 1
        end
        currentFrame = EnumerateFrames(currentFrame)
    end

    print(string.format("Scan complete. Found %d matching frames.", count))
end

-- Slash Command Handler
SLASH_ADDONVISIBILITY1 = "/av"
SlashCmdList["ADDONVISIBILITY"] = function(msg)
    local cmd, arg = msg:match("^(%S*)%s*(.*)")
    cmd = cmd and string.lower(cmd) or ""

    if cmd == "list" then
        AddonVisibility:ListHooks()
    elseif cmd == "inspect" then
        AddonVisibility:Inspect(arg)
    else
        print("|cff00ccff[Wise: AddonVisibility]|r Commands:")
        print("  /av list - Show hook status for configured addons.")
        print("  /av inspect [prefix] - Find frames matching the prefix.")
    end
end

-- Hook into Wise's initialization
local origInit = Wise.Initialize
function Wise:Initialize()
    if origInit then origInit(self) end
    AddonVisibility:Initialize()
end
