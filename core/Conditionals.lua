-- Conditionals.lua
local addonName, Wise = ...

local _G = _G
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local string = string
local table = table
local type = type
-- WoW APIs
local GetRealZoneText = GetRealZoneText
local GetInstanceInfo = GetInstanceInfo
local UnitName = UnitName
local UnitClass = UnitClass
local GetSpecialization = GetSpecialization
local GetSpecializationInfo = GetSpecializationInfo
local UnitLevel = UnitLevel
local UnitRace = UnitRace
local GetBuildInfo = GetBuildInfo
local GetShapeshiftForm = GetShapeshiftForm
local GetActionBarPage = GetActionBarPage
local UnitExists = UnitExists
local UnitFactionGroup = UnitFactionGroup
local IsFalling = IsFalling
local GetUnitSpeed = GetUnitSpeed
local HasPetUI = HasPetUI
local SecureCmdOptionParse = SecureCmdOptionParse
local InCombatLockdown = InCombatLockdown
local C_PvP = C_PvP
local GetWeaponEnchantInfo = GetWeaponEnchantInfo
local PanelTemplates_GetSelectedTab = PanelTemplates_GetSelectedTab
local MailFrame = MailFrame

-- Precompute Action Bar Check String (1-18) to avoid constructing it every frame
local ACTION_BAR_CHECK_STRING
do
    local parts = {}
    for i = 1, 18 do
        table.insert(parts, string.format("[actionbar:%d] %d;", i, i))
    end
    ACTION_BAR_CHECK_STRING = table.concat(parts, " ")
end

-- Comprehensive Whitelist of Valid Visibility Conditionals
-- Includes standard secure macro conditionals and Wise-specific custom keywords.
local VALID_CONDITIONALS = {
    -- Standard WoW Conditionals (SecureStateDriver compatible)
    ["actionbar"] = true, ["bonusbar"] = true, ["btn"] = true, ["button"] = true,
    ["canexitvehicle"] = true, ["channeling"] = true, ["combat"] = true, ["cursor"] = true,
    ["dead"] = true, ["equipped"] = true, ["exists"] = true, ["extrabar"] = true,
    ["flyable"] = true, ["flying"] = true, ["form"] = true, ["group"] = true,
    ["harm"] = true, ["help"] = true, ["indoors"] = true, ["known"] = true,
    ["mod"] = true, ["modifier"] = true, ["mounted"] = true, ["outdoors"] = true,
    ["overridebar"] = true, ["party"] = true, ["pet"] = true, ["petbattle"] = true,
    ["possessbar"] = true, ["pvpcombat"] = true, ["raid"] = true, ["resting"] = true,
    ["spec"] = true, ["stance"] = true, ["stealth"] = true, ["swimming"] = true,
    ["talent"] = true, ["target"] = true, ["unithasvehicleui"] = true, ["vehicleui"] = true,
    ["worn"] = true, ["advflyable"] = true,

    -- Target Modifiers (base names)
    ["@player"] = true, ["@target"] = true, ["@cursor"] = true, ["@mouseover"] = true,
    ["@focus"] = true, ["@pet"] = true, ["@vehicle"] = true, ["@targettarget"] = true,

    -- Wise Custom Conditionals (Handled via Lua/Custom State)
    ["guildbank"] = true, ["bank"] = true, ["mailbox"] = true, ["auctionhouse"] = true, ["always"] = true,
}

-- Built-in Conditionals List
Wise.builtinConditionals = {
    -- Targeted Conditionals
    { type = "header", text = "Targeted Conditionals (Reference Only)" },
    { name = "@player", desc = "Cast on yourself", skipeval = true },
    { name = "@target", desc = "Cast on your current target", skipeval = true },
    { name = "@cursor", desc = "Cast at the mouse cursor location", skipeval = true },
    { name = "@mouseover", desc = "Cast on the unit under your mouse", skipeval = true },
    { name = "@focus", desc = "Cast on your focus target", skipeval = true },
    { name = "@pet", desc = "Cast on your pet", skipeval = true },
    { name = "@vehicle", desc = "Cast on your vehicle", skipeval = true },
    { name = "@targettarget", desc = "Cast on your target's target", skipeval = true },
    { name = "@boss1", desc = "Cast on boss 1 (also boss2, boss3, etc)", skipeval = true },
    { name = "@arena1", desc = "Cast on arena enemy 1 (also arena2, arena3, etc)", skipeval = true },
    { name = "@party1", desc = "Cast on party member 1 (also party2, etc)", skipeval = true },
    { name = "@raid1", desc = "Cast on raid member 1 (also raid2, etc)", skipeval = true },

    -- Target
    { type = "header", text = "Evaluated against the temporary target (default: @target)" },
    { name = "exists", desc = "The unit exists" },
    { name = "help", desc = "Target is friendly (can assist)" },
    { name = "harm", desc = "Target is hostile (can attack)" },
    { name = "dead", desc = "Target is dead" },
    { name = "party", desc = "Target is in your party" },
    { name = "raid", desc = "Target is in your raid" },
    { name = "unithasvehicleui", desc = "Target is in a vehicle" },

    -- Player
    { type = "header", text = "Evaluated against the player only (always @player)" },
    { name = "advflyable", desc = "Area supports advanced flying" },
    { name = "canexitvehicle", desc = "In a vehicle and able to exit" },
    { name = "channeling", desc = "Channeling any spell" },
    { name = "channeling:spellName", desc = "Channeling a specific spell", skipeval = true },
    { name = "combat", desc = "In combat" },
    { name = "equipped:type", desc = "Item type is equipped", skipeval = true },
    { name = "worn:type", desc = "Item type is worn (same as equipped)", skipeval = true },
    { name = "flyable", desc = "Area supports flying" },
    { name = "flying", desc = "Mounted/Flight form and in the air" },
    -- Forms 1-7
    { name = "form:1", desc = "Shapeshift form 1" },
    { name = "form:2", desc = "Shapeshift form 2" },
    { name = "form:3", desc = "Shapeshift form 3" },
    { name = "form:4", desc = "Shapeshift form 4" },
    { name = "form:5", desc = "Shapeshift form 5" },
    { name = "form:6", desc = "Shapeshift form 6" },
    { name = "form:7", desc = "Shapeshift form 7" },
    
    { name = "group", desc = "In any group" },
    { name = "group:party", desc = "In a party" },
    { name = "group:raid", desc = "In a raid" },
    { name = "indoors", desc = "Player is indoors" },
    { name = "outdoors", desc = "Player is outdoors" },
    { name = "known:name", desc = "Knows spell by name", skipeval = true },
    { name = "known:spellID", desc = "Knows spell by ID", skipeval = true },
    { name = "mounted", desc = "Player is mounted" },
    { name = "pet:name", desc = "Pet matches name", skipeval = true },
    { name = "pet:family", desc = "Pet matches family", skipeval = true },
    { name = "petbattle", desc = "In a pet battle" },
    { name = "pvpcombat", desc = "PvP talents are usable" },
    { name = "resting", desc = "In a rested zone" },
    -- Spec 1-4
    { name = "spec:1", desc = "Specialization 1 active" },
    { name = "spec:2", desc = "Specialization 2 active" },
    { name = "spec:3", desc = "Specialization 3 active" },
    { name = "spec:4", desc = "Specialization 4 active" },
    
    { name = "stealth", desc = "Player is stealthed" },
    { name = "swimming", desc = "Player is swimming" },

    -- UI
    { type = "header", text = "Evaluated against the user interface" },
    { name = "actionbar:n", desc = "Action bar page n is active", skipeval = true },

    -- Bonus Bars (Stances/Forms)
    { name = "bonusbar:1/2/3/4/5", desc = "Any Bonus Bar is active" },
    { name = "bonusbar:1", desc = "Bonus Bar 1 (Stealth / Cat Form)" },
    { name = "bonusbar:2", desc = "Bonus Bar 2 (Tree of Life / Spirit)" },
    { name = "bonusbar:3", desc = "Bonus Bar 3 (Bear Form)" },
    { name = "bonusbar:4", desc = "Bonus Bar 4 (Moonkin Form)" },
    { name = "bonusbar:5", desc = "Bonus Bar 5 (Dragonriding / Skyriding)" },

    { name = "overridebar", desc = "Override Bar is active (Bar 11)" },
    { name = "possessbar", desc = "Possess Bar is active (Bar 12)" },
    { name = "shapeshift", desc = "Shapeshift Bar is active" },
    { name = "vehicleui", desc = "Vehicle UI is active" },

    { name = "button:n", desc = "Mouse button n pressed", skipeval = true },
    { name = "cursor", desc = "Dragging an item/spell" },
    { name = "extrabar", desc = "Extra action bar is visible" },
    { name = "modifier", desc = "Any modifier key held" },
    { name = "mod", desc = "Any modifier key held (alias)" },
    { name = "mod:shift", desc = "Shift key held" },
    { name = "mod:ctrl", desc = "Ctrl key held" },
    { name = "mod:alt", desc = "Alt key held" },
}

-- Wise (OPie) Conditionals List
Wise.opieConditionals = {
    { type = "header", text = "Evaluated against location and player status" },
    
    -- Location
    { name = "zone:name", desc = "Real Zone, Sub Zone, or Zone text", skipeval = true },
    { name = "instance:type", desc = "Instance type (dungeon, raid, arena, etc)", skipeval = true },
    { name = "in:type", desc = "Alias for instance", skipeval = true },
    
    -- Player Status
    { name = "me:name", desc = "Player Name, Class, or Class ID", skipeval = true },
    { name = "spec:id/name", desc = "Specialization ID or Name", skipeval = true },
    { name = "level:n", desc = "Player level >= n", skipeval = true },
    { name = "race:name", desc = "Player Race", skipeval = true },
    { name = "game:version", desc = "Game Version (modern, era, cata, etc)", skipeval = true },
    { name = "horde", desc = "Player faction is Horde" },
    { name = "alliance", desc = "Player faction is Alliance" },
    { name = "mercenary", desc = "Player is in mercenary mode" },
    
    -- Forms / Stances (Extended)
    { name = "form:token", desc = "Shapeshift form token (e.g. cat, bear, stealth)", skipeval = true },
    { name = "stance:token", desc = "Alias for form", skipeval = true },

    -- Pet
    { name = "petcontrol", desc = "Player has a pet/control bar" },
    { name = "havepet", desc = "Player has a summoned pet" },
    { name = "havepet:name", desc = "Player has specific pet", skipeval = true },

    -- Items / Equipment
    { name = "imbuedmh", desc = "Main hand has temporary enchant" },
    { name = "imbuedoh", desc = "Off hand has temporary enchant" },
    
    -- Professions
    { name = "prof:skill", desc = "Profession skill level (tail, lw, alch, etc)", skipeval = true },

    -- Bank & Storage
    { type = "header", text = "Bank & Storage" },
    { name = "bank", desc = "Bank interface is open" },
    { name = "guildbank", desc = "Guild Bank interface is open" },
    { name = "mailbox", desc = "Mailbox is open" },
    { name = "auctionhouse", desc = "Auction House is open" },

    -- Non-Secure (Combat Restricted)
    { type = "header", text = "Non-Secure Conditionals" },
    { name = "moving", desc = "Player is moving", combatRestricted = true },
    { name = "falling", desc = "Player is falling", combatRestricted = true },
    { name = "ready:spell", desc = "Spell/Item cooldown is ready", combatRestricted = true, skipeval = true },
    { name = "have:item", desc = "Player has item in bags", combatRestricted = true, skipeval = true },
    { name = "buff:name", desc = "Target has helpful aura", combatRestricted = true, skipeval = true },
    { name = "debuff:name", desc = "Target has harmful aura", combatRestricted = true, skipeval = true },
    { name = "selfbuff:name", desc = "Player has helpful aura", combatRestricted = true, skipeval = true },
    { name = "selfdebuff:name", desc = "Player has harmful aura", combatRestricted = true, skipeval = true },
    { name = "cleanse", desc = "Target can be cleansed by player", combatRestricted = true },
    { name = "combo:n", desc = "Combo points >= n", combatRestricted = true, skipeval = true },
    { name = "near:object", desc = "Near specific object/creature", combatRestricted = true, skipeval = true },
    { name = "bar:n", desc = "Action bar page is n (Future-aware)", combatRestricted = true, skipeval = true },
}

function Wise:UpdateConditionalsTab()
    local container = Wise.OptionsFrame.Views.Conditionals.Content
    local parent = Wise.OptionsFrame.Views.Conditionals

    -- Create Tabs if needed
    if not parent.TabFrame then
        parent.TabFrame = CreateFrame("Frame", nil, parent)
        parent.TabFrame:SetPoint("TOPLEFT", 10, -5)
        parent.TabFrame:SetPoint("TOPRIGHT", -10, -5)
        parent.TabFrame:SetHeight(30)
        
        parent.tabs = {}
        local tabData = {
            { name = "Built-in Macro Conditionals", id = "builtin" },
            { name = "Wise Conditionals", id = "wise" }
        }

        local totalWidth = 410 -- 2 * 200 + 10 padding
        local startX = (parent.TabFrame:GetWidth() - totalWidth) / 2

        for i, t in ipairs(tabData) do
            local btn = CreateFrame("Button", nil, parent.TabFrame, "GameMenuButtonTemplate")
            btn:SetSize(200, 24)
            -- Center alignment
             if i == 1 then
                btn:SetPoint("RIGHT", parent.TabFrame, "CENTER", -5, 0)
            else
                btn:SetPoint("LEFT", parent.TabFrame, "CENTER", 5, 0)
            end
            
            btn:SetText(t.name)
            
            btn:SetScript("OnClick", function()
                Wise.conditionalsSubTab = t.id
                Wise:UpdateConditionalsTab() 
            end)
            
            parent.tabs[t.id] = btn
        end

        -- Repoint main scroll frame down
        if Wise.OptionsFrame.Views.Conditionals.Scroll then
             Wise.OptionsFrame.Views.Conditionals.Scroll:SetPoint("TOPLEFT", 10, -40)
        end
        if Wise.OptionsFrame.Views.Conditionals.Title then
             Wise.OptionsFrame.Views.Conditionals.Title:Hide() -- Hide old title
        end
    end
    
    -- Default subtab
    if not Wise.conditionalsSubTab then Wise.conditionalsSubTab = "builtin" end
    
    -- Update Tab State
    for id, btn in pairs(parent.tabs) do
        if Wise.conditionalsSubTab == id then
            btn:Disable()
        else
            btn:Enable()
        end
    end

    -- Select List
    local list = (Wise.conditionalsSubTab == "wise") and Wise.opieConditionals or Wise.builtinConditionals
    container.conditionalsList = list

    -- Create/Update Rows
    container.rows = container.rows or {}
    local y = -10
    
    for i, item in ipairs(container.conditionalsList) do
        local row = container.rows[i]
        if not row then
            row = CreateFrame("Frame", nil, container)
            row:SetSize(760, 25)
            
            -- Striping Logic
            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints(row)
            row.bg:SetColorTexture(1, 1, 1, 0.05) -- Very faint white
            row.bg:Hide()
            
            row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.name:SetPoint("LEFT", 0, 0)
            row.name:SetWidth(250)
            row.name:SetJustifyH("RIGHT")
            
            row.desc = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.desc:SetPoint("LEFT", row.name, "RIGHT", 20, 0)
            row.desc:SetWidth(350)
            row.desc:SetJustifyH("LEFT")
            
            row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.status:SetPoint("RIGHT", -10, 0)
            row.status:SetWidth(120) 
            row.status:SetJustifyH("RIGHT")
            
            -- Header style
            row.header = row:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
            row.header:SetPoint("CENTER", 0, 0)
            row.header:SetWidth(760)
            row.header:SetJustifyH("CENTER")
            row.header:Hide()

            tinsert(container.rows, row)
        end
        row:Show()
        row:SetPoint("TOPLEFT", 20, y)
        
        -- Apply striping
        if item.type ~= "header" and (i % 2 == 0) then
            if row.bg then row.bg:Show() end
        else
            if row.bg then row.bg:Hide() end
        end

        if item.type == "header" then
            row.name:Hide()
            row.desc:Hide()
            row.status:Hide()
            row.header:Show()
            row.header:SetText(item.text)
            y = y - 45 -- Extra padding for headers
        else
            row.header:Hide()
            row.name:Show()
            row.desc:Show()
            row.status:Show()
            
            row.name:SetText("[" .. item.name .. "]")
            row.desc:SetText(item.desc)
            row.status:SetText("-")
            row.status:SetTextColor(1, 1, 1)

            if item.combatRestricted then
                row.status:SetText("combat only")
                row.status:SetTextColor(1, 1, 1) 
            end
            
            y = y - 25
        end
    end
    
    -- Hide unused rows
    for i = #container.conditionalsList + 1, #container.rows do
        container.rows[i]:Hide()
    end
    
    container:SetHeight(math.abs(y) + 20)
    
    -- Start Live Update (if not already running)
    if not Wise.conditionalsTimerInitialized then
        local updateTimer = 0
        Wise.OptionsFrame.Views.Conditionals:SetScript("OnUpdate", function(self, elapsed)
            updateTimer = updateTimer + elapsed
            if updateTimer > 0.1 then 
                Wise:UpdateConditionalsValues()
                updateTimer = 0
            end
        end)
        Wise.conditionalsTimerInitialized = true
    end
    

    Wise:UpdateConditionalsValues()
end

function Wise:GetConditionalValue(name)
    local base = name:lower():match("^([^:]+)") or name:lower()
    
    if base:sub(1, 1) == "@" then
        return "Reference"
    elseif base == "zone" then
        return GetRealZoneText() or "Unknown"
    elseif base == "instance" or base == "in" then
        local _, type = GetInstanceInfo()
        return type or "none"
    elseif base == "me" then
        local name = UnitName("player")
        local _, class = UnitClass("player")
        return string.format("%s (%s)", name, class)
    elseif base == "spec" then
        local idx = GetSpecialization()
        if not idx then return "None" end
        local id, name = GetSpecializationInfo(idx)
        return string.format("%s (%d)", name or "Unknown", id or 0)
    elseif base == "level" then
        return tostring(UnitLevel("player"))
    elseif base == "race" then
        local _, race = UnitRace("player")
        return race
    elseif base == "game" then
        local version = GetBuildInfo()
        return version
    elseif base == "form" or base == "stance" then
        return tostring(GetShapeshiftForm())
    elseif base == "actionbar" then
        local page = SecureCmdOptionParse(ACTION_BAR_CHECK_STRING)
        return page or tostring(GetActionBarPage())
    elseif base == "pet" then
        return UnitName("pet") or "No Pet"
    end
    
    
    return nil
end

function Wise:EvaluateCustomCondition(name, args)
    local check = name:lower()
    local param = args and args:lower()
    
    -- Faction
    if check == "horde" then
        return UnitFactionGroup("player") == "Horde"
    elseif check == "alliance" then
        return UnitFactionGroup("player") == "Alliance"
    elseif check == "mercenary" then
        return C_PvP and C_PvP.IsMercenary and C_PvP.IsMercenary()
        
    -- Pet
    elseif check == "havepet" then
        return UnitExists("pet")
    elseif check == "petcontrol" then
        return HasPetUI and HasPetUI()
        
    -- Items (Basic Check)
    elseif check == "imbuedmh" then
        local hasEnchant = select(1, GetWeaponEnchantInfo())
        return hasEnchant
    elseif check == "imbuedoh" then
        local _, _, _, _, hasEnchant = GetWeaponEnchantInfo()
        return hasEnchant
        
    -- Combat Restricted (OOC only checks)
    elseif check == "moving" then
        return GetUnitSpeed("player") > 0
    elseif check == "falling" then
        return IsFalling()
    elseif check == "cleanse" then
        return false
        
    -- Bank Checks
    elseif check == "bank" then
        return BankFrame and BankFrame:IsShown()

    elseif check == "guildbank" then
        return GuildBankFrame and GuildBankFrame:IsShown()

    elseif check == "mailbox" then
        return MailFrame and MailFrame:IsShown()

    elseif check == "auctionhouse" then
        return AuctionHouseFrame and AuctionHouseFrame:IsShown()
    end
    
    return false
end

function Wise:ValidateVisibilityCondition(str)
    if not str or str == "" then return true, nil end

    -- 1. Bracket Validation
    local depth = 0
    for i = 1, #str do
        local c = str:sub(i, i)
        if c == "[" then
            depth = depth + 1
            if depth > 1 then return false, "Nested brackets are not allowed." end
        elseif c == "]" then
            depth = depth - 1
            if depth < 0 then return false, "Unbalanced closing bracket." end
        end
    end
    if depth > 0 then return false, "Unbalanced opening bracket." end

    -- 2. Text Outside Brackets Validation
    local stripped = str:gsub("%b[]", "")
    if stripped:match("%S") then
        return false, "Text outside brackets is not allowed."
    end

    -- 3. Token Validation
    for block in str:gmatch("%[(.-)%]") do
        -- Split by comma (AND conditions)
        for token in block:gmatch("[^,]+") do
            -- Trim whitespace
            token = token:match("^%s*(.-)%s*$")
            if token ~= "" then
                -- Check for 'wise:' prefix (Custom Dependency)
                if token:match("^wise:") then
                    -- Valid
                -- Check for 'target=' prefix
                elseif token:lower():match("^target=") then
                    -- Valid
                -- Check for '@' prefix (Target shorthand)
                elseif token:sub(1,1) == "@" then
                    -- Accept if it's in the valid list OR looks like numbered unit
                    if not VALID_CONDITIONALS[token:lower()] then
                         local unit = token:sub(2):lower()
                         if not (unit:match("^raid%d+$") or unit:match("^party%d+$") or unit:match("^boss%d+$") or unit:match("^arena%d+$")) then
                              return false, "Unknown target: " .. token
                         end
                    end
                else
                    -- Standard Conditional
                    -- Extract base name (before :)
                    local base = token:match("^([^:]+)")
                    if not base then base = token end

                    -- Strip 'no' prefix if it exists and base isn't valid as-is
                    local check = base:lower()
                    if not VALID_CONDITIONALS[check] and check:sub(1, 2) == "no" then
                        check = check:sub(3)
                    end

                    if not VALID_CONDITIONALS[check] then
                        return false, "Unknown conditional: " .. base
                    end
                end
            end
        end
    end

    return true, nil
end

function Wise:HasVisibilityErrors(groupName)
    local group = WiseDB.groups[groupName]
    if not group then return false end

    if group.visibilitySettings then
        local showStr = group.visibilitySettings.customShow
        local hideStr = group.visibilitySettings.customHide

        local valid, _ = Wise:ValidateVisibilityCondition(showStr)
        if not valid then return true end

        local valid2, _ = Wise:ValidateVisibilityCondition(hideStr)
        if not valid2 then return true end
    end

    if group.actions then
        for _, slot in pairs(group.actions) do
            for _, action in ipairs(slot) do
                if action.conditions then
                    local valid, _ = Wise:ValidateVisibilityCondition(action.conditions)
                    if not valid then return true end
                end
            end
        end
    end

    return false
end

function Wise:UpdateConditionalsValues()
    local container = Wise.OptionsFrame.Views.Conditionals.Content
    if not container or not container.rows or not container.conditionalsList then return end
    
    local inCombat = InCombatLockdown()
    local isWiseTab = (Wise.conditionalsSubTab == "wise")

    for i, item in ipairs(container.conditionalsList) do
        local row = container.rows[i]
        if row and row:IsShown() and item.type ~= "header" then
            local isActive = false
            local isRestricted = false
            local isSkipped = false

            if item.combatRestricted and inCombat then
                isRestricted = true
            elseif item.skipeval then
                local val = Wise:GetConditionalValue(item.name)
                if val then
                    row.status:SetText(val)
                    row.status:SetTextColor(1, 1, 1) -- White
                else
                    row.status:SetText("-")
                    row.status:SetTextColor(0.5, 0.5, 0.5)
                end
                isSkipped = true
            elseif isWiseTab then
                isActive = Wise:EvaluateCustomCondition(item.name)
            else
                local result = SecureCmdOptionParse(string.format("[%s] true; false", item.name))
                isActive = (result == "true")
            end
            
            if isRestricted then
                row.status:SetText("combat only")
                row.status:SetTextColor(1, 1, 1) -- White
            elseif isSkipped then
                 -- Already updated above
            else
                if isActive then
                    row.status:SetText("ACTIVE")
                    row.status:SetTextColor(0, 1, 0)
                else
                    row.status:SetText("Inactive")
                    row.status:SetTextColor(0.5, 0.5, 0.5)
                end
            end
        end
    end
end
