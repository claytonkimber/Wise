-- SmartItem.lua
-- Optional integration with Syndicator/Baganator for item-based smart interfaces
local addonName, Wise = ...

-- Check if Syndicator is available
function Wise:IsSyndicatorAvailable()
    if Syndicator and Syndicator.Search and Syndicator.Search.RequestSearchEverywhereResults then
        return true
    end
    return false
end

-- Smart Item template interface name (special, never added to custom list)
Wise.SMART_ITEM_TEMPLATE = "Smart Item"

-- Initialize Smart Item support
function Wise:InitializeSmartItem()
    if not self:IsSyndicatorAvailable() then
        return false
    end
    
    -- The "Smart Item" interface is a special Wiser interface that acts as a template
    -- It doesn't appear in the actual game, only in the options panel as a way to create new custom interfaces
    -- Mark it as a special template type
    
    -- Register bag update event to handle auto-updates
    local bagFrame = CreateFrame("Frame")
    bagFrame:RegisterEvent("BAG_UPDATE")
    local updateTimer = nil
    
    bagFrame:SetScript("OnEvent", function() 
        if InCombatLockdown() then return end
        
        if updateTimer then return end
        -- Debounce for 2 seconds to avoid excessive updates during mass looting/organizing
        updateTimer = C_Timer.NewTimer(2, function()
             updateTimer = nil
             if InCombatLockdown() then return end
             
             if not WiseDB or not WiseDB.groups then return end
             
             for name, group in pairs(WiseDB.groups) do
                 if group.isSmartItem and group.smartUpdateOOC and group.smartItemSearch then
                     Wise:RefreshSmartItemInterface(name, true)
                 end
             end
        end)
    end)

    return true
end

-- Perform search using Syndicator API
-- callback receives: (results) where results is array of {itemLink, itemID, itemCount, sources}
function Wise:SearchItems(searchTerm, callback, sourceFilter)
    if not self:IsSyndicatorAvailable() then
        print("|cff00ccff[Wise]|r Syndicator not available for smart item search")
        callback({})
        return
    end
    
    if not searchTerm or searchTerm == "" then
        callback({})
        return
    end
    
    -- Default source filter
    sourceFilter = sourceFilter or {bags = true}
    
    searchTerm = searchTerm:lower()
    
    Syndicator.Search.RequestSearchEverywhereResults(searchTerm, function(results)
        -- Combine results to get unique items
        Syndicator.Search.CombineSearchEverywhereResults(results, function(combinedResults)
            -- Convert to Wise action format
            local items = {}
            for _, r in ipairs(combinedResults) do
                -- Check if item exists in any enabled source
                local hasItem = false
                
                for _, source in ipairs(r.sources or {}) do
                    if source.character then
                        local charKey = Syndicator.API.GetCurrentCharacter()
                        if source.character == charKey then
                            -- It's on current character. Syndicator doesn't easily distinguish bags vs bank here
                            -- Check item count to assume location
                            local bagCount = GetItemCount(r.itemID)
                            local totalCount = GetItemCount(r.itemID, true)
                            local bankCount = totalCount - bagCount
                            
                            -- Bags check
                            if sourceFilter.bags and bagCount > 0 then
                                hasItem = true
                                break
                            end
                            
                            -- Bank check (if in bank and bank is checked)
                            if sourceFilter.bank and bankCount > 0 then
                                hasItem = true
                                break
                            end
                            
                            -- Fallback: If filtered to bags/bank but counts are weird (e.g. reagent bank?), assume "character" covers generic possession if granular check fails?
                            -- For safety: if BagCount > 0 and only Bags checked -> YES
                            -- if BankCount > 0 and only Bank checked -> YES
                            -- What if I have 0 in bags, 0 in bank? (Equipped?) 
                            -- Equipped usually counts as bags in GetItemCount(id, false)? No, usually separate.
                            
                            if (sourceFilter.bags or sourceFilter.bank) and (bagCount == 0 and bankCount == 0) then
                                -- Maybe equipped?
                                if IsEquippedItem(r.itemID) and sourceFilter.bags then
                                     hasItem = true
                                     break
                                end
                            end
                        end
                    elseif source.warband then
                        if sourceFilter.warband then
                            hasItem = true
                            break
                        end
                    elseif source.guild then
                        if sourceFilter.guild then
                            hasItem = true
                            break
                        end
                    end
                end
                
                if hasItem then
                    table.insert(items, {
                        itemLink = r.itemLink,
                        itemID = r.itemID,
                        itemCount = r.itemCount,
                        quality = r.quality,
                    })
                end
            end
            
            callback(items)
        end)
    end)
end

-- Create a custom interface from a Smart Item search
function Wise:CreateSmartItemInterface(searchTerm, callback)
    if not searchTerm or searchTerm == "" then
        print("|cff00ccff[Wise]|r Please enter a search term")
        if callback then callback(false) end
        return
    end
    
    -- Use search term as interface name (sanitize it)
    local interfaceName = searchTerm:gsub("^%s+", ""):gsub("%s+$", "")
    if interfaceName == "" then
        interfaceName = "Smart Search"
    end
    
    -- Ensure unique name
    local baseName = interfaceName
    local counter = 1
    while WiseDB.groups[interfaceName] do
        counter = counter + 1
        interfaceName = baseName .. " " .. counter
    end
    
    print("|cff00ccff[Wise]|r Searching for items matching: " .. searchTerm)
    
    -- Default sources for new interface (Bags only)
    local sources = {bags = true, bank = false, warband = false, guild = false}
    
    self:SearchItems(searchTerm, function(items)
        if #items == 0 then
            print("|cff00ccff[Wise]|r No items found matching: " .. searchTerm)
            if callback then callback(false) end
            return
        end
        
        -- Create the new custom group
        Wise:CreateGroup(interfaceName, "circle")
        local group = WiseDB.groups[interfaceName]
        if not group then
            print("|cff00ccff[Wise]|r Failed to create interface")
            if callback then callback(false) end
            return
        end
        
        -- Mark it as a Smart Item generated interface
        group.isSmartItem = true
        group.smartItemSearch = searchTerm
        group.smartSources = sources -- Save sources
        group.isWiser = false 
        group.smartUpdateOOC = false 
        
        group.buttons = {}
        group.actions = nil
        
        -- Add items as actions
        for _, item in ipairs(items) do
            table.insert(group.buttons, {
                type = "item",
                value = item.itemID,
                category = "global",
            })
        end
        
        print("|cff00ccff[Wise]|r Created Smart Item interface '" .. interfaceName .. "' with " .. #items .. " items")
        
        -- Update UI
        Wise:UpdateGroupDisplay(interfaceName)
        Wise:UpdateOptionsUI()
        
        if callback then callback(true, interfaceName) end
    end, sources)
end

-- Refresh items in a Smart Item interface
function Wise:RefreshSmartItemInterface(interfaceName, silent)
    local group = WiseDB.groups[interfaceName]
    if not group or not group.isSmartItem or not group.smartItemSearch then
        return
    end
    
    local searchTerm = group.smartItemSearch
    -- Use saved sources or default to bags
    local sources = group.smartSources or {bags = true}
    
    if not silent then
        print("|cff00ccff[Wise]|r Refreshing Smart Item interface: " .. interfaceName)
    end
    
    self:SearchItems(searchTerm, function(items)
        -- Clear existing buttons
        group.buttons = {}
        group.actions = nil
        
        -- Add fresh items
        for _, item in ipairs(items) do
            table.insert(group.buttons, {
                type = "item",
                value = item.itemID,
                category = "global",
            })
        end
        
        if not silent then
            print("|cff00ccff[Wise]|r Updated '" .. interfaceName .. "' with " .. #items .. " items")
        end
        
        -- Update UI
        if not InCombatLockdown() then
            Wise:UpdateGroupDisplay(interfaceName)
        end
        
        -- Only update Options UI if the frame is shown
        if Wise.OptionsFrame and Wise.OptionsFrame:IsShown() then
            Wise:UpdateOptionsUI()
        end
    end, sources)
end

-- Create Smart Item settings panel (for the template interface)
function Wise:CreateSmartItemSettingsPanel(panel, group, y)
    if not self:IsSyndicatorAvailable() then
        -- Show message that Syndicator is required
        local msgLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        msgLabel:SetPoint("TOPLEFT", 10, y)
        msgLabel:SetWidth(200)
        msgLabel:SetJustifyH("LEFT")
        msgLabel:SetText("|cffff6600Syndicator/Baganator required for Smart Item search.|r")
        tinsert(panel.controls, msgLabel)
        return y - 40
    end
    
    -- Description
    local descLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    descLabel:SetPoint("TOPLEFT", 10, y)
    descLabel:SetWidth(200)
    descLabel:SetJustifyH("LEFT")
    descLabel:SetText("Search your inventory for items and create a new interface with the results.")
    tinsert(panel.controls, descLabel)
    y = y - 50
    
    -- Search Label
    local searchLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    searchLabel:SetPoint("TOPLEFT", 10, y)
    searchLabel:SetText("Item Search:")
    tinsert(panel.controls, searchLabel)
    y = y - 22
    
    -- Search EditBox
    local searchBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    searchBox:SetSize(180, 22)
    searchBox:SetPoint("TOPLEFT", 10, y)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(100)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    tinsert(panel.controls, searchBox)
    y = y - 30
    
    -- Note: Defaults for new interface are Bags=True, others=False. 
    -- We won't clutter the creation panel with checkboxes unless requested, user asked for checkboxes "In Smart items... after... created... checkboxes showing where items can be filtered from"
    -- But putting them here would give better control. Since request was specific about "after", I'll focus on the refresh panel.
    
    -- Hint text
    local hintLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintLabel:SetPoint("TOPLEFT", 10, y)
    hintLabel:SetWidth(200)
    hintLabel:SetJustifyH("LEFT")
    hintLabel:SetText("Use Syndicator search keywords:\n• quality:epic, boe, soulbound\n• armor, weapon, consumable\n• level:60, ilvl:>400")
    tinsert(panel.controls, hintLabel)
    y = y - 55
    
    -- Create Button
    local createBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
    createBtn:SetSize(180, 26)
    createBtn:SetPoint("TOPLEFT", 10, y)
    createBtn:SetText("Create Smart Interface")
    createBtn:SetScript("OnClick", function()
        local searchTerm = searchBox:GetText()
        -- Create with defaults
        Wise:CreateSmartItemInterface(searchTerm, function(success, newName)
            if success then
                -- Select the new interface
                Wise.selectedGroup = newName
                Wise:UpdateOptionsUI()
            end
        end)
    end)
    tinsert(panel.controls, createBtn)
    y = y - 35
    
    -- Enter key behavior
    searchBox:SetScript("OnEnterPressed", function(self)
        local searchTerm = self:GetText()
        Wise:CreateSmartItemInterface(searchTerm, function(success, newName)
            if success then
                Wise.selectedGroup = newName
                Wise:UpdateOptionsUI()
            end
        end)
        self:ClearFocus()
    end)
    
    return y
end

-- Create Refresh button for existing Smart Item interfaces
function Wise:CreateSmartItemRefreshButton(panel, group, groupName, y)
    if not group.isSmartItem or not group.smartItemSearch then
        return y
    end
    
    -- Ensure smartSources exists
    group.smartSources = group.smartSources or {bags = true, bank = false, warband = false, guild = false}
    
    -- Search Term EditBox
    local searchLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    searchLabel:SetPoint("TOPLEFT", 10, y)
    searchLabel:SetText("Smart Item Search:")
    tinsert(panel.controls, searchLabel)
    y = y - 20
    
    local searchBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    searchBox:SetSize(180, 22)
    searchBox:SetPoint("TOPLEFT", 14, y)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(100)
    searchBox:SetText(group.smartItemSearch or "")
    searchBox:SetCursorPosition(0)
    
    searchBox:SetScript("OnEscapePressed", function(self) 
        self:SetText(group.smartItemSearch or "")
        self:ClearFocus() 
    end)
    
    searchBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    
    searchBox:SetScript("OnEditFocusLost", function(self)
        group.smartItemSearch = self:GetText()
        Wise:RefreshSmartItemInterface(groupName)
    end)
    
    tinsert(panel.controls, searchBox)
    y = y - 30
    
    -- Refresh Button
    local refreshBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
    refreshBtn:SetSize(140, 22)
    refreshBtn:SetPoint("TOPLEFT", 10, y)
    refreshBtn:SetText("Refresh Items")
    refreshBtn:SetScript("OnClick", function()
        group.smartItemSearch = searchBox:GetText() -- Ensure latest text is used
        Wise:RefreshSmartItemInterface(groupName)
    end)
    tinsert(panel.controls, refreshBtn)
    y = y - 30
    
    -- Source Filter Checkboxes
    local sourceLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sourceLabel:SetPoint("TOPLEFT", 10, y)
    sourceLabel:SetText("Sources:")
    tinsert(panel.controls, sourceLabel)
    y = y - 20
    
    local sources = {
        {key = "bags", label = "Bags"},
        {key = "bank", label = "Bank"},
        {key = "warband", label = "Warband Bank"},
        {key = "guild", label = "Guild Bank"},
    }
    
    for _, s in ipairs(sources) do
        local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", 10, y)
        cb:SetChecked(group.smartSources[s.key] or false)
        cb:SetScript("OnClick", function(self)
            group.smartSources[s.key] = self:GetChecked()
            -- If auto-update is enabled, refresh immediately on setting change
            if group.smartUpdateOOC and not InCombatLockdown() then
                 group.smartItemSearch = searchBox:GetText() -- Sync search term just in case
                 Wise:RefreshSmartItemInterface(groupName)
            end
        end)
        tinsert(panel.controls, cb)
        
        local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("LEFT", cb, "RIGHT", 5, 0)
        lbl:SetText(s.label)
        tinsert(panel.controls, lbl)
        
        y = y - 22
    end
    
    y = y - 10

    -- "Update out of combat" Checkbox
    local oocCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    oocCheck:SetPoint("TOPLEFT", 10, y)
    oocCheck:SetChecked(group.smartUpdateOOC or false)
    oocCheck:SetScript("OnClick", function(self)
        group.smartUpdateOOC = self:GetChecked()
    end)
    tinsert(panel.controls, oocCheck)
    
    local oocLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    oocLabel:SetPoint("LEFT", oocCheck, "RIGHT", 5, 0)
    oocLabel:SetText("Update when bag changes (OOC)")
    tinsert(panel.controls, oocLabel)
    
    -- Warning text
    local noteLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    noteLabel:SetPoint("TOPLEFT", 40, y-28)
    noteLabel:SetWidth(180)
    noteLabel:SetJustifyH("LEFT")
    noteLabel:SetText("Automatically refreshes list when inventory changes while out of combat.")
    tinsert(panel.controls, noteLabel)
    
    y = y - 90
    
    return y
end

-- Hook into the main initialization
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self, event)
    C_Timer.After(1, function()
        Wise:InitializeSmartItem()
    end)
end)
