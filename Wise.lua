local addonName, addon = ...
Wise = addon

-- Core Globals/Utilities
local _G = _G
local date = date
local ipairs = ipairs
local pairs = pairs
local print = print
local select = select
local string = string
local table = table
local type = type
local unpack = unpack
local tonumber = tonumber
local tostring = tostring

-- WoW APIs
local C_AddOns = C_AddOns
local C_ClassTalents = C_ClassTalents
local C_CooldownViewer = C_CooldownViewer
local C_Item = C_Item
local C_Macro = C_Macro
local C_Spell = C_Spell
local C_Timer = C_Timer
local C_TradeSkillUI = C_TradeSkillUI
local C_Traits = C_Traits
local CreateFrame = CreateFrame
local GetBindingKey = GetBindingKey
local GetCursorPosition = GetCursorPosition
local GetMacroInfo = GetMacroInfo
local GetNumSpecializations = GetNumSpecializations
local GetProfessionInfo = GetProfessionInfo
local GetProfessions = GetProfessions
local GetRealmName = GetRealmName
local GetSpecialization = GetSpecialization
local GetSpecializationInfo = GetSpecializationInfo
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local StaticPopupDialogs = StaticPopupDialogs
local StaticPopup_Show = StaticPopup_Show
local UnitClass = UnitClass
local UnitName = UnitName

Wise.characterInfo = {}

-- Debug Helper
function Wise:DebugPrint(...)
    if WiseDB and WiseDB.settings and WiseDB.settings.debug then
        local msg = string.format(...)
        print("|cff00ccff[Wise Debug]|r", msg)
        
        if Wise.LogFrame then
            local timestamp = date("%H:%M:%S")
            local current = Wise.LogFrame:GetText() or ""
            -- Basic truncation to avoid memory issues (keep last 5000 chars roughly)
            if #current > 10000 then 
                 current = current:sub(-5000) 
            end
            Wise.LogFrame:SetText(current .. "\n[" .. timestamp .. "] " .. msg)
            -- Auto scroll to bottom
            if Wise.LogFrame:GetParent() then
                 Wise.LogFrame:GetParent():SetVerticalScroll(Wise.LogFrame:GetParent():GetVerticalScrollRange())
            end
        end
    end
end

-- Update Function - Core Info
function Wise:UpdateCharacterInfo(sourceEvent)
    local _, className = UnitClass("player")
    self.characterInfo.class = className
    
    local specIndex = GetSpecialization()
    if specIndex then
        local specID = GetSpecializationInfo(specIndex)
        self.characterInfo.specID = specID
    end
    
    -- Get active talent loadout name
    if C_ClassTalents and C_ClassTalents.GetActiveConfigID then
        if C_ClassTalents.GetStarterBuildActive and C_ClassTalents.GetStarterBuildActive() then
            self.characterInfo.talentBuild = "Starter Build"
        else
            local specID = GetSpecialization()
            local specInfoID = specID and GetSpecializationInfo(specID)
            local configID = C_ClassTalents.GetLastSelectedSavedConfigID and specInfoID and C_ClassTalents.GetLastSelectedSavedConfigID(specInfoID)
            
            if not configID then
                configID = C_ClassTalents.GetLastSelectedConfigID and specInfoID and C_ClassTalents.GetLastSelectedConfigID(specInfoID)
            end
            
            -- Fallback to currently active config ID if no last selected ID found
            if not configID then
                configID = C_ClassTalents.GetActiveConfigID()
            end
            
            if configID then
                local configInfo = C_Traits.GetConfigInfo(configID)
                if configInfo and configInfo.name then
                    self.characterInfo.talentBuild = configInfo.name
                end
            end
        end
    end
    
    -- Update Wiser Interfaces whenever character info changes (e.g. spec change updates Specs list)
    if Wise.UpdateWiserInterfaces then
        local isSpecChange = (sourceEvent == "PLAYER_SPECIALIZATION_CHANGED")
        Wise:UpdateWiserInterfaces(isSpecChange)
    end
end

-- IsGroupAvailable (Needs to be early for updates)
function Wise:IsGroupAvailable(groupName)
    local group = WiseDB.groups[groupName]
    if not group then return false end

    -- Wiser Interfaces: Always available (visibility controlled by easy/hard mode settings)
    -- Must be checked FIRST, before enabled/availability, because Wiser groups may have
    -- enabled=false (legacy default) or availability.mode="NONE" (from Properties migration)
    -- that would incorrectly mark them unavailable.
    if group.isWiser then return true end

    -- If no availability struct (e.g. custom groups or old version), default to enabled/true
    if not group.availability then
        -- respecting old 'enabled' flag if present, otherwise true
        if group.enabled ~= nil then return group.enabled end
        return true
    end

    local avail = group.availability
    if avail.mode == "ALL" then
        return true
    elseif avail.mode == "NONE" then
        return false
    else
        -- Check per-character
        local key = UnitName("player") .. "-" .. GetRealmName()
        return avail.characters[key] == true
    end
end

function Wise:IsActionAllowed(action)
    local category = action.category or "global"
    
    if category == "global" then
        return true
    elseif category == "class" then
        local checkClass = action.addedByClass or action.classRestriction
        if not checkClass then return true end
        return checkClass == self.characterInfo.class
    elseif category == "spec" then
        local checkSpec = action.addedBySpec or action.specRestriction
        if not checkSpec then return true end
        return checkSpec == self.characterInfo.specID
    elseif category == "talent_build" or category == "build" then
        local checkBuild = action.addedByTalentBuild or action.talentBuildRestriction
        if not checkBuild then return true end
        return checkBuild == self.characterInfo.talentBuild
    elseif category == "character" then
        local checkChar = action.addedByCharacter or action.characterRestriction
        if not checkChar then return true end
        local charKey = UnitName("player") .. "-" .. GetRealmName()
        return checkChar == charKey
    end
    
    return true
end

-- Helper: Check if interface is "Disabled" (no visibility settings)
function Wise:IsGroupDisabled(group)
    if not group then return true end
    local s = group.visibilitySettings and group.visibilitySettings.customShow
    local h = group.visibilitySettings and group.visibilitySettings.customHide
    local held = group.visibilitySettings and group.visibilitySettings.held
    local toggle = group.visibilitySettings and group.visibilitySettings.toggleOnPress

    local hasS = (s and s ~= "")
    local hasH = (h and h ~= "")

    if not hasS and not hasH and not held and not toggle then
        return true
    end
    return false
end

function Wise:ShouldLoadAction(action, group)
    -- If not dynamic, load all actions
    if not group.dynamic then
        return true
    end
    
    return self:IsActionAllowed(action)
end

function Wise:GetFilteredActions(group)
    local filtered = {}
    for i, action in ipairs(group.buttons) do
        if Wise:ShouldLoadAction(action, group) then
            table.insert(filtered, {index = i, action = action})
        end
    end
    return filtered
end

-- Update Wiser Interfaces
function Wise:UpdateWiserInterfaces(isSpecChange)
    if not WiseDB or not WiseDB.groups then return end

    -- Helper to ensure group exists with Wiser flag
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

        -- Migration: Force Menu Bar defaults if not already migrated
        if name == "Menu Bar" and not g.migrated_defaults_v1 then
            if defaults then
                if type(defaults) == "function" then
                    defaults(g)
                else
                    for k,v in pairs(defaults) do g[k] = v end
                end
            end
            g.migrated_defaults_v1 = true
        end

        g.isWiser = true -- Mark as Wiser
        g.buttons = {} -- Clear for rebuild
        g.actions = nil -- Clear actions to force migration from new buttons list
        
        -- Store metadata for context (helper for debugging/future features)
        local _, className = UnitClass("player")
        g.class = className
        g.specID = GetSpecializationInfo(GetSpecialization())
        
        return g
    end

    -- 1. Professions
    local profGroup = EnsureWiserGroup("Professions", "circle")
    local profs = {GetProfessions()} -- prof1, prof2, arch, fish, cook
    for _, index in ipairs(profs) do
        if index then
            local name, icon, _, _, _, _, skillLine, _, _, _ = GetProfessionInfo(index)
            if name and skillLine then
                -- Generate toggle macro
                local macroText = string.format("/run local i=C_TradeSkillUI.GetBaseProfessionInfo(); if i and i.professionID==%d then C_TradeSkillUI.CloseTradeSkill() else C_TradeSkillUI.OpenTradeSkill(%d) end", skillLine, skillLine)

                table.insert(profGroup.buttons, {
                    type = "macro", 
                    value = macroText,
                    name = name, -- Store name for tooltip/display
                    icon = icon, -- Explicit icon since macro won't have it by default
                    category = "global"
                })
            end
        end
    end
    -- Trigger display update if this group is active/shown
    if Wise.frames["Professions"] and Wise.frames["Professions"]:IsShown() then
        Wise:UpdateGroupDisplay("Professions")
    end

    -- 2. Menu Bar
    local menuGroup = EnsureWiserGroup("Menu Bar", "circle", {iconSize=28, textSize=12, padding=7})
    -- Menu, Shop, Adventure Guide, Warband Collections, Group Finder, Guild & Communities, Housing Dashboard, Quest Log, Achievements, Spellbook, Talents, Professions, Character Info
    local menuItems = {
        {type="uipanel", value="menu"},
        {type="uipanel", value="shop"},
        {type="uipanel", value="adventureguide"},
        {type="uipanel", value="collections"},
        {type="uipanel", value="groupfinder"},
        {type="uipanel", value="guild"},
        {type="uipanel", value="housing"},
        {type="uipanel", value="questlog"},
        {type="uipanel", value="achievements"},
        {type="uipanel", value="talents"},
        {type="uipanel", value="professions"},
        {type="uipanel", value="character"},
    }
    for _, item in ipairs(menuItems) do
        table.insert(menuGroup.buttons, {
            type = item.type,
            value = item.value,
            category = "global"
        })
    end
    if Wise.frames["Menu Bar"] and Wise.frames["Menu Bar"]:IsShown() then
        Wise:UpdateGroupDisplay("Menu Bar")
    end

    -- 3. Specs
    local specGroup = EnsureWiserGroup("Specs", "circle")
    local numSpecs = GetNumSpecializations()
    local currentSpecIndex = GetSpecialization()
    
    for i = 1, numSpecs do
        if i ~= currentSpecIndex then
            local id, name, _, icon = GetSpecializationInfo(i)
            if id then
                table.insert(specGroup.buttons, {
                    type = "misc",
                    value = "spec_" .. i, -- Use Index for simpler macro
                    name = name,
                    icon = icon,
                    category = "global"
                })
            end
        end
    end
    if Wise.frames["Specs"] and Wise.frames["Specs"]:IsShown() then
         Wise:UpdateGroupDisplay("Specs")
    end
    
    -- Refresh Options UI if open to show new/updated groups
    if Wise.UpdateOptionsUI then
        Wise:UpdateOptionsUI()
    end
end

-- Initialize Function
function Wise:Initialize()
    -- Masque Support
    if LibStub then
        local Masque = LibStub("Masque", true)
        if Masque then
            Wise.MasqueGroup = Masque:Group("Wise")
        end
    end

    print("|cff00ccffWise|r Loaded. Type /wise to open options.")
    
    -- Cache current character info
    if Wise.UpdateCharacterInfo then
        Wise:UpdateCharacterInfo()
    end
    
    -- Cleanup deprecated Wiser Interfaces
    if WiseDB and WiseDB.groups then
        if WiseDB.groups["Cooldowns"] and WiseDB.groups["Cooldowns"].isWiser then
            WiseDB.groups["Cooldowns"] = nil
        end
        if WiseDB.groups["Utilities"] and WiseDB.groups["Utilities"].isWiser then
            WiseDB.groups["Utilities"] = nil
        end
    end
    
    -- Restore Groups
    if WiseDB.groups then
        for name, data in pairs(WiseDB.groups) do
            Wise:UpdateGroupDisplay(name)
            if Wise.frames[name] then
               -- Visibility is handled by UpdateGroupDisplay via State Driver
            end
        end
    end
    
    if Wise.UpdateBindings then Wise:UpdateBindings() end

    -- Track Known Characters
    if not WiseDB.knownCharacters then WiseDB.knownCharacters = {} end
    local charKey = UnitName("player") .. "-" .. GetRealmName()
    if not WiseDB.knownCharacters[charKey] then
        WiseDB.knownCharacters[charKey] = true
    end

    if Wise.InitializeMinimap then
        Wise:InitializeMinimap()
    end
    
    -- Fix for the "Hider" Bug in 11.0.1+
    -- If default Blizzard buff/debuff trackers are hidden, the game stops scanning auras for AddOns.
    -- We keep them functionally "active" but set Alpha to 0 so they scan invisibly.
    if BuffIconCooldownViewer then BuffIconCooldownViewer:SetAlpha(0) end
    if BuffBarCooldownViewer then BuffBarCooldownViewer:SetAlpha(0) end
end

-- Import/Export Serialization
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function Base64Encode(data)
    return ((data:gsub('.', function(x)
        local r, b = '', x:byte()
        for i = 8, 1, -1 do r = r .. (b % 2^i - b % 2^(i-1) > 0 and '1' or '0') end
        return r
    end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if #x < 6 then return '' end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2^(6-i) or 0) end
        return B64:sub(c+1, c+1)
    end) .. ({'', '==', '='})[#data % 3 + 1])
end

local function Base64Decode(data)
    data = data:gsub('[^'..B64..'=]', '')
    return (data:gsub('.', function(x)
        if x == '=' then return '' end
        local r, f = '', (B64:find(x) - 1)
        for i = 6, 1, -1 do r = r .. (f % 2^i - f % 2^(i-1) > 0 and '1' or '0') end
        return r
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if #x ~= 8 then return '' end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i, i) == '1' and 2^(8-i) or 0) end
        return string.char(c)
    end))
end

local function DeserializeTable(str)
    local pos = 1
    local len = #str
    local depth = 0
    local maxDepth = 50
    local maxItems = 10000

    local function skipWhitespace()
        while pos <= len do
            local char = str:sub(pos, pos)
            if char == " " or char == "\t" or char == "\n" or char == "\r" then
                pos = pos + 1
            else
                break
            end
        end
    end

    local parseValue

    local function parseString()
        local quote = str:sub(pos, pos)
        pos = pos + 1
        local res = {}
        while pos <= len do
            local char = str:sub(pos, pos)
            if char == quote then
                pos = pos + 1
                return table.concat(res)
            elseif char == "\\" then
                pos = pos + 1
                if pos > len then break end
                local esc = str:sub(pos, pos)
                if esc == "n" then table.insert(res, "\n")
                elseif esc == "r" then table.insert(res, "\r")
                elseif esc == "t" then table.insert(res, "\t")
                elseif esc == "\\" then table.insert(res, "\\")
                elseif esc == "\"" then table.insert(res, "\"")
                elseif esc == "'" then table.insert(res, "'")
                elseif esc:match("%d") then
                    local ddd = str:sub(pos, pos + 2):match("^%d+")
                    table.insert(res, string.char(tonumber(ddd)))
                    pos = pos + #ddd - 1
                else
                    table.insert(res, esc)
                end
                pos = pos + 1
            else
                table.insert(res, char)
                pos = pos + 1
            end
        end
        error("Unterminated string")
    end

    local function parseNumber()
        local s, e = str:find("%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
        if not s or s ~= pos then error("Invalid number") end
        local numStr = str:sub(s, e)
        local val = tonumber(numStr)
        if not val then error("Invalid number literal: " .. numStr) end
        pos = e + 1
        return val
    end

    local function parseTable()
        depth = depth + 1
        if depth > maxDepth then error("Nested too deep") end

        pos = pos + 1 -- skip '{'
        local t = {}
        local count = 0
        local nextIndex = 1

        while pos <= len do
            skipWhitespace()
            if pos > len then break end
            local char = str:sub(pos, pos)
            if char == "}" then
                pos = pos + 1
                depth = depth - 1
                return t
            end

            count = count + 1
            if count > maxItems then error("Table too large") end

            local key, val
            if char == "[" then
                pos = pos + 1
                key = parseValue()
                skipWhitespace()
                if str:sub(pos, pos) ~= "]" then error("Expected ]") end
                pos = pos + 1
                skipWhitespace()
                if str:sub(pos, pos) ~= "=" then error("Expected =") end
                pos = pos + 1
                val = parseValue()
                t[key] = val
            else
                val = parseValue()
                skipWhitespace()
                if pos <= len and str:sub(pos, pos) == "=" then
                    key = val
                    pos = pos + 1
                    val = parseValue()
                    t[key] = val
                else
                    t[nextIndex] = val
                    nextIndex = nextIndex + 1
                end
            end

            skipWhitespace()
            if str:sub(pos, pos) == "," or str:sub(pos, pos) == ";" then
                pos = pos + 1
            end
        end
        error("Unterminated table")
    end

    parseValue = function()
        skipWhitespace()
        if pos > len then error("Unexpected end of input") end
        local char = str:sub(pos, pos)
        if char == "{" then
            return parseTable()
        elseif char == '"' or char == "'" then
            return parseString()
        elseif char == "-" or char:match("%d") then
            return parseNumber()
        elseif str:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif str:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif str:sub(pos, pos + 2) == "nil" then
            pos = pos + 3
            return nil
        else
            error("Unexpected character: " .. char)
        end
    end

    local ok, result = pcall(parseValue)
    if ok then
        return result
    else
        error(result)
    end
end

local function SerializeTable(val, indent)
    indent = indent or 0
    local pad = string.rep(" ", indent)
    if type(val) == "table" then
        local parts = {}
        local isArray = (#val > 0)
        if isArray then
            for _, v in ipairs(val) do
                parts[#parts+1] = pad .. "  " .. SerializeTable(v, indent + 2)
            end
        else
            local keys = {}
            for k in pairs(val) do keys[#keys+1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys) do
                local keyStr
                if type(k) == "number" then
                    keyStr = "[" .. k .. "]"
                else
                    keyStr = "[" .. string.format("%q", k) .. "]"
                end
                parts[#parts+1] = pad .. "  " .. keyStr .. "=" .. SerializeTable(val[k], indent + 2)
            end
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
    elseif type(val) == "string" then
        return string.format("%q", val)
    elseif type(val) == "number" or type(val) == "boolean" then
        return tostring(val)
    else
        return "nil"
    end
end

function Wise:Serialize(data)
    local str = SerializeTable(data)
    return Base64Encode(str)
end

function Wise:Deserialize(dataString)
    if not dataString or dataString == "" then return nil, "Empty string" end
    local decoded = Base64Decode(dataString)
    if not decoded or decoded == "" then return nil, "Failed to decode Base64" end

    -- Safe deserialization: use a restricted parser instead of loadstring
    local ok, result = pcall(DeserializeTable, decoded)
    if not ok then return nil, "Parse error: " .. tostring(result) end
    if type(result) ~= "table" then return nil, "Invalid data: expected table" end

    return result
end

function Wise:ValidateImportGroup(data)
    if type(data) ~= "table" then return false end
    -- Ensure required fields exist with sensible defaults
    if not data.type then data.type = "circle" end
    if not data.actions then data.actions = {} end
    if not data.visibilitySettings then data.visibilitySettings = {} end
    if not data.keybindSettings then data.keybindSettings = {} end
    if not data.anchor then data.anchor = {point = "CENTER", x = 0, y = 0} end
    -- Strip potentially dangerous fields
    data.binding = nil -- Don't import keybinds (could conflict)
    return true
end

function Wise:ExportInterfaces(names)
    local exportData = { version = 1, groups = {} }
    for _, name in ipairs(names) do
        local group = WiseDB.groups[name]
        if group then
            -- Deep copy to avoid modifying original
            exportData.groups[name] = Wise:DeepCopy(group)
        end
    end
    return Wise:Serialize(exportData)
end

function Wise:ImportInterfaces(dataString, overwrite)
    local data, err = Wise:Deserialize(dataString)
    if not data then return false, err end

    if not data.version then return false, "Missing version field" end
    if data.version > 1 then return false, "Unsupported version: " .. data.version .. ". Please update Wise." end
    if type(data.groups) ~= "table" then return false, "Invalid data: missing groups" end

    local imported = 0
    local conflicts = {}
    for name, groupData in pairs(data.groups) do
        if Wise:ValidateImportGroup(groupData) then
            if not WiseDB.groups[name] or overwrite then
                WiseDB.groups[name] = groupData
                Wise:UpdateGroupDisplay(name)
                imported = imported + 1
            else
                conflicts[#conflicts+1] = { name = name, data = groupData }
            end
        end
    end

    return true, imported .. " interface(s) imported.", conflicts
end

function Wise:ProcessImportConflicts(conflicts)
    if not conflicts or #conflicts == 0 then return end
    local index = 1

    StaticPopupDialogs["WISE_IMPORT_RENAME"] = {
        text = "Interface \"%s\" already exists.\nEnter a new name to import it:",
        button1 = "Import",
        button2 = "Skip",
        hasEditBox = true,
        editBoxWidth = 350,
        OnShow = function(self)
            local eb = self.EditBox or self.editBox; if not eb then return end
            local conflict = conflicts[index]
            eb:SetText(conflict.name .. " - imported")
            eb:HighlightText()
            eb:SetFocus()
        end,
        OnAccept = function(self)
            local eb = self.EditBox or self.editBox
            local newName = eb and eb:GetText()
            if newName and newName ~= "" then
                if WiseDB.groups[newName] then
                    print("|cff00ccff[Wise]|r \"" .. newName .. "\" also exists. Skipped.")
                else
                    WiseDB.groups[newName] = conflicts[index].data
                    Wise:UpdateGroupDisplay(newName)
                    print("|cff00ccff[Wise]|r Imported as \"" .. newName .. "\".")
                    if Wise.UpdateOptionsUI then Wise:UpdateOptionsUI() end
                end
            end
            index = index + 1
            if index <= #conflicts then
                C_Timer.After(0.1, function()
                    StaticPopup_Show("WISE_IMPORT_RENAME", conflicts[index].name)
                end)
            end
        end,
        OnCancel = function()
            index = index + 1
            if index <= #conflicts then
                C_Timer.After(0.1, function()
                    StaticPopup_Show("WISE_IMPORT_RENAME", conflicts[index].name)
                end)
            end
        end,
        EditBoxOnEnterPressed = function(self)
            local parent = self:GetParent()
            StaticPopup_OnClick(parent, 1)
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    StaticPopup_Show("WISE_IMPORT_RENAME", conflicts[1].name)
end

function Wise:DeepCopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do
        copy[Wise:DeepCopy(k)] = Wise:DeepCopy(v)
    end
    return copy
end

-- Core Event Handler Frame
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
frame:RegisterEvent("TRAIT_CONFIG_UPDATED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("SPELLS_CHANGED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("UPDATE_BINDINGS")

function frame:OnEvent(event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        if not WiseDB then
            WiseDB = {
                groups = {},
                settings = {
                    minimap = { hide = true },
                    debug = false,
                    iconSize = 30,
                    textSize = 12,
                    font = "Fonts\\FRIZQT__.TTF",
                    showKeybinds = false,
                    keybindPosition = "BOTTOM",
                    keybindTextSize = 10,
                    chargeTextSize = 12,
                    chargeTextPosition = "TOP",
                    showChargeText = true,
                    -- Countdown Text Defaults
                    countdownTextSize = 12,
                    countdownTextPosition = "CENTER",
                    showCountdownText = true,
                    showGlows = true, -- Default: Enable Proc Glows
                    showBuffs = false, -- Default: Disable Buff Durations
                    enableDragDrop = true, -- Default: Enable Drag and Drop
                    showTooltips = false, -- Default: Disable Interface Tooltips
                },
            }
        end
        -- Ensure global settings exist for existing users
        if WiseDB.settings then
            if WiseDB.settings.showTooltips == nil then WiseDB.settings.showTooltips = false end
            if WiseDB.settings.iconSize == nil then WiseDB.settings.iconSize = 30 end
            if WiseDB.settings.textSize == nil then WiseDB.settings.textSize = 12 end
            if WiseDB.settings.font == nil then WiseDB.settings.font = "Fonts\\FRIZQT__.TTF" end
            if WiseDB.settings.showKeybinds == nil then WiseDB.settings.showKeybinds = false end
            if WiseDB.settings.keybindPosition == nil then WiseDB.settings.keybindPosition = "BOTTOM" end
            if WiseDB.settings.keybindTextSize == nil then WiseDB.settings.keybindTextSize = 10 end
            if WiseDB.settings.chargeTextSize == nil then WiseDB.settings.chargeTextSize = 12 end
            if WiseDB.settings.chargeTextPosition == nil then WiseDB.settings.chargeTextPosition = "TOP" end
            if WiseDB.settings.showChargeText == nil then WiseDB.settings.showChargeText = true end
            -- Countdown Text Defaults
            if WiseDB.settings.countdownTextSize == nil then WiseDB.settings.countdownTextSize = 12 end
            if WiseDB.settings.countdownTextPosition == nil then WiseDB.settings.countdownTextPosition = "CENTER" end
            if WiseDB.settings.showCountdownText == nil then WiseDB.settings.showCountdownText = true end
            if WiseDB.settings.enableDragDrop == nil then WiseDB.settings.enableDragDrop = true end
        end
        -- Ensure settings.debug exists for existing users
        if WiseDB.settings and WiseDB.settings.debug == nil then
            WiseDB.settings.debug = false
        end
        -- Initialize modules if needed
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        if Wise.Initialize then Wise:Initialize() end
        if Wise.UpdateBlizzardUI then Wise:UpdateBlizzardUI() end
        -- Trigger Demo if first time
        if not WiseDB.tutorialComplete and Wise.Demo then
             C_Timer.After(2, function() Wise.Demo:Start() end)
        end
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "TRAIT_CONFIG_UPDATED" or event == "PLAYER_ENTERING_WORLD" or event == "SPELLS_CHANGED" then
        -- Update character cache
        if Wise.UpdateCharacterInfo then
            Wise:UpdateCharacterInfo(event)
        end
        -- Refresh all groups to apply dynamic filtering
        if WiseDB and WiseDB.groups then
            for name, _ in pairs(WiseDB.groups) do
                if Wise.UpdateGroupDisplay then
                    Wise:UpdateGroupDisplay(name)
                end
            end
        end
        -- Update nested interface icons (may have changed due to spec/spell changes)
        if Wise.UpdateInterfaceIcons then
            Wise:UpdateInterfaceIcons()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Process pending updates that were blocked during combat
        if Wise.pendingUpdates then
            for name, _ in pairs(Wise.pendingUpdates) do
                if Wise.UpdateGroupDisplay then
                    Wise:UpdateGroupDisplay(name)
                end
            end
            Wise.pendingUpdates = nil
        end
        if Wise.ResetSequences then
            Wise:ResetSequences()
        end
        if Wise.pendingBlizzardUIUpdate then
            if Wise.UpdateBlizzardUI then Wise:UpdateBlizzardUI() end
        end
    elseif event == "UPDATE_BINDINGS" then
        if Wise.UpdateBindings then
            Wise:UpdateBindings()
        end
    end
end
frame:SetScript("OnEvent", frame.OnEvent)

-- Update icons for buttons that use "interface" action type (nested interfaces).
-- Called on events that may change the nested interface's content (spec change, spells changed, etc.)
function Wise:UpdateInterfaceIcons()
    if not Wise.frames or not Wise.buttonMeta then return end
    for groupName, f in pairs(Wise.frames) do
        if f.buttons then
            for _, btn in ipairs(f.buttons) do
                if btn:IsShown() then
                    local meta = Wise.buttonMeta[btn]
                    if meta and meta.actionType == "interface" then
                        local newIcon = Wise:GetActionIcon("interface", meta.actionValue)
                        if newIcon then
                            btn.icon:SetTexture(newIcon)
                        end
                    end
                end
            end
        end
    end
end

function Wise:OpenPicker(callback)
    Wise.pickingAction = true
    Wise.pickingIcon = false
    Wise.PickerCallback = callback
    Wise.PickerCurrentCategory = "Spell"
    Wise:RefreshPropertiesPanel()
end

function Wise:OpenIconPicker(callback)
    if C_AddOns.IsAddOnLoaded("LargerMacroIconSelection") then
        Wise:OpenMacroPopupPicker(callback)
    else
        Wise.pickingAction = false
        Wise.pickingIcon = true
        Wise.PickerCallback = callback
        Wise:RefreshPropertiesPanel()
    end
end

function Wise:OpenMacroPopupPicker(callback)
    if not C_AddOns.IsAddOnLoaded("Blizzard_MacroUI") then
        C_AddOns.LoadAddOn("Blizzard_MacroUI")
    end

    if not MacroPopupFrame then return end

    -- Capture original state locally to ensure safe restoration
    local origParent = MacroPopupFrame:GetParent()
    local origStrata = MacroPopupFrame:GetFrameStrata()
    local origPoint = { MacroPopupFrame:GetPoint() } -- Basic capture of primary point

    local origOnAccept = MacroPopupFrame.OnAccept
    local origOnCancel = MacroPopupFrame.OnCancel
    local origOnHide = MacroPopupFrame:GetScript("OnHide")
    local origUpdateWidth = MacroPopupFrame.UpdateMacroFramePanelWidth

    local restored = false
    local function RestoreState()
        if restored then return end
        restored = true

        -- Restore frame hierarchy and position (frame is already hiding)
        MacroPopupFrame:SetParent(origParent)
        MacroPopupFrame:SetFrameStrata(origStrata)
        MacroPopupFrame:ClearAllPoints()
        if origPoint[1] then
            MacroPopupFrame:SetPoint(unpack(origPoint))
        end

        MacroPopupFrame.OnAccept = origOnAccept
        MacroPopupFrame.OnCancel = origOnCancel

        if origUpdateWidth then
            MacroPopupFrame.UpdateMacroFramePanelWidth = origUpdateWidth
        end

        -- Restore original OnHide but do NOT call it — Blizzard's handler
        -- expects internal icon-selector state we never initialized.
        if origOnHide then
            MacroPopupFrame:SetScript("OnHide", origOnHide)
        else
            MacroPopupFrame:SetScript("OnHide", nil)
        end
    end

    -- Override UpdateMacroFramePanelWidth to prevent taint/errors when MacroFrame is hidden
    MacroPopupFrame.UpdateMacroFramePanelWidth = function() end

    -- Reparent and Anchor for Visibility
    MacroPopupFrame:SetParent(Wise.OptionsFrame)
    MacroPopupFrame:SetFrameStrata("DIALOG")
    MacroPopupFrame:ClearAllPoints()
    -- Anchor to the right of the options frame ("popout")
    MacroPopupFrame:SetPoint("TOPLEFT", Wise.OptionsFrame, "TOPRIGHT", 0, 0)

    -- Ensure restoration on Hide (covers ESC key and Cancel button)
    MacroPopupFrame:SetScript("OnHide", function(self)
        RestoreState()
    end)

    MacroPopupFrame.OnAccept = function(self)
        local iconTexture = nil

        -- Try 1: selectedIcon property (set by LargerMacroIconSelection)
        if MacroPopupFrame.selectedIcon then
            iconTexture = MacroPopupFrame.selectedIcon
        end

        -- Try 2: Modern Blizzard IconSelector API (Retail 11.0+)
        if not iconTexture and MacroPopupFrame.IconSelector then
            local selector = MacroPopupFrame.IconSelector
            if selector.GetSelectedIndex then
                local idx = selector:GetSelectedIndex()
                if idx then
                    -- Use the data provider if available
                    if selector.iconDataProvider and selector.iconDataProvider.GetIconByIndex then
                        iconTexture = selector.iconDataProvider:GetIconByIndex(idx)
                    else
                        -- Fall back to macro icon list lookup
                        local icons = C_Macro and C_Macro.GetMacroIcons and C_Macro.GetMacroIcons()
                        if icons and icons[idx] then
                            iconTexture = icons[idx]
                        end
                    end
                end
            end
        end

        -- Try 3: Read texture from the selected-icon display area
        if not iconTexture and MacroPopupFrame.BorderBox then
            local area = MacroPopupFrame.BorderBox.SelectedIconArea
            if area then
                local btn = area.SelectedIconButton
                if btn then
                    local icon = btn.Icon or btn.icon
                    if icon and icon.GetTexture then
                        iconTexture = icon:GetTexture()
                    end
                end
            end
        end

        -- Hide triggers OnHide which calls RestoreState
        MacroPopupFrame:Hide()

        if callback and iconTexture then
            callback("icon", iconTexture)
        end
    end

    MacroPopupFrame.OnCancel = function(self)
        MacroPopupFrame:Hide()
    end

    MacroPopupFrame:Show()
end

-- HUD Edit Mode Integration


Wise.BlizzardFrames = {
    -- Action Bar 1: MainMenuBarArtFrame (art background), ActionButton1..12 (buttons)
    -- We avoid hiding MainMenuBar itself because it contains XP/Rep bars (StatusTrackingBarManager) and MicroMenu in some modes.
    -- Additional decorative art (end caps, background) is handled separately in UpdateBlizzardUI.
    { key = "hideActionBar1", label = "Action Bar 1", frames = {"MainMenuBarArtFrame"} },
    { key = "hideStanceBar", label = "Stance Bar", frames = {"StanceBar"} },
    { key = "hidePetBar", label = "Pet Bar", frames = {"PetActionBar"} },
    { key = "hideOverrideBar", label = "Override Bar", frames = {"OverrideActionBar"} },
    { key = "hideMicroMenu", label = "Micro Menu", frames = {"MicroMenuContainer", "MicroMenu"} },
    { key = "hideBagsBar", label = "Bags Bar", frames = {"BagsBar", "BagBarExpandable"} },
}

-- Hook into Edit Mode to re-apply visibility when exiting Edit Mode
if EditModeManagerFrame then
    EditModeManagerFrame:HookScript("OnHide", function()
        if Wise.UpdateBlizzardUI then
             -- Delay slightly to let Blizzard UI finish its layout updates
             C_Timer.After(0.1, function() Wise:UpdateBlizzardUI() end)
        end
    end)
end

Wise.managedFrames = Wise.managedFrames or {}

function Wise:UpdateBlizzardUI()
    if InCombatLockdown() then
        Wise.pendingBlizzardUIUpdate = true
        return
    end

    local settings = WiseDB.settings.blizzardUI or {}

    for _, info in ipairs(Wise.BlizzardFrames) do
        local shouldHide = settings[info.key]
        for _, frameName in ipairs(info.frames) do
            local frame = _G[frameName]
            if frame then
                if shouldHide then
                    RegisterStateDriver(frame, "visibility", "hide")
                    Wise.managedFrames[frame] = true
                elseif Wise.managedFrames[frame] then
                    UnregisterStateDriver(frame, "visibility")
                    if frame.Show then frame:Show() end
                    Wise.managedFrames[frame] = nil
                end
            end
        end
    end

    -- Special handling for Action Bar 1: buttons + decorative art elements
    local hideAB1 = settings["hideActionBar1"]

    -- Action Buttons 1-12
    for i = 1, 12 do
        local btn = _G["ActionButton" .. i]
        if btn then
            if hideAB1 then
                RegisterStateDriver(btn, "visibility", "hide")
                btn:SetAlpha(0)
                btn:EnableMouse(false)
                Wise.managedFrames[btn] = true
            elseif Wise.managedFrames[btn] then
                UnregisterStateDriver(btn, "visibility")
                btn:SetAlpha(1)
                btn:EnableMouse(true)
                if btn.Show then btn:Show() end
                Wise.managedFrames[btn] = nil
            end
        end
    end
    
    if MainActionBar then
        if hideAB1 then
            MainActionBar:SetAlpha(0)
            MainActionBar:EnableMouse(false)
            Wise.managedFrames[MainActionBar] = true
        elseif Wise.managedFrames[MainActionBar] then
            MainActionBar:SetAlpha(1)
            MainActionBar:EnableMouse(true)
            Wise.managedFrames[MainActionBar] = nil
        end
    end

    -- Decorative art elements (end caps / dragon-gryphon art, background, page number)
    -- These may be child frames or textures that aren't covered by MainMenuBarArtFrame alone.
    local artElements = {
        _G["MainMenuBarArtFrameBackground"],
        _G["ActionBarPageNumber"],
        MainMenuBar and MainMenuBar.EndCaps,
        MainMenuBar and MainMenuBar.BorderArt,
        MainMenuBarArtFrame and MainMenuBarArtFrame.LeftEndCap,
        MainMenuBarArtFrame and MainMenuBarArtFrame.RightEndCap,
        MainMenuBarArtFrame and MainMenuBarArtFrame.PageNumber,
        MainActionBar and MainActionBar.EndCaps,
        MainActionBar and MainActionBar.BorderArt,
        MainActionBar and MainActionBar.ActionBarPageNumber,
    }
    for _, element in ipairs(artElements) do
        if element then
            if hideAB1 then
                element:SetAlpha(0)
                if element.Hide then element:Hide() end
                Wise.managedArtElements = Wise.managedArtElements or {}
                Wise.managedArtElements[element] = true
            elseif Wise.managedArtElements and Wise.managedArtElements[element] then
                element:SetAlpha(1)
                if element.Show then element:Show() end
                Wise.managedArtElements[element] = nil
            end
        end
    end

    Wise.pendingBlizzardUIUpdate = false
end

-- Slash Command Handler
SLASH_WISE1 = "/wise"
SlashCmdList["WISE"] = function(msg)
    local cmd, arg = msg:match("^(%S*)%s*(.*)")
    
    if cmd == "hidebars" then
        if not WiseDB.settings.minimap then WiseDB.settings.minimap = { hide = true } end
        local newState = true -- Default toggle on

        if arg == "off" then
            newState = false
        elseif arg == "on" then
            newState = true
        else
            -- Toggle all based on first one? Or just toggle all ON?
            -- Let's make it toggle: if any are visible, hide all. If all hidden, show all.
            local anyVisible = false
            for _, info in ipairs(Wise.BlizzardFrames) do
                if not WiseDB.settings.blizzardUI[info.key] then
                    anyVisible = true
                    break
                end
            end
            newState = anyVisible -- If any visible, hide all (true). If all hidden, show all (false).
        end

        for _, info in ipairs(Wise.BlizzardFrames) do
            WiseDB.settings.blizzardUI[info.key] = newState
        end

        Wise:UpdateBlizzardUI()

        -- Refresh UI if open
        if Wise.PopulateSettingsView and Wise.OptionsFrame and Wise.OptionsFrame:IsShown() and Wise.currentTab == "Settings" then
            Wise:PopulateSettingsView(Wise.OptionsFrame.Views.Settings)
        end

        print("|cff00ccff[Wise]|r Blizzard Bars " .. (newState and "Hidden" or "Shown"))
        return
    end

    if cmd == "delete" then
        if arg == "" then
            print("|cff00ccff[Wise]|r Usage: /wise delete [interface name]")
            return
        end
        if WiseDB.groups[arg] then
            if InCombatLockdown() then
                print("|cff00ccff[Wise]|r Cannot delete interface in combat.")
                return
            end
            Wise:DeleteGroup(arg)
            print("|cff00ccff[Wise]|r Interface '" .. arg .. "' deleted.")
        else
            print("|cff00ccff[Wise]|r Interface '" .. arg .. "' not found.")
        end
        return
    end

    if cmd == "debug" then
        print("|cff00ccff[Wise Debug]|r Checking Bindings...")
        if WiseDB and WiseDB.groups then
            for name, group in pairs(WiseDB.groups) do
                local toggleName = "WiseGroupToggle_" .. name
                local key = GetBindingKey("CLICK " .. toggleName .. ":LeftButton")
                print(string.format("Group '%s': ToggleButton='%s' Key='%s'", name, toggleName, tostring(key)))
                
                -- Check for keybind properties directly
                print(string.format("  Props: bind='%s' keybind='%s' hotkey='%s' trigger='%s'", 
                    tostring(group.bind), tostring(group.keybind), tostring(group.hotkey), tostring(group.trigger)))
            end
        end
        return
    end

    if cmd == "demo" then
        if arg == "reset" then
            WiseDB.tutorialComplete = false
            print("|cff00ccff[Wise]|r Tutorial reset. Reload UI or type '/wise demo start' to begin.")
        elseif arg == "start" then
            if Wise.Demo then Wise.Demo:Start() end
        elseif arg == "stop" then
            if Wise.Demo then Wise.Demo:Stop() end
        else
            print("|cff00ccff[Wise]|r Usage: /wise demo [start|stop|reset]")
        end
        return
    end

    if cmd == "bugreport" then
        if Wise.ShowBugReportWindow then
            Wise:ShowBugReportWindow()
        else
            print("|cff00ccff[Wise]|r Bug Report module not loaded.")
        end
        return
    end

    if Wise.ToggleOptions then
        Wise:ToggleOptions()
    else
        print("|cff00ccff[Wise]|r Options not loaded properly.")
    end
end

function Wise:ToggleOptions()
    if not Wise.OptionsFrame then
        Wise:CreateOptionsFrame()
    end
    if Wise.OptionsFrame:IsShown() then
        Wise.OptionsFrame:Hide()
    else
        Wise.OptionsFrame:Show()
    end
end

-- Validation System
function Wise:ValidateGroup(groupName)
    local group = WiseDB.groups[groupName]
    if not group then return false, "Reference missing" end
    
    -- Check basic types
    if type(group) ~= "table" then return false, "Corrupted Data (Not a table)" end
    if type(group.type) ~= "string" then return false, "Missing 'type'" end
    
    -- Check structure
    if group.buttons and not group.actions then
        if group.isWiser then
            return true  -- Wiser interfaces use buttons, not actions
        else
            return false, "Old Data (Migration Needed)"
        end
    end
    
    if type(group.actions) ~= "table" then
        return false, "Missing 'actions' table"
    end
    
    -- Check for mixed keys in actions (indicative of corruption)
    -- Also ensure anchor is valid
    if not group.anchor or type(group.anchor) ~= "table" then
        return false, "Missing anchor data"
    end
    
    -- Validate Slots
    for k, v in pairs(group.actions) do
        if type(k) == "number" and type(v) ~= "table" then
            return false, "Corrupted Slot " .. k
        end
    end
    
    return true
end
