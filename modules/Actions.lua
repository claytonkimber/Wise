-- Actions.lua
local addonName, addon = ...
Wise = addon

Wise.ActionFilter = "global"

local _G = _G
local pairs = pairs
local ipairs = ipairs
local type = type
local tostring = tostring
local tonumber = tonumber
local string = string
local table = table
-- WoW APIs
local C_Spell = C_Spell
local C_Item = C_Item
local C_MountJournal = C_MountJournal
local C_PetJournal = C_PetJournal
local C_ToyBox = C_ToyBox
local C_Container = C_Container
local C_SpellBook = C_SpellBook
local C_EquipmentSet = C_EquipmentSet
local GetRecipeInfo = GetRecipeInfo
local GetInventoryItemID = GetInventoryItemID
local GameTooltip = GameTooltip

-- API Compatibility
local GetSpellBaseCooldown = (C_Spell and C_Spell.GetSpellBaseCooldown) or GetSpellBaseCooldown
local GetItemSpell = (C_Item and C_Item.GetItemSpell) or GetItemSpell
local GetFlyoutInfo = GetFlyoutInfo
local GetFlyoutSlotInfo = GetFlyoutSlotInfo

-- ═══════════════════════════════════════════════════════════════
-- Drag-to-Reorder Infrastructure
-- ═══════════════════════════════════════════════════════════════

local DRAG_THRESHOLD = 8 -- pixels of movement before drag activates

-- Forward declarations (defined after helpers)
local FinalizeSlotReorder
local FinalizeStateReorder
local CleanupDrag
local ReorderDrag_OnUpdate

local reorderDrag = {
    active = false,         -- true once drag threshold is met
    pending = false,        -- true between mousedown and threshold
    dragType = nil,         -- "slot" or "state"
    sourceSlotID = nil,     -- the data key in group.actions
    sourceVisualIdx = nil,  -- 1-based visual index of source slot
    sourceStateIdx = nil,   -- for state drag: index within states array
    targetVisualIdx = nil,  -- computed during drag
    targetStateIdx = nil,   -- computed during drag (state)
    container = nil,
    sourceFrame = nil,      -- the frame that was mousedown'd
    startX = nil,           -- cursor position at mousedown
    startY = nil,
}

local function GetOrCreateInsertIndicator(container)
    if container.slotInsertIndicator then return container.slotInsertIndicator end
    local ind = container:CreateTexture(nil, "OVERLAY")
    ind:SetColorTexture(0, 0.8, 1, 0.9)
    ind:SetSize(260, 3)
    ind:Hide()
    container.slotInsertIndicator = ind
    return ind
end

local function GetOrCreateStateInsertIndicator(slotFrame)
    if slotFrame.stateInsertIndicator then return slotFrame.stateInsertIndicator end
    local ind = slotFrame:CreateTexture(nil, "OVERLAY")
    ind:SetColorTexture(1, 0.8, 0, 0.9)
    ind:SetSize(240, 2)
    ind:Hide()
    slotFrame.stateInsertIndicator = ind
    return ind
end

-- Floating ghost frame that follows cursor during drag
local dragGhost = nil
local function GetOrCreateDragGhost()
    if dragGhost then return dragGhost end
    dragGhost = CreateFrame("Frame", "WiseDragGhost", UIParent, "BackdropTemplate")
    dragGhost:SetFrameStrata("TOOLTIP")
    dragGhost:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    dragGhost:SetBackdropColor(0.15, 0.15, 0.15, 0.85)
    dragGhost:SetBackdropBorderColor(0, 0.8, 1, 1)
    dragGhost:EnableMouse(false)
    dragGhost:Hide()

    dragGhost.icon = dragGhost:CreateTexture(nil, "ARTWORK")
    dragGhost.icon:SetSize(24, 24)
    dragGhost.icon:SetPoint("LEFT", 4, 0)

    dragGhost.label = dragGhost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dragGhost.label:SetPoint("LEFT", dragGhost.icon, "RIGHT", 4, 0)
    dragGhost.label:SetPoint("RIGHT", -4, 0)
    dragGhost.label:SetJustifyH("LEFT")

    return dragGhost
end

local function ShowDragGhost(sourceFrame, dragType)
    local ghost = GetOrCreateDragGhost()

    if dragType == "slot" then
        -- Show "Slot N" with border color
        ghost:SetSize(160, 28)
        ghost:SetBackdropBorderColor(0, 0.8, 1, 1)
        ghost.icon:Hide()
        ghost.label:ClearAllPoints()
        ghost.label:SetPoint("CENTER")
        ghost.label:SetText(sourceFrame.Header and sourceFrame.Header:GetText() or "Slot")
    elseif dragType == "state" then
        -- Show icon + name from the action button
        ghost:SetSize(180, 30)
        ghost:SetBackdropBorderColor(1, 0.8, 0, 1)
        if sourceFrame.icon and sourceFrame.icon:GetTexture() then
            ghost.icon:SetTexture(sourceFrame.icon:GetTexture())
            ghost.icon:Show()
            ghost.label:ClearAllPoints()
            ghost.label:SetPoint("LEFT", ghost.icon, "RIGHT", 4, 0)
            ghost.label:SetPoint("RIGHT", -4, 0)
        else
            ghost.icon:Hide()
            ghost.label:ClearAllPoints()
            ghost.label:SetPoint("CENTER")
        end
        ghost.label:SetText(sourceFrame.label and sourceFrame.label:GetText() or "State")
    end

    ghost:Show()
end

local function UpdateDragGhostPosition(cx, cy)
    if not dragGhost or not dragGhost:IsShown() then return end
    dragGhost:ClearAllPoints()
    dragGhost:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx + 20, cy - 10)
end

CleanupDrag = function(container)
    if not container then container = reorderDrag.container end
    -- Hide slot indicator
    if container and container.slotInsertIndicator then
        container.slotInsertIndicator:Hide()
    end
    -- Hide state indicators and restore alpha on all slots
    if container and container.slots then
        for _, slot in ipairs(container.slots) do
            if slot:IsShown() then
                slot:SetAlpha(1)
                if slot.stateInsertIndicator then slot.stateInsertIndicator:Hide() end
                for _, ab in ipairs(slot.ActionButtons) do
                    if ab:IsShown() then ab:SetAlpha(1) end
                end
            end
        end
    end
    -- Hide drag ghost
    if dragGhost then dragGhost:Hide() end
    -- Stop OnUpdate
    if container then container:SetScript("OnUpdate", nil) end
    -- Reset state
    reorderDrag.active = false
    reorderDrag.pending = false
    reorderDrag.dragType = nil
    reorderDrag.sourceSlotID = nil
    reorderDrag.sourceVisualIdx = nil
    reorderDrag.sourceStateIdx = nil
    reorderDrag.targetVisualIdx = nil
    reorderDrag.targetStateIdx = nil
    reorderDrag.container = nil
    reorderDrag.sourceFrame = nil
    reorderDrag.startX = nil
    reorderDrag.startY = nil
end

local function UpdateSlotInsertIndicator(container, cursorY)
    local ind = GetOrCreateInsertIndicator(container)
    local slots = container.slots
    local bestIdx = nil
    local anchorSlot = nil
    local anchorPoint = nil -- "TOP" = place at top of anchorSlot, "BOTTOM" = place at bottom

    -- Collect visible slots in order
    local visibleSlots = {}
    for _, slot in ipairs(slots) do
        if slot:IsShown() then
            visibleSlots[#visibleSlots + 1] = slot
        end
    end

    if #visibleSlots == 0 then ind:Hide(); return end

    -- Determine insertion point by comparing cursor to midpoints
    for i, slot in ipairs(visibleSlots) do
        local top = slot:GetTop()
        local bottom = slot:GetBottom()
        if top and bottom then
            local mid = (top + bottom) / 2
            if cursorY > mid then
                -- Insert before this slot (indicator at its top edge)
                bestIdx = i
                anchorSlot = slot
                anchorPoint = "TOP"
                break
            end
        end
    end

    -- If cursor is below all slots, insert after last
    if not bestIdx then
        bestIdx = #visibleSlots + 1
        anchorSlot = visibleSlots[#visibleSlots]
        anchorPoint = "BOTTOM"
    end

    -- Hide indicator for no-op (dropping at same position)
    local srcVis = reorderDrag.sourceVisualIdx
    if bestIdx == srcVis or bestIdx == srcVis + 1 then
        ind:Hide()
        reorderDrag.targetVisualIdx = nil
        return
    end

    reorderDrag.targetVisualIdx = bestIdx
    ind:ClearAllPoints()
    if anchorPoint == "TOP" then
        ind:SetPoint("BOTTOM", anchorSlot, "TOP", 0, 5)
    else
        ind:SetPoint("TOP", anchorSlot, "BOTTOM", 0, -5)
    end
    ind:Show()
end

local function UpdateStateInsertIndicator(container, cursorY)
    -- Find the source slot frame
    local sourceSlotFrame = nil
    if container.slots then
        for _, slot in ipairs(container.slots) do
            if slot:IsShown() and slot.slotID == reorderDrag.sourceSlotID then
                sourceSlotFrame = slot
                break
            end
        end
    end
    if not sourceSlotFrame then return end

    local ind = GetOrCreateStateInsertIndicator(sourceSlotFrame)
    local buttons = sourceSlotFrame.ActionButtons

    -- Collect visible buttons in order
    local visibleBtns = {}
    for _, ab in ipairs(buttons) do
        if ab:IsShown() then
            visibleBtns[#visibleBtns + 1] = ab
        end
    end

    if #visibleBtns == 0 then ind:Hide(); return end

    local bestIdx = nil
    local anchorBtn = nil
    local anchorPoint = nil

    for i, ab in ipairs(visibleBtns) do
        local top = ab:GetTop()
        local bottom = ab:GetBottom()
        if top and bottom then
            local mid = (top + bottom) / 2
            if cursorY > mid then
                bestIdx = i
                anchorBtn = ab
                anchorPoint = "TOP"
                break
            end
        end
    end

    if not bestIdx then
        bestIdx = #visibleBtns + 1
        anchorBtn = visibleBtns[#visibleBtns]
        anchorPoint = "BOTTOM"
    end

    -- Hide for no-op
    local srcState = reorderDrag.sourceStateIdx
    if bestIdx == srcState or bestIdx == srcState + 1 then
        ind:Hide()
        reorderDrag.targetStateIdx = nil
        return
    end

    reorderDrag.targetStateIdx = bestIdx
    ind:ClearAllPoints()
    if anchorPoint == "TOP" then
        ind:SetPoint("BOTTOM", anchorBtn, "TOP", 0, 1)
    else
        ind:SetPoint("TOP", anchorBtn, "BOTTOM", 0, -1)
    end
    ind:Show()
end

ReorderDrag_OnUpdate = function(self, elapsed)
    if not reorderDrag.pending and not reorderDrag.active then return end
    local scale = self:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale

    local mouseDown = IsMouseButtonDown("LeftButton")

    -- Check threshold before activating
    if reorderDrag.pending and not reorderDrag.active then
        -- If mouse released before threshold, cancel pending
        if not mouseDown then
            reorderDrag.pending = false
            reorderDrag.dragType = nil
            reorderDrag.container = nil
            reorderDrag.sourceFrame = nil
            self:SetScript("OnUpdate", nil)
            return
        end
        local dx = cx - (reorderDrag.startX or cx)
        local dy = cy - (reorderDrag.startY or cy)
        if (dx * dx + dy * dy) < (DRAG_THRESHOLD * DRAG_THRESHOLD) then
            return -- not enough movement yet
        end
        -- Threshold met — activate drag
        reorderDrag.active = true
        reorderDrag.pending = false

        if reorderDrag.sourceFrame then
            reorderDrag.sourceFrame:SetAlpha(0.4)
            ShowDragGhost(reorderDrag.sourceFrame, reorderDrag.dragType)
        end
    end

    if reorderDrag.active then
        -- Update ghost position (use raw screen coords for UIParent-anchored ghost)
        local rawCx, rawCy = GetCursorPosition()
        local uiScale = UIParent:GetEffectiveScale()
        UpdateDragGhostPosition(rawCx / uiScale, rawCy / uiScale)

        -- Check for mouse release to finalize
        if not mouseDown then
            if reorderDrag.dragType == "slot" then
                FinalizeSlotReorder()
            elseif reorderDrag.dragType == "state" then
                FinalizeStateReorder()
            else
                CleanupDrag(self)
            end
            return
        end

        -- Update indicator position
        if reorderDrag.dragType == "slot" then
            UpdateSlotInsertIndicator(self, cy)
        elseif reorderDrag.dragType == "state" then
            UpdateStateInsertIndicator(self, cy)
        end
    end
end

FinalizeSlotReorder = function()
    local container = reorderDrag.container
    local groupName = Wise.selectedGroup
    if not groupName or not WiseDB.groups[groupName] then CleanupDrag(container); return end
    local group = WiseDB.groups[groupName]

    local targetVis = reorderDrag.targetVisualIdx
    if not targetVis then CleanupDrag(container); return end

    -- Collect sorted keys
    local keys = {}
    for k in pairs(group.actions) do keys[#keys + 1] = k end
    table.sort(keys)

    local srcVis = reorderDrag.sourceVisualIdx
    if not srcVis or srcVis < 1 or srcVis > #keys then CleanupDrag(container); return end

    if group.propertyType == "CooldownWiser" then
        -- CooldownWiser: preserve integer slot keys, assign decimal keys for moved custom slots
        local sourceKey = keys[srcVis]
        local movedData = group.actions[sourceKey]

        -- Only allow reordering custom (decimal) slots, not imported integer slots
        if sourceKey == math.floor(sourceKey) then
            CleanupDrag(container)
            return
        end

        -- Remove the source slot
        group.actions[sourceKey] = nil

        -- Determine the new decimal key based on target visual position
        -- Adjust target for removal shift
        local adjustedTarget = targetVis
        if targetVis > srcVis then adjustedTarget = adjustedTarget - 1 end
        if adjustedTarget < 1 then adjustedTarget = 1 end

        -- Rebuild sorted keys without the source
        local remainingKeys = {}
        for k in pairs(group.actions) do remainingKeys[#remainingKeys + 1] = k end
        table.sort(remainingKeys)

        -- Find the neighboring keys at the insertion point
        local prevKey, nextKey
        if adjustedTarget <= #remainingKeys then
            nextKey = remainingKeys[adjustedTarget]
        end
        if adjustedTarget > 1 then
            prevKey = remainingKeys[adjustedTarget - 1]
        end

        -- Compute the new decimal key between prevKey and nextKey
        local newKey
        if not prevKey then
            -- Inserting before everything: use half of the first key
            newKey = (nextKey or 1) - 0.5
            if newKey <= 0 then newKey = 0.1 end
        elseif not nextKey then
            -- Inserting after everything
            local baseInt = math.floor(prevKey)
            local decimal = 1
            while group.actions[baseInt + decimal * 0.1] do
                decimal = decimal + 1
            end
            newKey = baseInt + decimal * 0.1
        else
            -- Insert between prevKey and nextKey
            newKey = (prevKey + nextKey) / 2
            -- If that key already exists, nudge it
            local attempts = 0
            while group.actions[newKey] and attempts < 100 do
                newKey = newKey + 0.01
                attempts = attempts + 1
            end
        end

        group.actions[newKey] = movedData

        -- Update selection tracking
        if Wise.selectedSlot == sourceKey then
            Wise.selectedSlot = newKey
        end
    else
        -- Standard groups: rebuild with sequential integer keys
        -- Build ordered list of action table references
        local ordered = {}
        for i, k in ipairs(keys) do
            ordered[i] = group.actions[k]
        end

        -- Remove source from ordered list
        local movedData = table.remove(ordered, srcVis)

        -- Adjust target for removal shift
        local insertAt = targetVis
        if targetVis > srcVis then insertAt = insertAt - 1 end

        -- Clamp
        if insertAt < 1 then insertAt = 1 end
        if insertAt > #ordered + 1 then insertAt = #ordered + 1 end

        table.insert(ordered, insertAt, movedData)

        -- Rebuild group.actions with sequential keys
        local newActions = {}
        for i, data in ipairs(ordered) do
            newActions[i] = data
        end
        group.actions = newActions

        -- Update selection tracking
        if Wise.selectedSlot == reorderDrag.sourceSlotID then
            Wise.selectedSlot = insertAt
        end
    end

    CleanupDrag(container)
    Wise:RefreshActionsView(container)
    Wise:RefreshPropertiesPanel()
    C_Timer.After(0, function()
        if not InCombatLockdown() then Wise:UpdateGroupDisplay(groupName) end
    end)
end

FinalizeStateReorder = function()
    local container = reorderDrag.container
    local groupName = Wise.selectedGroup
    if not groupName or not WiseDB.groups[groupName] then CleanupDrag(container); return end
    local group = WiseDB.groups[groupName]

    local slotID = reorderDrag.sourceSlotID
    local states = group.actions[slotID]
    if not states then CleanupDrag(container); return end

    local targetIdx = reorderDrag.targetStateIdx
    if not targetIdx then CleanupDrag(container); return end

    local srcIdx = reorderDrag.sourceStateIdx
    if not srcIdx or srcIdx < 1 or srcIdx > #states then CleanupDrag(container); return end

    local movedState = table.remove(states, srcIdx)

    local insertAt = targetIdx
    if targetIdx > srcIdx then insertAt = insertAt - 1 end
    if insertAt < 1 then insertAt = 1 end
    if insertAt > #states + 1 then insertAt = #states + 1 end

    table.insert(states, insertAt, movedState)

    -- Update selection tracking
    if Wise.selectedSlot == slotID and Wise.selectedState == srcIdx then
        Wise.selectedState = insertAt
    end

    CleanupDrag(container)
    Wise:RefreshActionsView(container)
    Wise:RefreshPropertiesPanel()
    C_Timer.After(0, function()
        if not InCombatLockdown() then Wise:UpdateGroupDisplay(groupName) end
    end)
end

-- ═══════════════════════════════════════════════════════════════
-- End Drag-to-Reorder Infrastructure
-- ═══════════════════════════════════════════════════════════════

function Wise:ShouldShowAction(action)
    local filter = Wise.ActionFilter
    local enables = action.visibilityEnable or {}

    -- "Global" filter -> Show everything
    if filter == "global" then return true end

    -- If there are NO enables, it is effectively global
    if #enables == 0 then return true end

    for _, tag in ipairs(enables) do
        if filter == "class" and tag:match("^class:") then
            local _, pClass = UnitClass("player")
            if tag == "class:" .. pClass then return true end
        elseif filter == "role" and tag:match("^role:") then
            if tag == "role:" .. (Wise.characterInfo.role or "") then return true end
        elseif filter == "spec" and tag:match("^spec:") then
            if tag == "spec:" .. (Wise.characterInfo.specID or "") then return true end
        elseif filter == "talent" and tag:match("^talent:") then
            -- Let's just show it in the list if they select talent
            return true
        elseif filter == "character" and tag:match("^char:") then
            local charKey = UnitName("player") .. "-" .. GetRealmName()
            if tag == "char:" .. charKey then return true end
        end
    end

    return false
end

Wise.ActionTypes = {
    "spell", "item", "macro", "toy", "mount", 
    "battlepet", "equipmentset", "raidmarker", "worldmarker", "uipanel", "uivisibility", "skyriding", "professions", "misc"
}

-- Category constants
Wise.Categories = {"global", "class", "role", "spec", "talent", "character"}
Wise.CategoryLabels = {
    global = "Global",
    class = "Class",
    role = "Role",
    spec = "Spec",
    talent = "Talents",
    character = "Character"
}
Wise.RoleLabels = {
    TANK = "Tank",
    HEALER = "Healer",
    DAMAGER = "DPS",
}

-- Resolve the spellbook category for a given spell ID.
-- Returns category ("global", "class", "spec") and sourceSpecID (or nil).
-- Checks both direct spell ID match and override match (base spell in book -> override active).
function Wise:ResolveSpellCategory(spellID)
    if not spellID or not C_SpellBook or not C_SpellBook.GetNumSpellBookSkillLines then
        return "global", nil
    end
    if type(spellID) == "string" then
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
        if info then spellID = info.spellID else return "global", nil end
    end

    local currentSpec = GetSpecialization()
    local currentSpecID = currentSpec and GetSpecializationInfo(currentSpec) or nil
    local numSkillLines = C_SpellBook.GetNumSpellBookSkillLines()

    for i = 1, numSkillLines do
        local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(i)
        if lineInfo then
            local offset = lineInfo.itemIndexOffset
            local count = lineInfo.numSpellBookItems
            for j = 1, count do
                local index = offset + j
                local spellType, bookSpellID = C_SpellBook.GetSpellBookItemType(index, Enum.SpellBookSpellBank.Player)
                if spellType == Enum.SpellBookItemType.Spell then
                    local overrideID = Wise:GetOverrideSpellID(bookSpellID)
                    if bookSpellID == spellID or overrideID == spellID then
                        if lineInfo.specID then
                            return "spec", lineInfo.specID
                        elseif lineInfo.name == "General" or lineInfo.name == "Warbands" then
                            return "global", nil
                        else
                            return "class", nil
                        end
                    end
                end
            end
        end
    end

    return "global", nil
end

-- ... (existing code) ...

function Wise:GetSkyriding(filter)
    local spells = {}
    local seen = {}
    
    -- Iterate General Spellbook Tab to find Skyriding spells dynamically
    -- Skyriding spells are usually in the "General" tab 
    -- Alternatively, they might be marked with a specific label or category in C_SpellBook?
    -- For now, let's combine a known list with a scan of the General tab for keywords.
    
    local targetSpells = {
        "Switch Flight Style",
        "Skyward Ascent",
        "Surge Forward",
        "Whirling Surge",
        "Bronze Timelock",
        "Second Wind",
        "Airborne Tumbling",
        "Lightning Rush",
        "Aerial Halt"
    }
    
    -- Add from hardcoded list first
    for _, spellName in ipairs(targetSpells) do
        local info = C_Spell.GetSpellInfo(spellName)
        if info then
            if not seen[info.name] and (not filter or string.find(string.lower(info.name), filter, 1, true)) then
                table.insert(spells, {type="spell", value=info.spellID, name=info.name, icon=info.iconID, category="Skyriding"})
                seen[info.name] = true
            end
        end
    end
    
    -- Scan General Tab (Skill Line 1 usually)
    -- This helps find racial specific ones like Soar (Dracthyr) if they are in General
    local numSkillLines = C_SpellBook.GetNumSpellBookSkillLines()
    for i = 1, numSkillLines do
        local info = C_SpellBook.GetSpellBookSkillLineInfo(i)
        if info and info.name == "General" then
            local offset = info.itemIndexOffset
            local count = info.numSpellBookItems
            for j = 1, count do
                 local index = offset + j
                 local spellType, spellId = C_SpellBook.GetSpellBookItemType(index, Enum.SpellBookSpellBank.Player)
                 if spellType == Enum.SpellBookItemType.Spell then
                     local sName = C_Spell.GetSpellName(spellId)
                     -- Heuristic: Check if known skyriding spell but missed by list?
                     -- hard to detect generically without a "Skyriding" tag.
                     -- For now, trust the list + "Switch Flight Style".
                     
                     -- Check for "Ride" or "Sky" in name? Too risky.
                     -- Let's stick to the list + ensuring Dracthyr Soar is there.
                     if sName == "Soar" or sName == "Lift Off" then
                          if not seen[sName] and (not filter or string.find(string.lower(sName), filter, 1, true)) then
                             local icon = C_Spell.GetSpellTexture(spellId)
                             table.insert(spells, {type="spell", value=spellId, name=sName, icon=icon, category="Skyriding"})
                             seen[sName] = true
                          end
                     end
                 end
            end
        end
    end

    table.sort(spells, function(a, b) return a.name < b.name end)
    return spells
end

function Wise:GetTransportation(filter)
    local items = {}
    local seen = {}

    -- 1. Spells (Teleport, Portal, Hero's Path, etc.)
    local numSkillLines = C_SpellBook.GetNumSpellBookSkillLines()
    for i = 1, numSkillLines do
        local info = C_SpellBook.GetSpellBookSkillLineInfo(i)
        if info then
            local offset = info.itemIndexOffset
            local count = info.numSpellBookItems
            for j = 1, count do
                local index = offset + j
                local spellType, spellId = C_SpellBook.GetSpellBookItemType(index, Enum.SpellBookSpellBank.Player)
                if spellType == Enum.SpellBookItemType.Spell then
                    if not C_Spell.IsSpellPassive(spellId) then
                        local sName = C_Spell.GetSpellName(spellId)
                        local sIcon = C_Spell.GetSpellTexture(spellId)
                        if sName then
                            local isTransport = false
                            local displayName = sName

                            -- Check keywords
                            if string.match(sName, "^Teleport:") or
                               string.match(sName, "^Portal:") or
                               sName == "Dreamwalk" or
                               sName == "Astral Recall" or
                               sName == "Zen Pilgrimage" or
                               sName == "Death Gate" then
                                isTransport = true
                            elseif string.find(sName, "Hero's Path:") then
                                isTransport = true
                                -- Remove "Hero's Path: " or "Hero's Path:"
                                displayName = string.gsub(sName, "Hero's Path:%s*", "")
                            end

                            if isTransport and (not filter or string.find(string.lower(displayName), filter, 1, true)) then
                                if not seen[displayName] then
                                    table.insert(items, {
                                        type = "spell",
                                        value = spellId,
                                        name = displayName,
                                        icon = sIcon,
                                        category = "Transportation"
                                    })
                                    seen[displayName] = true
                                end
                            end
                        end
                    end
                elseif spellType == Enum.SpellBookItemType.Flyout then
                    local flyoutID = spellId
                    local flyoutName, _, numSlots, isKnown = GetFlyoutInfo(flyoutID)
                    if isKnown and numSlots > 0 then
                        for s = 1, numSlots do
                            local flyoutSpellID, overrideSpellID, isKnownSlot = GetFlyoutSlotInfo(flyoutID, s)
                            if isKnownSlot and flyoutSpellID then
                                local actualSpellID = overrideSpellID or flyoutSpellID
                                if not C_Spell.IsSpellPassive(actualSpellID) then
                                    local sName = C_Spell.GetSpellName(actualSpellID)
                                    local sIcon = C_Spell.GetSpellTexture(actualSpellID)
                                    if sName then
                                        local isTransport = false
                                        local displayName = sName

                                        if string.match(sName, "^Teleport:") or
                                           string.match(sName, "^Portal:") or
                                           sName == "Dreamwalk" or
                                           sName == "Astral Recall" or
                                           sName == "Zen Pilgrimage" or
                                           sName == "Death Gate" then
                                            isTransport = true
                                        elseif string.find(sName, "Hero's Path:") then
                                            isTransport = true
                                            -- Remove "Hero's Path: " or "Hero's Path:"
                                            displayName = string.gsub(sName, "Hero's Path:%s*", "")
                                        elseif flyoutName and string.find(flyoutName, "Hero's Path:") then
                                            isTransport = true
                                        end

                                        if isTransport and (not filter or string.find(string.lower(displayName), filter, 1, true)) then
                                            if not seen[displayName] then
                                                table.insert(items, {
                                                    type = "spell",
                                                    value = actualSpellID,
                                                    name = displayName,
                                                    icon = sIcon,
                                                    category = "Transportation"
                                                })
                                                seen[displayName] = true
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- 2. Items (Hearthstones, teleport items in bags)
    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                local name = C_Item.GetItemNameByID(info.itemID)
                if name then
                    local isTransportItem = false

                    if string.match(string.lower(name), "hearthstone") then
                        isTransportItem = true
                    else
                        -- Check if item casts a teleport spell
                        local spellID
                        if GetItemSpell then
                            local _, sID = GetItemSpell(info.itemID)
                            spellID = sID
                        end
                        if not spellID and C_Item and C_Item.GetItemSpell then
                            local res = C_Item.GetItemSpell(info.itemID)
                            if res and res.spellID then spellID = res.spellID end
                        end

                        if spellID then
                            local sName = C_Spell.GetSpellName(spellID)
                            if sName and (string.match(sName, "^Teleport:") or string.match(sName, "^Portal:")) then
                                isTransportItem = true
                            end
                        end
                    end

                    if isTransportItem and (not filter or string.find(string.lower(name), filter, 1, true)) then
                        if not seen[name] then
                            table.insert(items, {
                                type = "item",
                                value = info.itemID,
                                name = name,
                                icon = info.iconFileID,
                                category = "Transportation"
                            })
                            seen[name] = true
                        end
                    end
                end
            end
        end
    end

    -- 3. Toys (Hearthstones, Wormholes, etc.)
    if C_ToyBox then
        local wasCollectedShown = C_ToyBox.GetCollectedShown()
        local wasUncollectedShown = C_ToyBox.GetUncollectedShown()
        C_ToyBox.SetCollectedShown(true)
        C_ToyBox.SetUncollectedShown(false)
        for i = 1, C_ToyBox.GetNumFilteredToys() do
            local itemID = C_ToyBox.GetToyFromIndex(i)
            if itemID ~= -1 then
                local _, name, icon = C_ToyBox.GetToyInfo(itemID)
                if name then
                    local isTransportToy = false
                    local lName = string.lower(name)

                    if string.match(lName, "hearthstone") or string.match(lName, "wormhole") then
                        isTransportToy = true
                    else
                        -- Check if toy casts a teleport spell
                        local spellID
                        if GetItemSpell then
                            local _, sID = GetItemSpell(itemID)
                            spellID = sID
                        end
                        if not spellID and C_Item and C_Item.GetItemSpell then
                            local res = C_Item.GetItemSpell(itemID)
                            if res and res.spellID then spellID = res.spellID end
                        end

                        if spellID then
                            local sName = C_Spell.GetSpellName(spellID)
                            if sName and (string.match(sName, "^Teleport:") or string.match(sName, "^Portal:")) then
                                isTransportToy = true
                            end
                        end
                    end

                    if isTransportToy and (not filter or string.find(string.lower(name), filter, 1, true)) then
                        if not seen[name] then
                            table.insert(items, {
                                type = "toy",
                                value = itemID,
                                name = name,
                                icon = icon,
                                category = "Transportation"
                            })
                            seen[name] = true
                        end
                    end
                end
            end
        end
        C_ToyBox.SetCollectedShown(wasCollectedShown)
        C_ToyBox.SetUncollectedShown(wasUncollectedShown)
    end

    table.sort(items, function(a, b) return a.name < b.name end)
    return items
end

function Wise:GetInterface(filter)
    local allowedWiser = { ["Specs"] = true, ["Professions"] = true, ["Forms"] = true, ["Menu Bar"] = true }

    local items = {}
    
    -- Context: Who is the parent?
    -- Wise.selectedGroup is the interface we are editing (the parent)
    local parentName = Wise.selectedGroup
    local parentGroup = parentName and WiseDB.groups[parentName]
    
    if not parentGroup then 
        -- Fallback if no selected group (e.g. testing?), list all
        for name, group in pairs(WiseDB.groups) do
             if (not group.isWiser or allowedWiser[name]) and (not filter or string.find(string.lower(name), filter, 1, true)) then
                 local icon = Wise:GetActionIcon("interface", name)
                 table.insert(items, {type="interface", value=name, name=name, icon=icon, category="Interface"})
             end
        end
        table.sort(items, function(a, b) return a.name < b.name end)
        return items
    end
    
    local parentType = parentGroup.type or "circle"
    -- Check fixedAxis for "Line" determination
    local parentAxis = parentGroup.fixedAxis or "x" 
    
    for name, group in pairs(WiseDB.groups) do
        -- Base Filters:
        -- 1. Not Wiser (Wiser Interfaces can't be selected)
        -- 2. Not Self (Cannot nest inside itself)
        if (not group.isWiser or allowedWiser[name]) and name ~= parentName then

            -- Filter by text
            if not filter or string.find(string.lower(name), filter, 1, true) then

                -- All nesting allowed initially since child mode can be overridden
                local allowed = true

                if allowed then
                    local icon = Wise:GetActionIcon("interface", name)
                    table.insert(items, {
                        type = "interface",
                        value = name,
                        name = name,
                        icon = icon,
                        category = "Interface"
                    })
                end
            end
        end
    end
    
    table.sort(items, function(a, b) return a.name < b.name end)
    return items
end

-- ============================================================================
-- Data Management
-- ============================================================================

-- Migrate a group to the new numbered slot structure
function Wise:MigrateGroupToActions(group)
    if not group.actions and group.buttons then
        group.actions = {}
        for i, btnData in ipairs(group.buttons) do
            -- Assign to slot 'i'
            group.actions[i] = { btnData }
        end
        -- Clear oldButtons to avoid confusion (but maybe keep backup?)
        -- group.buttons = nil -- Keep for safety for now?
    end
    group.actions = group.actions or {}

    -- Migrate old talent/build restrictions and new visibility enables/disables
    for _, slotStates in pairs(group.actions) do
        for _, action in ipairs(slotStates) do
            -- Talent migration
            if action.category == "talent_build" or action.category == "build" then
                action.category = "talent"
            end
            if action.addedByTalentBuild then
                action.talentRequirements = action.addedByTalentBuild
                action.addedByTalentBuild = nil
            elseif action.talentBuildRestriction then
                action.talentRequirements = action.talentBuildRestriction
                action.talentBuildRestriction = nil
            end

            -- Convert old category/addedBy logic to visibilityEnable / visibilityDisable
            if action.category and (not action.visibilityEnable and not action.visibilityDisable) then
                action.visibilityEnable = {}
                action.visibilityDisable = {}
                local cat = action.category

                if cat == "class" then
                    local cls = action.addedByClass or action.classRestriction
                    if cls then table.insert(action.visibilityEnable, "class:" .. cls) end
                elseif cat == "role" then
                    if type(action.roleRequirements) == "table" then
                        for _, r in ipairs(action.roleRequirements) do
                            table.insert(action.visibilityEnable, "role:" .. r)
                        end
                    end
                elseif cat == "spec" then
                    if type(action.specRequirements) == "table" and #action.specRequirements > 0 then
                        for _, sp in ipairs(action.specRequirements) do
                            table.insert(action.visibilityEnable, "spec:" .. sp)
                        end
                    else
                        local sp = action.addedBySpec or action.specRestriction
                        if sp then table.insert(action.visibilityEnable, "spec:" .. sp) end
                    end
                elseif cat == "talent" then
                    if type(action.talentRequirements) == "table" then
                        for _, t in ipairs(action.talentRequirements) do
                            table.insert(action.visibilityEnable, "talent:" .. t)
                        end
                    end
                elseif cat == "character" then
                    local ch = action.addedByCharacter or action.characterRestriction
                    if ch then table.insert(action.visibilityEnable, "char:" .. ch) end
                end

                -- action.category = nil -- Don't delete it yet just in case, but rely on new structure
            end
        end
    end
end

-- Add an action to a specific slot (and state index)
-- If slot is nil, find next available
function Wise:AddAction(groupName, slotIndex, actionType, actionValue, category, extraData, insertIndex)
    local group = WiseDB.groups[groupName]
    if not group then return end
    
    Wise:MigrateGroupToActions(group)
    
    -- Capture Metadata
    local _, playerClass = UnitClass("player")
    local currentSpec = GetSpecialization()
    local specID = currentSpec and GetSpecializationInfo(currentSpec) or nil
    local talentBuildName = nil

    if Wise.characterInfo and Wise.characterInfo.talentBuild then
        talentBuildName = Wise.characterInfo.talentBuild
    else
        -- Fallback if characterInfo is somehow not ready
        if C_ClassTalents and C_ClassTalents.GetActiveConfigID then
            if C_ClassTalents.GetStarterBuildActive and C_ClassTalents.GetStarterBuildActive() then
                talentBuildName = "Starter Build"
            else
                local specID_val = GetSpecialization()
                local specInfoID = specID_val and GetSpecializationInfo(specID_val)
                local configID = C_ClassTalents.GetLastSelectedSavedConfigID and specInfoID and C_ClassTalents.GetLastSelectedSavedConfigID(specInfoID)
                
                if not configID then
                    configID = C_ClassTalents.GetLastSelectedConfigID and specInfoID and C_ClassTalents.GetLastSelectedConfigID(specInfoID)
                end
                
                if not configID then
                    configID = C_ClassTalents.GetActiveConfigID()
                end
                
                if configID and C_Traits and C_Traits.GetConfigInfo then
                    local configInfo = C_Traits.GetConfigInfo(configID)
                    -- Ensure configInfo is a valid table before accessing .name
                    if type(configInfo) == "table" and configInfo.name then 
                        talentBuildName = configInfo.name 
                    end
                end
            end
        end
    end

    if Wise.DebugPrint then
        Wise:DebugPrint("Wise:AddAction - TalentBuild cached: " .. tostring(Wise.characterInfo and Wise.characterInfo.talentBuild) .. " | Used: " .. tostring(talentBuildName) .. " | ActionValue: " .. tostring(actionValue))
    end
    
    -- Resolve Category and Spec Source
    -- Default to Global if not provided
    local resolvedCategory = "global"
    if category and category ~= "global" then resolvedCategory = category end
    if extraData and extraData.category then resolvedCategory = extraData.category end

    -- Auto-detect category for spells if still "global" (catches all entry points)
    if actionType == "spell" and resolvedCategory == "global" and Wise.ResolveSpellCategory then
        local detectedCat, detectedSpecID = Wise:ResolveSpellCategory(actionValue)
        if detectedCat ~= "global" then
            resolvedCategory = detectedCat
            if detectedSpecID and not (extraData and extraData.sourceSpecID) then
                extraData = extraData or {}
                extraData.sourceSpecID = detectedSpecID
            end
        end
    end

    -- Spec ID: Use sourceSpecID if provided (for Off-Spec spells), else current spec
    local resolvedSpecID = specID
    if extraData and extraData.sourceSpecID then resolvedSpecID = extraData.sourceSpecID end
    if resolvedCategory == "class" then resolvedSpecID = nil end -- Class spells don't have a spec restriction

    local newAction = {
        type = actionType,
        value = actionValue,
        category = resolvedCategory, -- keeping for legacy safety temporarily
        visibilityEnable = {},
        visibilityDisable = {},
        addedByCharacter = UnitName("player") .. "-" .. GetRealmName(),
        addedByClass = playerClass,
        addedBySpec = resolvedSpecID,
        talentRequirements = talentBuildName,
    }

    -- Set up initial visibility arrays based on the resolved category
    if resolvedCategory == "class" and playerClass then
        table.insert(newAction.visibilityEnable, "class:" .. playerClass)
    elseif resolvedCategory == "spec" and resolvedSpecID then
        table.insert(newAction.visibilityEnable, "spec:" .. resolvedSpecID)
    end

    if extraData then
        if extraData.icon then newAction.icon = extraData.icon end
        if extraData.name then newAction.name = extraData.name end
        if extraData.conditions then newAction.conditions = extraData.conditions end
    end
    
    if not slotIndex then
        -- Find next available slot
        slotIndex = 1
        while group.actions[slotIndex] and #group.actions[slotIndex] > 0 do
            slotIndex = slotIndex + 1
        end
    end
    
    -- Ensure slot exists
    if not group.actions[slotIndex] then
        group.actions[slotIndex] = {}
    end
    
    if insertIndex then
        table.insert(group.actions[slotIndex], insertIndex, newAction)
    else
        table.insert(group.actions[slotIndex], newAction)
    end
    
    return slotIndex
end

function Wise:RemoveSlot(groupName, slotIndex)
    local group = WiseDB.groups[groupName]
    if group and group.actions then
        -- Remove the slot
        group.actions[slotIndex] = nil

        -- CooldownWiser: don't shift slots — integer keys are import-stable, decimals are custom
        if group.propertyType == "CooldownWiser" then
            return
        end

        -- Standard groups: shift subsequent slots down to fill the gap
        local maxSlot = 0
        for k in pairs(group.actions) do
            if type(k) == "number" and k > maxSlot then maxSlot = k end
        end

        for i = slotIndex, maxSlot do
            if group.actions[i+1] then
                group.actions[i] = group.actions[i+1]
                group.actions[i+1] = nil
            end
        end
    end
end


function Wise:ReplaceSlotAction(groupName, slotIndex, actionType, actionValue, category, extraData)
    local group = WiseDB.groups[groupName]
    if not group then return end

    Wise:MigrateGroupToActions(group)

    -- Clear existing actions in this slot
    group.actions[slotIndex] = {}

    -- Add the new action as the only action (default priority/state)
    Wise:AddAction(groupName, slotIndex, actionType, actionValue, category, extraData)

    -- Refresh UI
    Wise:UpdateGroupDisplay(groupName)
    Wise:UpdateOptionsUI()
end

function Wise:ReplaceStateAction(groupName, slotIndex, stateIndex, actionType, actionValue, category, extraData)
    local group = WiseDB.groups[groupName]
    if not group then return end

    Wise:MigrateGroupToActions(group)

    if not group.actions[slotIndex] or not group.actions[slotIndex][stateIndex] then return end

    -- Remove the old state and insert the new one at the same position
    table.remove(group.actions[slotIndex], stateIndex)
    Wise:AddAction(groupName, slotIndex, actionType, actionValue, category, extraData, stateIndex)

    -- Refresh UI
    Wise:UpdateGroupDisplay(groupName)
    Wise:UpdateOptionsUI()
end

function Wise:RemoveActionFromSlot(groupName, slotIndex, actionIndex)
    local group = WiseDB.groups[groupName]
    if group and group.actions and group.actions[slotIndex] then
        table.remove(group.actions[slotIndex], actionIndex)
        -- If slot is empty, WE KEEP IT (User Requirement: Explicit Delete only)
        -- if #group.actions[slotIndex] == 0 then
        --      Wise:RemoveSlot(groupName, slotIndex)
        -- end
    end
end

-- ============================================================================
-- Helper Functions (Ported from Action.lua)
-- ============================================================================

function Wise:ResolveMacroData(macroText)
    if not macroText or macroText == "" then return nil, nil, nil end

    local targetLine = nil

    -- Pass 1: Check for #showtooltip or #show
    for line in string.gmatch(macroText, "[^\r\n]+") do
        local clean = strtrim(line)
        if clean:match("^#showtooltip") then
            local args = clean:match("^#showtooltip%s+(.*)")
            if args then
                targetLine = args
                break
            end
            -- If #showtooltip has no args, we fall through to find the first cast/use
        elseif clean:match("^#show") then
            local args = clean:match("^#show%s+(.*)")
            if args then
                targetLine = args
                break
            end
        end
    end

    -- Pass 2: If no explicit #show arg found, find first cast/use
    if not targetLine then
        for line in string.gmatch(macroText, "[^\r\n]+") do
            local clean = strtrim(line)
            local cmd, args = clean:match("^(%S+)%s+(.*)")
            if cmd then
                cmd = string.lower(cmd)
                -- /cast, /use, /castsequence, /randomcast, /castrandom
                if (cmd == "/cast" or cmd == "/use" or cmd == "/castsequence" or cmd == "/randomcast" or cmd == "/castrandom") and args then
                    targetLine = args
                    break
                end
            end
        end
    end

    if not targetLine then return nil, nil, nil end

    -- Evaluate Conditional
    local result = SecureCmdOptionParse(targetLine)
    if not result then return nil, nil, nil end

    -- Resolve Result (Item or Spell?)
    -- Try Spell first (most common)
    local sInfo = C_Spell.GetSpellInfo(result)
    if sInfo then
        return "spell", sInfo.spellID, sInfo.iconID
    end

    -- Try Item
    local iName, iLink, iRarity, iLevel, iMinLevel, iType, iSubType, iStackCount, iEquipLoc, iIcon, iSellPrice, iClassID, iSubClassID, bindType, expacID, iSetID, isCraftingReagent = C_Item.GetItemInfo(result)
    if iIcon then
        local iID = C_Item.GetItemInfoInstant(result) -- Get ID reliably
        return "item", iID, iIcon
    end

    -- Fallback: Check if it's a numeric ID directly
    local id = tonumber(result)
    if id then
       -- Check Spell ID
       sInfo = C_Spell.GetSpellInfo(id)
       if sInfo then return "spell", sInfo.spellID, sInfo.iconID end

       -- Check Item ID
       local icon = C_Item.GetItemIconByID(id)
       if icon then return "item", id, icon end
    end

    return nil, nil, nil
end



function Wise:GetActionName(actionType, value, extraData)
    if extraData and extraData.customName then return extraData.customName end

    -- For spells, always resolve dynamically (overrides change with spec/talents)
    if extraData and extraData.name and actionType ~= "spell" then return extraData.name end

    if actionType == "action" then
        if tonumber(value) then
            local actionTypeStr, id, subType = GetActionInfo(tonumber(value))
            if actionTypeStr == "spell" and id then
                local info = C_Spell.GetSpellInfo(id)
                return info and info.name or "Action " .. value
            elseif actionTypeStr == "item" and id then
                return C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(id) or GetItemInfo(id) or "Action " .. value
            elseif actionTypeStr == "macro" and id then
                return GetMacroInfo(id) or "Action " .. value
            end
            return "Action " .. value
        end
        return "Unknown Action"

    elseif actionType == "spell" then
        local overrideValue = Wise:GetOverrideSpellID(value) or value
        if C_Spell and C_Spell.GetSpellInfo then
             local info = C_Spell.GetSpellInfo(overrideValue)
             return info and info.name or value
        end
        local name = GetSpellInfo(overrideValue)
        return name or value
        
    elseif actionType == "item" or actionType == "toy" or actionType == "equipped" then
        if C_Item and C_Item.GetItemInfo then
             local name = C_Item.GetItemInfo(value)
             return name or value
        end
        local name = GetItemInfo(value)
        return name or value
        
    elseif actionType == "macro" then
        local name = GetMacroInfo(value)
        return name or value
        
    elseif actionType == "raidmarker" then
        local names = {"Star (Unit)", "Circle (Unit)", "Diamond (Unit)", "Triangle (Unit)", "Moon (Unit)", "Square (Unit)", "Cross (Unit)", "Skull (Unit)"}
        return names[value] or "Marker " .. value

    elseif actionType == "worldmarker" then
        local wmNames = {
            [1] = "Square (Ground)",
            [2] = "Triangle (Ground)",
            [3] = "Diamond (Ground)",
            [4] = "Cross (Ground)",
            [5] = "Star (Ground)",
            [6] = "Circle (Ground)",
            [7] = "Moon (Ground)",
            [8] = "Skull (Ground)"
        }
        return wmNames[value] or "Ground Marker " .. value

    elseif actionType == "equipmentset" then
        return value -- Name is the value
        
    elseif actionType == "mount" then
        if C_MountJournal then
            local name = C_MountJournal.GetMountInfoByID(value)
            return name or value
        end
        
    elseif actionType == "battlepet" then
        if C_PetJournal then
             local _, _, _, _, _, _, _, name = C_PetJournal.GetPetInfoByPetID(value)
             return name or value
        end
        
    elseif actionType == "misc" then
        if value == "extrabutton" then return "Extra Button" end
        if value == "zoneability" then return "Zone Ability" end
        if value == "overridebar" then return "Override Bar" end
        if value == "possessbar" then return "Possess Bar" end
        if value == "leave_vehicle" then return "Leave Vehicle" end
        if value == "custom_macro" then return "Custom Macro" end
        if value == "toggle_sound" then return "Toggle Sound" end
        if value == "toggle_sfx" then return "Toggle Sound Effects" end
        if value == "vol_up" then return "Volume Up" end
        if value == "vol_down" then return "Volume Down" end
        if type(value) == "string" and string.sub(value, 1, 12) == "addon_magic_" then
            local slotIdx = tonumber(string.sub(value, 13))
            if slotIdx and WiseDB.addonMagicSlots and WiseDB.addonMagicSlots[slotIdx] then
                return WiseDB.addonMagicSlots[slotIdx].name or ("Slot " .. slotIdx)
            end
            return "AM Slot " .. (slotIdx or "?")
        end
        if type(value) == "string" and string.sub(value, 1, 5) == "spec_" then
            local val = tonumber(string.sub(value, 6))
            if val then
                local name
                if val <= 10 then
                    _, name = GetSpecializationInfo(val)
                else
                    _, name = GetSpecializationInfoByID(val)
                end
                return name or ("Spec " .. val)
            end
        end
        if type(value) == "string" and string.sub(value, 1, 5) == "form_" then
            local formIndex = tonumber(string.sub(value, 6))
            if formIndex then
                local icon, _, _, spellID = GetShapeshiftFormInfo(formIndex)
                if spellID then
                    local info = C_Spell.GetSpellInfo(spellID)
                    if info and info.name then return info.name end
                end
                return "Form " .. formIndex
            end
        end
        if type(value) == "string" and string.sub(value, 1, 9) == "lootspec_" then
            local specID = tonumber(string.sub(value, 10))
            if specID then
                local _, name = GetSpecializationInfoByID(specID)
                return "Loot: " .. (name or specID)
            end
        end
    elseif actionType == "uivisibility" then
        local element, state = string.match(value, "^(.-):(.+)$")
        if element and state then
            local eName = element:gsub("^%l", string.upper)
            if element == "xpbar" then eName = "XP Bar"
            elseif element == "repbar" then eName = "Reputation Bar"
            elseif element == "micromenu" then eName = "Micro Menu"
            elseif element == "minimap" then eName = "Minimap"
            elseif element == "bags" then eName = "Bags Bar"
            end

            local sName = state:gsub("^%l", string.upper)
            return eName .. ": " .. sName
        end
        return value

    elseif actionType == "uipanel" then
        local names = {
            character = "Character",
            spellbook = "Spellbook",
            talents = "Talents",
            specialization = "Specialization",
            collections = "Collections",
            groupfinder = "Group Finder",
            adventureguide = "Adventure Guide",
            achievements = "Achievements",
            guild = "Guild",
            map = "Map",
            menu = "Game Menu",
            shop = "Shop",
            questlog = "Quest Log",
            professions = "Professions",
            housing = "Housing",
            bag_backpack = "Toggle Backpack",
            bag_1 = "Toggle Bag 1",
            bag_2 = "Toggle Bag 2",
            bag_3 = "Toggle Bag 3",
            bag_4 = "Toggle Bag 4",
            bag_reagent = "Toggle Reagent Bag",
            bag_all = "Open All Bags",
            collections_mounts = "Mount Journal",
            collections_pets = "Pet Journal",
            collections_toys = "Toy Box",
            collections_heirlooms = "Heirlooms",
            collections_appearances = "Appearances",
            social = "Social Panel",
            social_friends = "Friends List",
            social_who = "Who",
            social_raid = "Raid",
            pvp = "PVP Panel",
            dungeons = "Dungeons & Raids",
            mythicplus = "Mythic+",
            reputation = "Reputation",
            currency = "Currency",
            statistics = "Statistics",
            map_size = "World Map Size",
            map_zone = "Zone Map",
            map_minimap = "Toggle Minimap",
            garrison = "Garrison Report",
        }
        return names[value] or value
        
    elseif actionType == "interface" then
        return value -- The value is the interface name

    elseif actionType == "empty" then
        return "Empty Slot"
    end
    
    return value
end

function Wise:GetActionIcon(actionType, value, extraData)
    -- For spells, always resolve dynamically (overrides change with spec/talents)
    if extraData and extraData.icon and actionType ~= "spell" then return extraData.icon end

    local texture = 134400 -- Default Question Mark

    if actionType == "action" then
        local aID = tonumber(value)
        if aID then
            local realID = Wise:ResolveBarActionID(aID)
            local icon = GetActionTexture(realID)
            if icon then return icon end
        end
        return 134400

    elseif actionType == "spell" then
        local overrideValue = Wise:GetOverrideSpellID(value) or value
        if C_Spell and C_Spell.GetSpellInfo then
            local spellInfo = C_Spell.GetSpellInfo(overrideValue)
            if spellInfo and spellInfo.iconID then
                texture = spellInfo.iconID
            end
        else
            local _, _, icon = GetSpellInfo(overrideValue)
            if icon then texture = icon end
        end
        
    elseif actionType == "item" or actionType == "toy" or actionType == "equipped" then
        local icon = nil
        if C_Item and C_Item.GetItemIconByID then
             icon = C_Item.GetItemIconByID(value)
        end
        if not icon then
             icon = GetItemIcon(value) 
        end
        if icon then texture = icon end
        
        if actionType == "equipped" and type(value) == "number" and value <= 19 then
             local itemIcon = GetInventoryItemTexture("player", value)
             if itemIcon then texture = itemIcon end
        end

    elseif actionType == "macro" then
        local _, icon = GetMacroInfo(value)
        if icon then texture = icon end
        
    elseif actionType == "mount" then
         if C_MountJournal then
             local name, spellID, icon = C_MountJournal.GetMountInfoByID(value)
             if icon then texture = icon end
         end
         
    elseif actionType == "battlepet" then
        if C_PetJournal then
             local _, _, _, _, _, _, _, _, icon = C_PetJournal.GetPetInfoByPetID(value)
             if icon then texture = icon end
        end
    
    elseif actionType == "equipmentset" then
        if C_EquipmentSet then
            if type(value) == "string" then
                local id = C_EquipmentSet.GetEquipmentSetID(value)
                if id then
                    local _, i = C_EquipmentSet.GetEquipmentSetInfo(id)
                    texture = i
                end
            end
        end
        
    elseif actionType == "raidmarker" then
         texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. value
         
    elseif actionType == "worldmarker" then
         -- Map back from /wm index to the UI-RaidTargetingIcon index for the icon
         -- /wm mapping: 1=Square(6), 2=Triangle(4), 3=Diamond(3), 4=Cross(7), 5=Star(1), 6=Circle(2), 7=Moon(5), 8=Skull(8)
         local iconIndex = value
         if value == 1 then iconIndex = 6
         elseif value == 2 then iconIndex = 4
         elseif value == 3 then iconIndex = 3
         elseif value == 4 then iconIndex = 7
         elseif value == 5 then iconIndex = 1
         elseif value == 6 then iconIndex = 2
         elseif value == 7 then iconIndex = 5
         elseif value == 8 then iconIndex = 8
         end
         texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. iconIndex

    elseif actionType == "uivisibility" then
         -- Generic Icons based on element
         local element = string.match(value, "^(.-):")
         if element == "minimap" then texture = "Interface\\Icons\\INV_Misc_Spyglass_03"
         elseif element == "micromenu" then texture = "Interface\\Icons\\INV_Misc_EngGizmos_17"
         elseif element == "bags" then texture = "Interface\\Icons\\INV_Misc_Bag_08"
         elseif element == "xpbar" then texture = "Interface\\Icons\\Spell_Holy_DivineProvidence"
         elseif element == "repbar" then texture = "Interface\\Icons\\Achievement_Reputation_01"
         elseif element == "chat" then texture = "Interface\\Icons\\Spell_Holy_Silence"
         elseif element == "objectives" then texture = "Interface\\Icons\\INV_Misc_Book_07"
         elseif element == "player" then texture = "Interface\\Icons\\Achievement_Character_Human_Male"
         elseif element == "target" then texture = "Interface\\Icons\\Ability_Hunter_SniperShot"
         elseif element == "buffs" then texture = "Interface\\Icons\\Spell_Holy_WordFortitude"
         elseif element == "debuffs" then texture = "Interface\\Icons\\Spell_Shadow_CurseOfTounges"
         else texture = "Interface\\Icons\\INV_Misc_QuestionMark" end

    elseif actionType == "uipanel" then
         local icons = {
            character="Interface\\Icons\\Achievement_Level_100",
            spellbook="Interface\\Icons\\INV_Misc_Book_09",
            talents="Interface\\Icons\\Ability_Marksmanship",
            specialization="Interface\\Icons\\ClassIcon_Warrior",
            collections="Interface\\Icons\\MountJournalPortrait",
            groupfinder="Interface\\Icons\\INV_Helmet_06",
            adventureguide="Interface\\Icons\\INV_Misc_Book_01",
            achievements="Interface\\Icons\\Achievement_Quests_Completed_01",
            guild="Interface\\Icons\\Achievement_GuildPerk_MassResurrection",
            map="Interface\\Icons\\INV_Misc_Map_01",
            menu="Interface\\Icons\\INV_Misc_EngGizmos_17",
            shop="Interface\\Icons\\WoW_Token01",
            questlog="Interface\\Icons\\INV_Misc_Book_07",
            professions="Interface\\Icons\\Trade_Engineering",
            housing="Interface\\Icons\\Garrison_Building_Storehouse",
            bag_backpack="Interface\\Icons\\INV_Misc_Bag_08",
            bag_1="Interface\\Icons\\INV_Misc_Bag_10_Blue",
            bag_2="Interface\\Icons\\INV_Misc_Bag_10_Green",
            bag_3="Interface\\Icons\\INV_Misc_Bag_10_Red",
            bag_4="Interface\\Icons\\INV_Misc_Bag_10",
            bag_reagent="Interface\\Icons\\INV_Enchant_DustArcane",
            bag_all="Interface\\Icons\\INV_Misc_Bag_17",
            collections_mounts="Interface\\Icons\\MountJournalPortrait",
            collections_pets="Interface\\Icons\\INV_Box_PetCarrier_01",
            collections_toys="Interface\\Icons\\INV_Misc_Toy_10",
            collections_heirlooms="Interface\\Icons\\INV_Misc_Book_01",
            collections_appearances="Interface\\Icons\\INV_Chest_Cloth_17",
            social="Interface\\Icons\\Ability_Warrior_RallyingCry",
            social_friends="Interface\\Icons\\Ability_Warrior_RallyingCry",
            social_who="Interface\\Icons\\INV_Misc_GroupLooking",
            social_raid="Interface\\Icons\\Ability_TrueShot",
            pvp="Interface\\Icons\\Achievement_BG_WinWSG",
            dungeons="Interface\\Icons\\INV_Helmet_06",
            mythicplus="Interface\\Icons\\INV_Relics_Hourglass",
            reputation="Interface\\Icons\\Achievement_Reputation_01",
            currency="Interface\\Icons\\INV_Misc_Coin_01",
            statistics="Interface\\Icons\\Achievement_Quests_Completed_01",
            map_size="Interface\\Icons\\INV_Misc_Map_01",
            map_zone="Interface\\Icons\\INV_Misc_Map02",
            map_minimap="Interface\\Icons\\INV_Misc_Spyglass_03",
            garrison="Interface\\Icons\\Achievement_Garrison_Horde_PVE",
         }
         if icons[value] then texture = icons[value] end

     elseif actionType == "interface" then
          -- Try to get the first icon from the interface
          texture = "Interface\\Icons\\INV_Misc_Folder01" -- Default Folder Icon
          if WiseDB and WiseDB.groups and WiseDB.groups[value] then
              local group = WiseDB.groups[value]
              
              -- Migrate if needed
              if Wise.MigrateGroupToActions then Wise:MigrateGroupToActions(group) end
    
              if group.actions then
                   -- Identify the first valid slot (usually slot 1)
                   -- We need to find the lowest index
                   local slots = {}
                   for k in pairs(group.actions) do
                       if type(k) == "number" then table.insert(slots, k) end
                   end
                   table.sort(slots)
                   
                   for _, slotIdx in ipairs(slots) do
                       local states = group.actions[slotIdx]
                       if states and #states > 0 then
                           -- Filter Valid States (Class/Spec)
                           local validStates = {}
                           validStates.conflictStrategy = states.conflictStrategy
                           for _, state in ipairs(states) do
                               if Wise:IsActionAllowed(state) then
                                   table.insert(validStates, state)
                               end
                           end
                           
                           if #validStates > 0 then
                                -- Evaluate Conditions to find active state
                                local conflictStrategy = validStates.conflictStrategy or "priority"
                                local chosenIdx = 1
                                if Wise.EvaluateSlotConditions then
                                     chosenIdx = Wise:EvaluateSlotConditions(validStates, conflictStrategy, nil)
                                end
                                local actionData = validStates[chosenIdx] or validStates[1]
                                
                                if actionData then
                                     texture = Wise:GetActionIcon(actionData.type, actionData.value, actionData)
                                     break -- Found our icon
                                end
                           end
                       end
                   end
              elseif group.buttons and group.buttons[1] then
                  texture = Wise:GetActionIcon(group.buttons[1].type, group.buttons[1].value)
              end
          end
         
    elseif actionType == "misc" then
        if value == "extrabutton" then
            texture = GetActionTexture(Wise.EXTRA_ACTION_BUTTON_SLOT) or "Interface\\Icons\\Temp"
        end
        if value == "zoneability" then
            local zoneBtn = Wise:GetZoneAbilitySpellButton()
            if zoneBtn and zoneBtn.spellID then
                local info = C_Spell.GetSpellInfo(zoneBtn.spellID)
                if info then texture = info.iconID end
            end
            texture = texture or "Interface\\Icons\\Temp"
        end
        if value == "overridebar" then
            local realID = Wise:ResolveBarActionID(133)
            texture = GetActionTexture(realID) or "Interface\\Icons\\Temp"
        end
        if value == "possessbar" then
            local realID = Wise:ResolveBarActionID(121)
            texture = GetActionTexture(realID) or "Interface\\Icons\\Temp"
        end
        if value == "leave_vehicle" then texture = "Interface\\Vehicles\\UI-Vehicles-Button-Exit-Up" end
        if value == "custom_macro" then texture = 134400 end
        if value == "toggle_sound" then texture = "Interface\\AddOns\\Wise\\Media\\SoundToggle.tga" end
        if value == "toggle_sfx" then texture = "Interface\\AddOns\\Wise\\Media\\SFXToggle.tga" end
        if value == "vol_up" then texture = "Interface\\AddOns\\Wise\\Media\\VolUp.tga" end
        if value == "vol_down" then texture = "Interface\\AddOns\\Wise\\Media\\VolDown.tga" end
        if type(value) == "string" and string.sub(value, 1, 5) == "spec_" then
            local specIndex = tonumber(string.sub(value, 6))
            if specIndex then
                local _, _, _, icon = GetSpecializationInfo(specIndex)
                if icon then texture = icon end
            end
        end
        if type(value) == "string" and string.sub(value, 1, 5) == "form_" then
            local formIndex = tonumber(string.sub(value, 6))
            if formIndex then
                local icon = GetShapeshiftFormInfo(formIndex)
                if icon then texture = icon end
            end
        end
        if type(value) == "string" and string.sub(value, 1, 9) == "lootspec_" then
            local specID = tonumber(string.sub(value, 10))
            if specID then
                local _, _, _, icon = GetSpecializationInfoByID(specID)
                if icon then texture = icon end
            end
        end
    elseif actionType == "icon" then
         texture = value

    elseif actionType == "empty" then
         return nil
    end
    
    return texture
end

function Wise:IsActionKnown(actionType, value)
    if actionType == "spell" then
        local spellID = value
        if type(value) == "string" then
            if C_Spell and C_Spell.GetSpellInfo then
                local spellInfo = C_Spell.GetSpellInfo(value)
                if spellInfo then spellID = spellInfo.spellID else return false end
            else
                local _, _, _, _, _, _, id = GetSpellInfo(value)
                if id then spellID = id else return false end
            end
        end
        if not spellID or type(spellID) ~= "number" then return false end

        -- Also resolve the override of the stored spellID (e.g. skyriding talent → active spell)
        local storedOverride = Wise:GetOverrideSpellID(spellID)

        local currentSpec = GetSpecialization()
        local currentSpecID = currentSpec and GetSpecializationInfo(currentSpec) or nil

        if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
            local numSkillLines = C_SpellBook.GetNumSpellBookSkillLines()
            for i = 1, numSkillLines do
                local info = C_SpellBook.GetSpellBookSkillLineInfo(i)
                if info then
                    local lineSpecID = info.specID
                    if (not lineSpecID) or (lineSpecID == currentSpecID) then
                        local offset = info.itemIndexOffset
                        local count = info.numSpellBookItems
                        for j = 1, count do
                            local index = offset + j
                            local spellType, bookSpellID = C_SpellBook.GetSpellBookItemType(index, Enum.SpellBookSpellBank.Player)
                            if spellType == Enum.SpellBookItemType.Spell then
                                -- Check both direct match and override match (e.g. Maul -> Raze)
                                local overrideID = Wise:GetOverrideSpellID(bookSpellID)
                                if (bookSpellID == spellID or overrideID == spellID
                                    or (storedOverride and (bookSpellID == storedOverride or overrideID == storedOverride))) then
                                    if not C_Spell.IsSpellPassive(bookSpellID) then return true end
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Check both original and override spell IDs
        if IsPlayerSpell and type(spellID) == "number" then
            if IsPlayerSpell(spellID) then return true end
            if storedOverride and storedOverride ~= spellID and IsPlayerSpell(storedOverride) then return true end
        end
        return false
        
    elseif actionType == "item" then
        if type(value) == "number" or type(value) == "string" then
            local count = GetItemCount(value, true)
            return count and count > 0
        end
    
    elseif actionType == "toy" then
        local toyID = tonumber(value)
        if not toyID then return false end
        -- Must be collected first
        if PlayerHasToy and not PlayerHasToy(toyID) then return false end
        -- Check profession/faction/class restrictions
        if C_ToyBox and C_ToyBox.IsToyUsable then
            return C_ToyBox.IsToyUsable(toyID)
        end
        -- API unavailable, fall back to collected-only check
        return PlayerHasToy and PlayerHasToy(toyID) or false
        
    elseif actionType == "mount" then
        if C_MountJournal then
            local _, _, _, _, _, _, _, _, _, _, isCollected = C_MountJournal.GetMountInfoByID(value)
            return isCollected or false
        end
        
    elseif actionType == "battlepet" then
        if C_PetJournal then
            local speciesID = C_PetJournal.GetPetInfoByPetID(value)
            return speciesID ~= nil
        end
        
    elseif actionType == "macro" then
        if type(value) == "string" and string.sub(value, 1, 1) == "/" then return true end
        return GetMacroInfo(value) ~= nil
        
    elseif actionType == "equipmentset" then
        if C_EquipmentSet then return C_EquipmentSet.GetEquipmentSetID(value) ~= nil end
    
    elseif actionType == "equipped" then
        return GetInventoryItemID("player", value) ~= nil
        
    elseif actionType == "raidmarker" or actionType == "worldmarker" or actionType == "uipanel" then
        return true

    elseif actionType == "misc" then
        -- For dynamic groups, these misc sub-types have knowable availability.
        -- HasExtraActionBar() checks if the bar is currently active, not just if the slot has data.
        -- HasAction() retains stale data after the bar disappears, so we can't use it here.
        if value == "extrabutton" then
            return HasExtraActionBar and HasExtraActionBar() or false
        elseif value == "zoneability" then
            local zoneFrame = _G["ZoneAbilityFrame"]
            if not zoneFrame or not zoneFrame.SpellButtonContainer then return false end
            local children = { zoneFrame.SpellButtonContainer:GetChildren() }
            for _, child in ipairs(children) do
                if child.spellID and child:IsShown() then return true end
            end
            return false
        elseif value == "overridebar" then
            return HasOverrideActionBar and HasOverrideActionBar() or false
        elseif value == "possessbar" then
            return (HasTempShapeshiftActionBar and HasTempShapeshiftActionBar()) or (HasVehicleActionBar and HasVehicleActionBar()) or false
        end
        return true
        
    elseif actionType == "interface" then
        return WiseDB and WiseDB.groups and WiseDB.groups[value] ~= nil

    elseif actionType == "action" then
        return tonumber(value) and HasAction(tonumber(value)) or true

    elseif actionType == "empty" then
        return true
    end
    
    return true
end

-- Check if an action is currently on cooldown (> 1.5s remaining to ignore GCD)
-- Uses pcall for comparisons because cooldown API return values can be tainted
-- if earlier addon code touched protected state.
function Wise:IsActionOnCooldown(actionType, value, actionData)
    if actionType == "spell" then
        local spellID = value
        if type(value) == "string" then
            local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(value)
            if info then spellID = info.spellID end
        end
        spellID = tonumber(spellID)
        if spellID then
            local overrideID = Wise:GetOverrideSpellID(spellID)
            local checkID = overrideID or spellID
            local info = C_Spell.GetSpellCooldown(checkID)
            if info then
                local ok, onCD = pcall(function()
                    if info.duration and info.duration > 1.5 then
                        local remaining = (info.startTime + info.duration) - GetTime()
                        return remaining > 1.5
                    end
                    return false
                end)
                if ok and onCD then return true end
            end
        end
    elseif actionType == "item" then
        local itemID = tonumber(value)
        if itemID then
            local start, duration = C_Item.GetItemCooldown(itemID)
            local ok, onCD = pcall(function()
                if duration and duration > 1.5 then
                    local remaining = (start + duration) - GetTime()
                    return remaining > 1.5
                end
                return false
            end)
            if ok and onCD then return true end
        end
    elseif actionType == "toy" then
        local toyID = tonumber(value)
        if toyID then
            local start, duration = C_Item.GetItemCooldown(toyID)
            local ok, onCD = pcall(function()
                if duration and duration > 1.5 then
                    local remaining = (start + duration) - GetTime()
                    return remaining > 1.5
                end
                return false
            end)
            if ok and onCD then return true end
        end
    elseif actionType == "mount" then
        -- Mounts don't have meaningful cooldowns to filter on
        return false
    end
    return false
end

function Wise:GetCastTimeText(actionType, value)
    local spellID

    if actionType == "spell" then
        -- Resolve overrides for accurate cast time (e.g. Maul -> Raze)
        local resolvedValue = Wise:GetOverrideSpellID(value) or value
        if type(resolvedValue) == "number" then
            spellID = resolvedValue
        elseif type(resolvedValue) == "string" and C_Spell and C_Spell.GetSpellInfo then
             local info = C_Spell.GetSpellInfo(resolvedValue)
             if info then spellID = info.spellID end
        end
    elseif actionType == "item" or actionType == "toy" then
        local itemID = tonumber(value)
        if itemID then
             local _, sID = GetItemSpell(itemID)
             if sID then spellID = sID end
             -- Fallback to C_Item if available
             if not spellID and C_Item and C_Item.GetItemSpell then
                 local res = C_Item.GetItemSpell(itemID)
                 if res and res.spellID then spellID = res.spellID end
             end
        end
    elseif actionType == "equipped" then
        local slotID = value
        local itemID = GetInventoryItemID("player", slotID)
        if itemID then
             local _, sID = GetItemSpell(itemID)
             if sID then spellID = sID end
        end
    elseif actionType == "mount" then
        if C_MountJournal then
            local _, sID = C_MountJournal.GetMountInfoByID(value)
            if sID then spellID = sID end
        end
    end

    if not spellID then
        -- Macros (target, focus, stopcasting, etc.) never trigger the GCD
        if actionType == "macro" then
            return "Inst", "Off-GCD", true
        end
        -- Items/equipped/toys without a resolvable spell (trinkets, engineering tools, etc.)
        -- are typically off-GCD on-use effects
        if actionType == "item" or actionType == "toy" or actionType == "equipped" then
            return nil, "Off-GCD", true
        end
        return nil, nil, false
    end

    local info = C_Spell.GetSpellInfo(spellID)
    if not info then return nil, nil, false end

    local castTime = info.castTime
    local gcdMS = 0
    if GetSpellBaseCooldown then
        local _cdMS, _gcdMS = GetSpellBaseCooldown(spellID)
        gcdMS = _gcdMS or 0
    end

    -- Format Cast Time
    local castText
    if castTime == 0 then
        castText = "Inst"
    else
        castText = string.format("%.1fs", castTime / 1000)
    end

    -- Format GCD
    local gcdText
    local isOffGCD = false

    -- Items, toys, and equipped slots are always treated as off-GCD for stacking purposes.
    -- In WoW macros, /use lines (especially conditional ones) don't block subsequent /cast lines.
    if actionType == "item" or actionType == "toy" or actionType == "equipped" then
        isOffGCD = true
    end

    if not gcdMS or gcdMS == 0 or gcdMS < 10 then -- Tolerance for tiny dummy values
        gcdText = "Off-GCD"
        isOffGCD = true
    else
        gcdText = string.format("%.1fs", gcdMS / 1000)
    end

    return castText, gcdText, isOffGCD
end

function Wise:CreateCastReadout(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(1, 20) -- Width will be set dynamically in SetCastReadout

    f.CastTime = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.CastTime:SetTextColor(0.5, 0.5, 0.5)
    f.CastTime:SetJustifyH("RIGHT")

    f.Sep = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.Sep:SetTextColor(0.5, 0.5, 0.5)
    f.Sep:SetText("/")

    f.GCDTime = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.GCDTime:SetTextColor(0.5, 0.5, 0.5)
    f.GCDTime:SetJustifyH("LEFT")

    f.Strike = f:CreateTexture(nil, "OVERLAY")
    f.Strike:SetColorTexture(0.5, 0.5, 0.5, 0.8)
    f.Strike:SetHeight(1)
    f.Strike:SetPoint("LEFT", f.GCDTime, "LEFT", -1, 0)
    f.Strike:SetPoint("RIGHT", f.GCDTime, "RIGHT", 1, 0)
    f.Strike:Hide()

    return f
end

function Wise:SetCastReadout(f, actionType, value, groupName)
    local castText, gcdText, isOffGCD = Wise:GetCastTimeText(actionType, value)

    local showGCD = true
    if Wise.GetGroupDisplaySettings then
         local _, _, _, _, _, _, _, _, _, _, _, _, _, sGCD = Wise:GetGroupDisplaySettings(groupName)
         if sGCD ~= nil then showGCD = sGCD end
    elseif WiseDB and WiseDB.settings then
         if WiseDB.settings.showGCD ~= nil then showGCD = WiseDB.settings.showGCD end
    end

    if castText then
        f:Show()
        f.CastTime:SetText(castText)
        f.CastTime:Show()

        if showGCD and gcdText then
            f.GCDTime:SetText(gcdText)
            f.GCDTime:Show()
            f.Sep:Show()
            if isOffGCD then f.Strike:Show() else f.Strike:Hide() end

            -- Measure text widths and size the frame to fit
            local castW = f.CastTime:GetStringWidth() or 20
            local sepW = f.Sep:GetStringWidth() or 5
            local gcdW = f.GCDTime:GetStringWidth() or 20
            local totalW = castW + 4 + sepW + 4 + gcdW
            f:SetWidth(totalW)

            -- Layout: CastTime | Sep | GCDTime, all inside the frame
            f.CastTime:ClearAllPoints()
            f.CastTime:SetPoint("LEFT", f, "LEFT", 0, 0)
            f.Sep:ClearAllPoints()
            f.Sep:SetPoint("LEFT", f.CastTime, "RIGHT", 4, 0)
            f.GCDTime:ClearAllPoints()
            f.GCDTime:SetPoint("LEFT", f.Sep, "RIGHT", 4, 0)
        else
            f.GCDTime:Hide()
            f.Strike:Hide()
            f.Sep:Hide()

            local castW = f.CastTime:GetStringWidth() or 20
            f:SetWidth(castW)

            f.CastTime:ClearAllPoints()
            f.CastTime:SetPoint("RIGHT", f, "RIGHT", 0, 0)
        end

        return true
    else
        f:Hide()
        return false
    end
end

-- ============================================================================
-- Picker UI (Ported from Picker.lua)
-- ============================================================================

function Wise:CreateEmbeddedPicker(parent)
    local ep = Wise.EmbeddedPicker

    -- If picker elements already exist and are parented to this container, just show them
    if ep and ep.parent == parent then
        ep.CategoryBtn:Show()
        ep.FilterFrame:Show()
        ep.Search:Show()
        ep.Scroll:Show()
        ep.CancelBtn:Show()
        Wise:PickerSelectCategory(Wise.PickerCurrentCategory or "Spell")
        return
    end

    -- Build new picker UI into parent
    ep = {}
    ep.parent = parent

    -- Cancel / Back button
    ep.CancelBtn = CreateFrame("Button", nil, parent, "GameMenuButtonTemplate")
    ep.CancelBtn:SetSize(80, 22)
    ep.CancelBtn:SetPoint("TOPLEFT", 10, -20)
    ep.CancelBtn:SetText("< Back")
    ep.CancelBtn:SetScript("OnClick", function()
        Wise.pickingAction = false
        Wise:RefreshPropertiesPanel()
    end)
    tinsert(parent.controls, ep.CancelBtn)

    -- Category dropdown button
    ep.CategoryBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    ep.CategoryBtn:SetHeight(24) -- Match standard height
    -- ep.CategoryBtn:SetWidth(200) -- Rmoved fixed width
    ep.CategoryBtn:SetPoint("LEFT", ep.CancelBtn, "RIGHT", 10, 0)
    ep.CategoryBtn:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    
    ep.CategoryBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    ep.CategoryBtn:SetBackdropColor(0.15, 0.15, 0.15, 1)
    ep.CategoryBtn:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    tinsert(parent.controls, ep.CategoryBtn)

    ep.CategoryLabel = ep.CategoryBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ep.CategoryLabel:SetPoint("LEFT", 10, 0)
    ep.CategoryLabel:SetText("Spell")

    local arrow = ep.CategoryBtn:CreateTexture(nil, "OVERLAY")
    arrow:SetSize(16, 16)
    arrow:SetPoint("RIGHT", -5, 0)
    arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")

    -- Category dropdown menu
    ep.CategoryMenu = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    ep.CategoryMenu:SetPoint("TOPLEFT", ep.CategoryBtn, "BOTTOMLEFT", 0, 0)
    ep.CategoryMenu:SetPoint("TOPRIGHT", ep.CategoryBtn, "BOTTOMRIGHT", 0, 0)
    ep.CategoryMenu:SetFrameLevel(parent:GetFrameLevel() + 20)
    ep.CategoryMenu:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    ep.CategoryMenu:SetBackdropColor(0.15, 0.15, 0.15, 1)
    ep.CategoryMenu:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    ep.CategoryMenu:Hide()
    tinsert(parent.controls, ep.CategoryMenu)

    local categories = {
        "Spell", "Items", "Equipped", "Battle pets", "Mounts", "Macros",
        "Equipment sets", "Raid markers", "Toys", "UI panel", "UI Visibility", "Skyriding",
        "Professions", "Interface", "DataBroker", "Miscellaneous", "Override bars", "Transportation"
    }

    local prevItem
    for _, cat in ipairs(categories) do
        local btn = CreateFrame("Button", nil, ep.CategoryMenu)
        btn:SetHeight(20)
        -- Width will be set dynamically or anchored to left/right
        btn:SetPoint("LEFT", 6, 0)
        btn:SetPoint("RIGHT", -6, 0)
        
        if prevItem then
            btn:SetPoint("TOP", prevItem, "BOTTOM", 0, 0)
        else
            btn:SetPoint("TOP", 0, -6)
        end
        local catText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        catText:SetPoint("LEFT", 4, 0)
        catText:SetText(cat)

        btn:SetScript("OnEnter", function() catText:SetTextColor(1, 0.8, 0) end)
        btn:SetScript("OnLeave", function() catText:SetTextColor(1, 1, 1) end)
        btn:SetScript("OnClick", function()
            Wise:PickerSelectCategory(cat)
            ep.CategoryMenu:Hide()
        end)
        prevItem = btn
    end
    ep.CategoryMenu:SetHeight(#categories * 20 + 12)

    ep.CategoryBtn:SetScript("OnClick", function()
        if ep.CategoryMenu:IsShown() then ep.CategoryMenu:Hide() else ep.CategoryMenu:Show() end
    end)

    -- Filter frame (shared by spell filters and collection filters)
    ep.FilterFrame = CreateFrame("Frame", nil, parent)
    ep.FilterFrame:SetSize(220, 24)
    ep.FilterFrame:SetPoint("TOPLEFT", ep.CancelBtn, "BOTTOMLEFT", 0, -8)
    tinsert(parent.controls, ep.FilterFrame)

    -- Spell filter buttons: In-Spec / Off-Spec / Global
    ep.SpellFilterButtons = {}
    local spellFilters = {"In-Spec", "Off-Spec", "Global"}
    local filterX = 0
    for _, filterName in ipairs(spellFilters) do
        local filterBtn = CreateFrame("Button", nil, ep.FilterFrame, "BackdropTemplate")
        filterBtn:SetSize(68, 22)
        filterBtn:SetPoint("LEFT", filterX, 0)
        filterBtn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })

        filterBtn.label = filterBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        filterBtn.label:SetPoint("CENTER")
        filterBtn.label:SetText(filterName)

        filterBtn.filterName = filterName
        filterBtn:SetScript("OnClick", function(self)
            Wise.PickerSpellFilter = self.filterName
            Wise:UpdatePickerFilterButtons()
            Wise:PickerRefresh(ep.Search:GetText())
        end)

        ep.SpellFilterButtons[filterName] = filterBtn
        filterX = filterX + 70
    end

    -- Collection filter buttons: All / Favorites
    ep.CollectionFilterButtons = {}
    local collFilters = {"All", "Favorites"}
    filterX = 0
    for _, filterName in ipairs(collFilters) do
        local filterBtn = CreateFrame("Button", nil, ep.FilterFrame, "BackdropTemplate")
        filterBtn:SetSize(80, 22)
        filterBtn:SetPoint("LEFT", filterX, 0)
        filterBtn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })

        filterBtn.label = filterBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        filterBtn.label:SetPoint("CENTER")
        filterBtn.label:SetText(filterName)

        filterBtn.filterName = filterName
        filterBtn:SetScript("OnClick", function(self)
            Wise.PickerCollectionFilter = self.filterName
            Wise:UpdatePickerFilterButtons()
            Wise:PickerRefresh(ep.Search:GetText())
        end)

        ep.CollectionFilterButtons[filterName] = filterBtn
        filterX = filterX + 82
    end

    -- Macro filter buttons: All / Global / Character
    ep.MacroFilterButtons = {}
    local macroFilters = {"All", "Global", "Character"}
    filterX = 0
    for _, filterName in ipairs(macroFilters) do
        local filterBtn = CreateFrame("Button", nil, ep.FilterFrame, "BackdropTemplate")
        filterBtn:SetSize(80, 22)
        filterBtn:SetPoint("LEFT", filterX, 0)
        filterBtn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })

        filterBtn.label = filterBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        filterBtn.label:SetPoint("CENTER")
        filterBtn.label:SetText(filterName)

        filterBtn.filterName = filterName
        filterBtn:SetScript("OnClick", function(self)
            Wise.PickerMacroFilter = self.filterName
            Wise:UpdatePickerFilterButtons()
            Wise:PickerRefresh(ep.Search:GetText())
        end)

        ep.MacroFilterButtons[filterName] = filterBtn
        filterX = filterX + 82
    end

    -- Search box
    ep.Search = CreateFrame("EditBox", nil, parent, "SearchBoxTemplate")
    ep.Search:SetHeight(20)
    -- ep.Search:SetSize(210, 20) -- Width dynamic now
    ep.Search:SetPoint("TOPLEFT", ep.FilterFrame, "BOTTOMLEFT", 5, -6) -- Indent slightly for search icon? Standard SearchBox has inset.
    -- Actually standard SearchBoxTemplate usually usually needs some width.
    -- Let's stick to sticking to left. 
    -- The SearchBoxTemplate has the magnifying glass on the left.
    -- If we align TOPLEFT to FilterFrame BOTTOMLEFT, it should be fine.
    
    -- Correction: SearchBoxTemplate texture often extends a bit. 
    -- Let's just use 0,-6.
    ep.Search:SetPoint("TOPLEFT", ep.FilterFrame, "BOTTOMLEFT", 0, -4) 
    ep.Search:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    
    local function UpdateSearchInstructions(self)
        local instr = self.Instructions
        if not instr then
            for _, region in ipairs({self:GetRegions()}) do
                if region:IsObjectType("FontString") and (region:GetText() == SEARCH or region:GetText() == "Search") then
                    instr = region
                    self.Instructions = region
                    break
                end
            end
        end
        if instr then
            instr:SetShown(self:GetText() == "")
        end
    end

    ep.Search:HookScript("OnTextChanged", function(self)
        UpdateSearchInstructions(self)
        Wise:PickerRefresh(self:GetText())
    end)

    ep.Search:HookScript("OnEditFocusGained", function(self)
        UpdateSearchInstructions(self)
    end)

    ep.Search:HookScript("OnEditFocusLost", function(self)
        UpdateSearchInstructions(self)
    end)

    UpdateSearchInstructions(ep.Search)
    tinsert(parent.controls, ep.Search)

    -- Scroll list
    ep.Scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    ep.Scroll:SetPoint("TOPLEFT", ep.Search, "BOTTOMLEFT", 0, -4)
    ep.Scroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -25, 10)
    tinsert(parent.controls, ep.Scroll)

    ep.Content = CreateFrame("Frame", nil, ep.Scroll)
    ep.Content:SetSize(200, 400)
    ep.Scroll:SetScrollChild(ep.Content)

    Wise.EmbeddedPicker = ep
    Wise.PickerSpellFilter = Wise.PickerSpellFilter or "In-Spec"
    Wise.PickerCollectionFilter = Wise.PickerCollectionFilter or "All"
    Wise.PickerMacroFilter = Wise.PickerMacroFilter or "All"

    Wise:PickerSelectCategory("Spell")
end

function Wise:UpdatePickerFilterButtons()
    local ep = Wise.EmbeddedPicker
    if not ep then return end

    -- Spell filter buttons
    for filterName, btn in pairs(ep.SpellFilterButtons) do
        if filterName == Wise.PickerSpellFilter then
            btn:SetBackdropColor(0.2, 0.5, 0.8, 1)
            btn.label:SetTextColor(1, 1, 1)
        else
            btn:SetBackdropColor(0.15, 0.15, 0.15, 1)
            btn.label:SetTextColor(0.7, 0.7, 0.7)
        end
    end

    -- Collection filter buttons
    for filterName, btn in pairs(ep.CollectionFilterButtons) do
        if filterName == Wise.PickerCollectionFilter then
            btn:SetBackdropColor(0.2, 0.5, 0.8, 1)
            btn.label:SetTextColor(1, 1, 1)
        else
            btn:SetBackdropColor(0.15, 0.15, 0.15, 1)
            btn.label:SetTextColor(0.7, 0.7, 0.7)
        end
    end

    -- Macro filter buttons
    for filterName, btn in pairs(ep.MacroFilterButtons) do
        if filterName == Wise.PickerMacroFilter then
            btn:SetBackdropColor(0.2, 0.5, 0.8, 1)
            btn.label:SetTextColor(1, 1, 1)
        else
            btn:SetBackdropColor(0.15, 0.15, 0.15, 1)
            btn.label:SetTextColor(0.7, 0.7, 0.7)
        end
    end
end

function Wise:OpenPicker(callback)
    Wise.pickingAction = true
    Wise.PickerCallback = callback
    Wise.PickerCurrentCategory = "Spell"
    Wise:RefreshPropertiesPanel()
end

function Wise:PickerSelectCategory(catName)
    Wise.PickerCurrentCategory = catName
    local ep = Wise.EmbeddedPicker
    if not ep then return end

    if ep.CategoryLabel then
        ep.CategoryLabel:SetText(catName)
    end

    -- Show/hide appropriate filter buttons
    local isSpell = (catName == "Spell")
    local isCollection = (catName == "Mounts" or catName == "Battle pets" or catName == "Toys")
    local isMacro = (catName == "Macros")

    for _, btn in pairs(ep.SpellFilterButtons) do
        if isSpell then btn:Show() else btn:Hide() end
    end
    for _, btn in pairs(ep.CollectionFilterButtons) do
        if isCollection then btn:Show() else btn:Hide() end
    end
    for _, btn in pairs(ep.MacroFilterButtons) do
        if isMacro then btn:Show() else btn:Hide() end
    end

    if isSpell then
        ep.FilterFrame:SetSize(220, 24)
        Wise:UpdatePickerFilterButtons()
    elseif isCollection then
        ep.FilterFrame:SetSize(170, 24)
        Wise.PickerCollectionFilter = Wise.PickerCollectionFilter or "All"
        Wise:UpdatePickerFilterButtons()
    elseif isMacro then
        ep.FilterFrame:SetSize(250, 24)
        Wise.PickerMacroFilter = Wise.PickerMacroFilter or "All"
        Wise:UpdatePickerFilterButtons()
    else
        ep.FilterFrame:SetSize(220, 1)
    end

    Wise:PickerRefresh(ep.Search and ep.Search:GetText() or "")
    if ep.Scroll then ep.Scroll:SetVerticalScroll(0) end
end

function Wise:PickerRefresh(filter)
    local ep = Wise.EmbeddedPicker
    if not ep or not ep.Content then return end

    local container = ep.Content
    filter = filter and filter ~= "" and string.lower(filter) or nil

    if container.buttons then
         for _, btn in pairs(container.buttons) do btn:Hide() end
    else
         container.buttons = {}
    end

    local items = {}
    local catKey = string.gsub(Wise.PickerCurrentCategory, " ", "")
    local method = Wise["Get" .. catKey]
    if method then
        local favoritesOnly = (Wise.PickerCollectionFilter == "Favorites")
        local macroCategory = (Wise.PickerMacroFilter or "All")
        if catKey == "Macros" then
             items = method(Wise, filter, macroCategory)
        else
             items = method(Wise, filter, favoritesOnly)
        end
    end

    local btnHeight = 32
    local btnWidth = container:GetParent():GetWidth() - 20
    if btnWidth < 100 then btnWidth = 200 end
    local padding = 2
    local y = 0

    for i, data in ipairs(items) do
        local btn = container.buttons[i]
        if not btn then
            btn = CreateFrame("Button", nil, container, "BackdropTemplate")
            btn:SetSize(btnWidth, btnHeight)

            btn.iconFrame = CreateFrame("Button", nil, btn)
            btn.iconFrame:SetSize(24, 24)
            btn.iconFrame:SetPoint("LEFT", 4, 0)
            btn.iconFrame:EnableMouse(false)

            btn.icon = btn.iconFrame:CreateTexture(nil, "ARTWORK")
            btn.icon:SetAllPoints()
            btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            if Wise.MasqueGroup then
                Wise.MasqueGroup:AddButton(btn.iconFrame, { Icon = btn.icon })
            end

            btn.castReadout = Wise:CreateCastReadout(btn)
            btn.castReadout:SetPoint("RIGHT", -10, 0)

            btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            btn.label:SetPoint("LEFT", btn.iconFrame, "RIGHT", 8, 0)
            btn.label:SetPoint("RIGHT", -4, 0)
            btn.label:SetJustifyH("LEFT")

            btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

            btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if self.data.tooltipFunc then
                    self.data.tooltipFunc(self.data.value)
                elseif self.data.type == "spell" then
                    local tooltipID = Wise:GetOverrideSpellID(self.data.value) or self.data.value
                    GameTooltip:SetSpellByID(tooltipID)
                elseif self.data.type == "item" or self.data.type == "toy" then
                    GameTooltip:SetItemByID(self.data.value)
                else
                    GameTooltip:SetText(self.data.name)
                end
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            btn:SetScript("OnClick", function(self)
                if Wise.PickerCallback then
                    local extra = {}
                    if self.data.icon then extra.icon = self.data.icon end
                    if self.data.name then extra.name = self.data.name end
                    if self.data.category then extra.category = self.data.category end
                    if self.data.sourceSpecID then extra.sourceSpecID = self.data.sourceSpecID end
                    if self.data.conditions then extra.conditions = self.data.conditions end
                    Wise.PickerCallback(self.data.type, self.data.value, extra)
                end
                Wise.pickingAction = false
                Wise:RefreshPropertiesPanel()
            end)

            table.insert(container.buttons, btn)
        end

        btn:SetSize(btnWidth, btnHeight)
        btn:Show()
        btn.data = data
        btn.icon:SetTexture(data.icon)
        btn.label:SetText(data.name or "Unknown")

        local hasReadout = Wise:SetCastReadout(btn.castReadout, data.type, data.value, Wise.selectedGroup)
        btn.label:ClearAllPoints()
        btn.label:SetPoint("LEFT", btn.iconFrame, "RIGHT", 8, 0)
        if hasReadout then
            btn.castReadout:ClearAllPoints()
            btn.castReadout:SetPoint("RIGHT", -10, 0)
            btn.label:SetPoint("RIGHT", btn.castReadout, "LEFT", -4, 0)
        else
            btn.castReadout:Hide()
            btn.label:SetPoint("RIGHT", -4, 0)
        end

        btn:SetPoint("TOPLEFT", 0, -y)
        y = y + btnHeight + padding
    end

    container:SetHeight(math.max(y, 10))
end


-- ============================================================================
-- Picker Data Sources (Ported from Picker.lua)
-- ============================================================================
-- NOTE: I am abbreviating these slightly for brevity if they are identical, 
-- but I will copy the logic 1:1.

function Wise:GetSpell(filter)
    local spells = {}
    local seen = {}
    local currentSpec = GetSpecialization()
    local currentSpecID = currentSpec and GetSpecializationInfo(currentSpec) or nil
    
    local numSkillLines = C_SpellBook.GetNumSpellBookSkillLines()
    for i = 1, numSkillLines do
        local info = C_SpellBook.GetSpellBookSkillLineInfo(i)
        if info then
            local offset = info.itemIndexOffset
            local count = info.numSpellBookItems
            local skillLineName = info.name
            local specID = info.specID
            
            local displayCategory = "Global"
            local realCategory = "global"
            local sourceSpecID = nil

            if specID and specID == currentSpecID then
                displayCategory = "In-Spec"
                realCategory = "spec"
                sourceSpecID = specID
            elseif specID and specID ~= currentSpecID then
                displayCategory = "Off-Spec"
                realCategory = "spec"
                sourceSpecID = specID
            elseif skillLineName == "General" or skillLineName == "Warbands" then
                displayCategory = "Global"
                realCategory = "global"
            else
                -- Class Spells (No SpecID, not General)
                -- We show them in "In-Spec" list because they are usable by current spec
                displayCategory = "In-Spec"
                realCategory = "class"
            end
            
            local showSpell = false
            if Wise.PickerSpellFilter == displayCategory then showSpell = true end
            
            if showSpell then
                for j = 1, count do
                    local index = offset + j
                    local spellType, spellId = C_SpellBook.GetSpellBookItemType(index, Enum.SpellBookSpellBank.Player)
                    if spellType == Enum.SpellBookItemType.Spell then
                         if not C_Spell.IsSpellPassive(spellId) then
                             -- Resolve spell overrides for display (e.g. Maul -> Raze)
                             local displayId = Wise:GetOverrideSpellID(spellId) or spellId
                             local name = C_Spell.GetSpellName(displayId)
                             local icon = C_Spell.GetSpellTexture(displayId)
                             local description = C_Spell.GetSpellDescription(displayId) or ""
                             if name and (not filter or string.find(string.lower(name), filter, 1, true) or string.find(string.lower(description), filter, 1, true)) then
                                 if not seen[name] then
                                     table.insert(spells, {
                                         type="spell",
                                         value=spellId,  -- Store base ID; overrides resolved dynamically
                                         name=name,
                                         icon=icon,
                                         category=realCategory,
                                         sourceSpecID=sourceSpecID
                                     })
                                     seen[name] = true
                                 end
                             end
                         end
                    elseif spellType == Enum.SpellBookItemType.Flyout then
                         local flyoutID = spellId
                         local _, _, numSlots, isKnown = GetFlyoutInfo(flyoutID)
                         if isKnown and numSlots > 0 then
                              for s = 1, numSlots do
                                   local flyoutSpellID, overrideSpellID, isKnownSlot = GetFlyoutSlotInfo(flyoutID, s)
                                   if isKnownSlot and flyoutSpellID then
                                        local actualSpellID = overrideSpellID or flyoutSpellID
                                        if not C_Spell.IsSpellPassive(actualSpellID) then
                                             local sName = C_Spell.GetSpellName(actualSpellID)
                                             local sIcon = C_Spell.GetSpellTexture(actualSpellID)
                                             local description = C_Spell.GetSpellDescription(actualSpellID) or ""
                                             if sName and (not filter or string.find(string.lower(sName), filter, 1, true) or string.find(string.lower(description), filter, 1, true)) then
                                                  if not seen[sName] then
                                                       table.insert(spells, {
                                                            type="spell",
                                                            value=actualSpellID,
                                                            name=sName,
                                                            icon=sIcon,
                                                            category=realCategory,
                                                            sourceSpecID=sourceSpecID
                                                       })
                                                       seen[sName] = true
                                                  end
                                             end
                                        end
                                   end
                              end
                         end
                    end
                end
            end
        end
    end

    
    -- Class-specific hidden/replacement spells
    local _, playerClass = UnitClass("player")
    local classSpells = {
        PALADIN = {
            427453 -- Hammer of Light
        }
    }

    if classSpells[playerClass] and (Wise.PickerSpellFilter == "In-Spec" or Wise.PickerSpellFilter == "Global") then
        for _, spellName in ipairs(classSpells[playerClass]) do
            if not seen[spellName] then
                local info = C_Spell.GetSpellInfo(spellName)
                if info then
                    if not filter or string.find(string.lower(info.name), filter, 1, true) then
                        table.insert(spells, {
                            type="spell",
                            value=info.spellID,
                            name=info.name,
                            icon=info.iconID,
                            category="class"
                        })
                        seen[spellName] = true
                    end
                end
            end
        end
    end

    -- Manual Exclusions/Inclusions
    if Wise.PickerSpellFilter == "Global" then
        -- Assist (often missed by spellbook iterators)
        if not seen["Assist"] then
             local info = C_Spell.GetSpellInfo("Assist")
             if info then
                table.insert(spells, {type="spell", value="Assist", name=info.name, icon=info.iconID, category="global"})
                seen["Assist"] = true
             end
        end
        -- Attack
        if not seen["Attack"] then
             local info = C_Spell.GetSpellInfo("Attack")
             if info then
                table.insert(spells, {type="spell", value="Attack", name=info.name, icon=info.iconID, category="global"})
                seen["Attack"] = true
             end
        end
        -- Single-Button Assistant
        if not seen["Single-Button Assistant"] then
             local info = C_Spell.GetSpellInfo("Single-Button Assistant")
             if info then
                table.insert(spells, {type="spell", value=info.spellID, name=info.name, icon=info.iconID, category="global"})
                seen[info.name] = true
             end
        end
    end
    
    table.sort(spells, function(a, b) return a.name < b.name end)
    return spells
end

function Wise:GetMacros(filter, categoryFilter)
    local macros = {}
    local numGlobal, numPerChar = GetNumMacros()
    local MAX_ACCOUNT_MACROS = MAX_ACCOUNT_MACROS or 120

    local showGlobal = (categoryFilter == "All" or categoryFilter == "Global")
    local showChar = (categoryFilter == "All" or categoryFilter == "Character")

    -- Global Macros
    if showGlobal then
        for i = 1, numGlobal do
            local name, icon = GetMacroInfo(i)
            if name and (not filter or string.find(string.lower(name), filter, 1, true)) then
                 table.insert(macros, {type="macro", value=name, name=name, icon=icon})
            end
        end
    end

    -- Character Macros
    if showChar then
        for i = 1, numPerChar do
            local index = MAX_ACCOUNT_MACROS + i
            local name, icon = GetMacroInfo(index)
            if name and (not filter or string.find(string.lower(name), filter, 1, true)) then
                 table.insert(macros, {type="macro", value=name, name=name, icon=icon})
            end
        end
    end

    table.sort(macros, function(a, b) return a.name < b.name end)
    return macros
end

function Wise:GetItems(filter)
    local items = {}
    local seen = {}
    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                local name = C_Item.GetItemNameByID(info.itemID)
                if name and (not filter or string.find(string.lower(name), filter, 1, true)) then
                    if not seen[info.itemID] then
                        table.insert(items, {type="item", value=info.itemID, name=name, icon=info.iconFileID})
                        seen[info.itemID] = true
                    end
                end
            end
        end
    end
    return items
end

function Wise:GetEquipped(filter)
    local items = {}
    local slots = {
        "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "ShirtSlot", "TabardSlot", 
        "WristSlot", "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot", "Finger0Slot", "Finger1Slot", 
        "Trinket0Slot", "Trinket1Slot", "MainHandSlot", "SecondaryHandSlot"
    }
    for _, slotName in ipairs(slots) do
        local slotId, texture = GetInventorySlotInfo(slotName)
        if texture then
            if not filter or string.find(string.lower(slotName), filter, 1, true) then
                table.insert(items, {type="equipped", value=slotId, name=slotName, icon=texture})
            end
        end
    end
    return items
end

function Wise:GetBattlepets(filter, favoritesOnly)
    local items = {}
    if not C_PetJournal then return items end
    local numPets = C_PetJournal.GetNumPets()
    for i = 1, numPets do
        local petID, speciesID, owned, customName, _, _, _, speciesName, icon = C_PetJournal.GetPetInfoByIndex(i)
        if owned then
            if favoritesOnly and C_PetJournal.PetIsFavorite and not C_PetJournal.PetIsFavorite(petID) then
                -- skip non-favorites
            else
                local name = customName or speciesName
                if name and (not filter or string.find(string.lower(name), filter, 1, true)) then
                    table.insert(items, {type="battlepet", value=petID, name=name, icon=icon})
                end
            end
        end
    end
    return items
end

function Wise:GetMounts(filter, favoritesOnly)
    local items = {}
    if not C_MountJournal then return items end
    -- Iterate IDs directly to bypass any filters in the mount journal UI
    for i = 1, 4200 do
        local name, spellID, icon, active, isUsable, sourceType, isFavorite, isFactionSpecific, faction, hideOnChar, isCollected, mountID = C_MountJournal.GetMountInfoByID(i)

        if name and isCollected then
            local match = true
            if favoritesOnly and not isFavorite then match = false end

            if match and (not filter or string.find(string.lower(name), filter, 1, true)) then
                table.insert(items, {type="mount", value=mountID, name=name, icon=icon})
            end
        end
    end
    return items
end

function Wise:GetEquipmentsets(filter)
    local items = {}
    if not C_EquipmentSet then return items end
    local setIDs = C_EquipmentSet.GetEquipmentSetIDs()
    for _, setID in ipairs(setIDs) do
        local name, icon = C_EquipmentSet.GetEquipmentSetInfo(setID)
        if name and (not filter or string.find(string.lower(name), filter, 1, true)) then
            table.insert(items, {type="equipmentset", value=name, name=name, icon=icon})
        end
    end
    return items
end

function Wise:GetRaidmarkers(filter)
    local items = {}
    local markers = {"Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull"}
    -- Map each marker to its corresponding World Marker (/wm) index
    -- WoW /wm indexes: 1=Square, 2=Triangle, 3=Diamond, 4=Cross, 5=Star, 6=Circle, 7=Moon, 8=Skull
    local wmMap = {
        ["Star"] = 5,
        ["Circle"] = 6,
        ["Diamond"] = 3,
        ["Triangle"] = 2,
        ["Moon"] = 7,
        ["Square"] = 1,
        ["Cross"] = 4,
        ["Skull"] = 8
    }

    local iconPath = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_"
    for i, name in ipairs(markers) do
        local unitName = name .. " (Unit)"
        local groundName = name .. " (Ground)"

        if not filter or string.find(string.lower(unitName), filter, 1, true) then
            table.insert(items, {type="raidmarker", value=i, name=unitName, icon=iconPath..i})
        end

        if not filter or string.find(string.lower(groundName), filter, 1, true) then
            local wmIndex = wmMap[name]
            table.insert(items, {type="worldmarker", value=wmIndex, name=groundName, icon=iconPath..i})
        end
    end
    return items
end

function Wise:GetToys(filter, favoritesOnly)
    local items = {}
    if not C_ToyBox then return items end
    C_ToyBox.SetCollectedShown(true)
    C_ToyBox.SetUncollectedShown(false)
    for i = 1, C_ToyBox.GetNumFilteredToys() do
        local itemID = C_ToyBox.GetToyFromIndex(i)
        if itemID ~= -1 then
            if favoritesOnly and C_ToyBox.GetIsFavorite and not C_ToyBox.GetIsFavorite(itemID) then
                -- skip non-favorites
            else
                local _, name, icon = C_ToyBox.GetToyInfo(itemID)
                if name and (not filter or string.find(string.lower(name), filter, 1, true)) then
                     table.insert(items, {type="toy", value=itemID, name=name, icon=icon})
                end
            end
        end
    end
    return items
end

function Wise:GetUIVisibility(filter)
    local items = {}
    local elements = {
        {id="minimap", name="Minimap", icon="Interface\\Icons\\INV_Misc_Spyglass_03"},
        {id="micromenu", name="Micro Menu", icon="Interface\\Icons\\INV_Misc_EngGizmos_17"},
        {id="bags", name="Bags Bar", icon="Interface\\Icons\\INV_Misc_Bag_08"},
        {id="xpbar", name="XP Bar", icon="Interface\\Icons\\Spell_Holy_DivineProvidence"},
        {id="repbar", name="Reputation Bar", icon="Interface\\Icons\\Achievement_Reputation_01"},
        {id="chat", name="Chat Frame", icon="Interface\\Icons\\Spell_Holy_Silence"},
        {id="objectives", name="Objective Tracker", icon="Interface\\Icons\\INV_Misc_Book_07"},
        {id="player", name="Player Frame", icon="Interface\\Icons\\Achievement_Character_Human_Male"},
        {id="target", name="Target Frame", icon="Interface\\Icons\\Ability_Hunter_SniperShot"},
        {id="buffs", name="Buffs", icon="Interface\\Icons\\Spell_Holy_WordFortitude"},
        {id="debuffs", name="Debuffs", icon="Interface\\Icons\\Spell_Shadow_CurseOfTounges"},
    }

    local states = {"On", "Off", "Toggle"}
    local stateKeys = {On="show", Off="hide", Toggle="toggle"}

    for _, el in ipairs(elements) do
        for _, state in ipairs(states) do
            local fullName = el.name .. ": " .. state
            if not filter or string.find(string.lower(fullName), filter, 1, true) then
                local val = el.id .. ":" .. stateKeys[state]
                table.insert(items, {type="uivisibility", value=val, name=fullName, icon=el.icon})
            end
        end
    end

    return items
end

function Wise:GetUIpanel(filter)
    local items = {}
    local panels = {
        -- Core Panels
        {name="Game Menu", val="menu", icon="Interface\\Icons\\INV_Misc_EngGizmos_17"},
        {name="Character", val="character", icon="Interface\\Icons\\Achievement_Level_100"},
        {name="Spellbook", val="spellbook", icon="Interface\\Icons\\INV_Misc_Book_09"},
        {name="Talents", val="talents", icon="Interface\\Icons\\Ability_Marksmanship"},
        {name="Specialization", val="specialization", icon="Interface\\Icons\\ClassIcon_Warrior"},
        {name="Collections", val="collections", icon="Interface\\Icons\\MountJournalPortrait"},
        {name="Group Finder", val="groupfinder", icon="Interface\\Icons\\INV_Helmet_06"},
        {name="Adventure Guide", val="adventureguide", icon="Interface\\Icons\\INV_Misc_Book_01"},
        {name="Achievements", val="achievements", icon="Interface\\Icons\\Achievement_Quests_Completed_01"},
        {name="Guild", val="guild", icon="Interface\\Icons\\Achievement_GuildPerk_MassResurrection"},
        {name="Map", val="map", icon="Interface\\Icons\\INV_Misc_Map_01"},
        {name="Shop", val="shop", icon="Interface\\Icons\\WoW_Token01"},
        {name="Quest Log", val="questlog", icon="Interface\\Icons\\INV_Misc_Book_07"},
        {name="Professions", val="professions", icon="Interface\\Icons\\Trade_Engineering"},
        {name="Housing", val="housing", icon="Interface\\Icons\\Garrison_Building_Storehouse"},
        -- Bags
        {name="Toggle Backpack", val="bag_backpack", icon="Interface\\Icons\\INV_Misc_Bag_08"},
        {name="Toggle Bag 1", val="bag_1", icon="Interface\\Icons\\INV_Misc_Bag_10_Blue"},
        {name="Toggle Bag 2", val="bag_2", icon="Interface\\Icons\\INV_Misc_Bag_10_Green"},
        {name="Toggle Bag 3", val="bag_3", icon="Interface\\Icons\\INV_Misc_Bag_10_Red"},
        {name="Toggle Bag 4", val="bag_4", icon="Interface\\Icons\\INV_Misc_Bag_10"},
        {name="Toggle Reagent Bag", val="bag_reagent", icon="Interface\\Icons\\INV_Enchant_DustArcane"},
        {name="Open All Bags", val="bag_all", icon="Interface\\Icons\\INV_Misc_Bag_17"},
        -- Collection Tabs
        {name="Mount Journal", val="collections_mounts", icon="Interface\\Icons\\MountJournalPortrait"},
        {name="Pet Journal", val="collections_pets", icon="Interface\\Icons\\INV_Box_PetCarrier_01"},
        {name="Toy Box", val="collections_toys", icon="Interface\\Icons\\INV_Misc_Toy_10"},
        {name="Heirlooms", val="collections_heirlooms", icon="Interface\\Icons\\INV_Misc_Book_01"},
        {name="Appearances", val="collections_appearances", icon="Interface\\Icons\\INV_Chest_Cloth_17"},
        -- Social
        {name="Social Panel", val="social", icon="Interface\\Icons\\Ability_Warrior_RallyingCry"},
        {name="Friends List", val="social_friends", icon="Interface\\Icons\\Ability_Warrior_RallyingCry"},
        {name="Who", val="social_who", icon="Interface\\Icons\\INV_Misc_GroupLooking"},
        {name="Raid", val="social_raid", icon="Interface\\Icons\\Ability_TrueShot"},
        -- PVP & Dungeons
        {name="PVP Panel", val="pvp", icon="Interface\\Icons\\Achievement_BG_WinWSG"},
        {name="Dungeons & Raids", val="dungeons", icon="Interface\\Icons\\INV_Helmet_06"},
        {name="Mythic+", val="mythicplus", icon="Interface\\Icons\\INV_Relics_Hourglass"},
        -- Reputation & Currency
        {name="Reputation", val="reputation", icon="Interface\\Icons\\Achievement_Reputation_01"},
        {name="Currency", val="currency", icon="Interface\\Icons\\INV_Misc_Coin_01"},
        -- Statistics
        {name="Statistics", val="statistics", icon="Interface\\Icons\\Achievement_Quests_Completed_01"},
        -- Maps
        {name="World Map Size", val="map_size", icon="Interface\\Icons\\INV_Misc_Map_01"},
        {name="Zone Map", val="map_zone", icon="Interface\\Icons\\INV_Misc_Map02"},
        {name="Toggle Minimap", val="map_minimap", icon="Interface\\Icons\\INV_Misc_Spyglass_03"},
        -- Garrison / Mission Report
        {name="Garrison Report", val="garrison", icon="Interface\\Icons\\Achievement_Garrison_Horde_PVE"},
    }
    for _, p in ipairs(panels) do
         if not filter or string.find(string.lower(p.name), filter, 1, true) then
             table.insert(items, {type="uipanel", value=p.val, name=p.name, icon=p.icon})
         end
    end
    return items
end

function Wise:GetProfessions(filter)
    local items = {}
    local profs = {GetProfessions()}
    local seen = {}

    for _, index in ipairs(profs) do
        if index then
            local name, icon, _, _, numAbilities, spellOffset, skillLine = GetProfessionInfo(index)
            if name then
                -- 1. Main Toggle Button (The "Profession" itself)
                local showMain = true
                if filter and not string.find(string.lower(name), filter, 1, true) then
                    showMain = false
                end

                if showMain then
                    local macroText = string.format("/run local i=C_TradeSkillUI.GetBaseProfessionInfo(); if i and i.professionID==%d then C_TradeSkillUI.CloseTradeSkill() else C_TradeSkillUI.OpenTradeSkill(%d) end", skillLine, skillLine)

                    table.insert(items, {
                        type = "macro",
                        value = macroText,
                        name = name,
                        icon = icon,
                        category = "Professions",
                        tooltipFunc = function() GameTooltip:SetText(name .. " (Toggle)") end
                    })
                    seen[name] = true
                end

                -- 2. Spells
                if numAbilities and spellOffset then
                    for j = 1, numAbilities do
                        local slotIndex = spellOffset + j
                        local spellType, spellID = C_SpellBook.GetSpellBookItemType(slotIndex, Enum.SpellBookSpellBank.Player)
                        if spellType == Enum.SpellBookItemType.Spell then
                            local sName = C_Spell.GetSpellName(spellID)
                            local sIcon = C_Spell.GetSpellTexture(spellID)

                            if sName and (not filter or string.find(string.lower(sName), filter, 1, true)) then
                                -- Avoid duplicate if spell name == profession name (assuming we prefer the toggle macro)
                                if sName ~= name then
                                    if not seen[sName] then
                                        table.insert(items, {
                                            type = "spell",
                                            value = spellID,
                                            name = sName,
                                            icon = sIcon,
                                            category = "Professions"
                                        })
                                        seen[sName] = true
                                    end
                                end
                            end
                        elseif spellType == Enum.SpellBookItemType.Flyout then
                            local flyoutID = spellID
                            local _, _, numSlots, isKnown = GetFlyoutInfo(flyoutID)
                            if isKnown and numSlots > 0 then
                                for s = 1, numSlots do
                                    local flyoutSpellID, overrideSpellID, isKnownSlot = GetFlyoutSlotInfo(flyoutID, s)
                                    if isKnownSlot and flyoutSpellID then
                                        local actualSpellID = overrideSpellID or flyoutSpellID
                                        if not C_Spell.IsSpellPassive(actualSpellID) then
                                            local sName = C_Spell.GetSpellName(actualSpellID)
                                            local sIcon = C_Spell.GetSpellTexture(actualSpellID)
                                            if sName and (not filter or string.find(string.lower(sName), filter, 1, true)) then
                                                if not seen[sName] then
                                                    table.insert(items, {
                                                        type="spell",
                                                        value=actualSpellID,
                                                        name=sName,
                                                        icon=sIcon,
                                                        category="Professions"
                                                    })
                                                    seen[sName] = true
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(items, function(a, b) return a.name < b.name end)
    return items
end

function Wise:GetDataBroker(filter) return {} end

function Wise:GetOverridebars(filter)
    local items = {}

    local overrideBarName = "Override Bar Button "
    for i = 1, 8 do
        local name = overrideBarName .. i
        if not filter or string.find(string.lower(name), filter, 1, true) then
            -- Override bar action IDs are 133-144
            local actionID = 132 + i
            table.insert(items, {
                type = "action",
                value = actionID,
                name = name,
                icon = "Interface\\Icons\\INV_Misc_QuestionMark",
                category = "Override bars",
                conditions = "[overridebar]"
            })
        end
    end

    local possessBarName = "Possess Bar Button "
    for i = 1, 8 do
        local name = possessBarName .. i
        if not filter or string.find(string.lower(name), filter, 1, true) then
            -- Possess bar usually maps over ActionButton1-12 which map to 1-12 or 121-132
            -- Let's use 121-132 for explicit possess bar slots
            local actionID = 120 + i
            table.insert(items, {
                type = "action",
                value = actionID,
                name = name,
                icon = "Interface\\Icons\\INV_Misc_QuestionMark",
                category = "Override bars",
                conditions = "[possessbar]"
            })
        end
    end

    if not filter or string.find("leave vehicle", filter, 1, true) then
        table.insert(items, {
            type = "misc",
            value = "leave_vehicle",
            name = "Leave Vehicle",
            icon = "Interface\\Vehicles\\UI-Vehicles-Button-Exit-Up",
            category = "Override bars"
        })
    end

    return items
end

function Wise:GetMiscellaneous(filter)
    local items = {}
    local misc = {
         {name="New Custom Macro", val="custom_macro", icon="Interface\\Icons\\Macro_Create"},
         {name="Extra Action Button 1", val="extrabutton", icon="Interface\\Icons\\Temp"},
         {name="Zone Ability", val="zoneability", icon="Interface\\Icons\\Temp"},
         {name="Override Bar", val="overridebar", icon="Interface\\Icons\\Temp"},
         {name="Possess Bar", val="possessbar", icon="Interface\\Icons\\Temp"},
         {name="Toggle Sound", val="toggle_sound", icon="Interface\\AddOns\\Wise\\Media\\SoundToggle.tga"},
         {name="Toggle Sound Effects", val="toggle_sfx", icon="Interface\\AddOns\\Wise\\Media\\SFXToggle.tga"},
         {name="Volume Up", val="vol_up", icon="Interface\\AddOns\\Wise\\Media\\VolUp.tga"},
         {name="Volume Down", val="vol_down", icon="Interface\\AddOns\\Wise\\Media\\VolDown.tga"},
    }
    local numSpecs = GetNumSpecializations()
    for i = 1, numSpecs do
        local id, name, _, icon = GetSpecializationInfo(i)
        if id then
            table.insert(misc, {name="Activate " .. name, val="spec_"..id, icon=icon})
            table.insert(misc, {name="Loot Spec: " .. name, val="lootspec_"..id, icon=icon})
        end
    end
    for _, m in ipairs(misc) do
        if not filter or string.find(string.lower(m.name), filter, 1, true) then
            table.insert(items, {type="misc", value=m.val, name=m.name, icon=m.icon})
        end
    end
    return items
end

-- ============================================================================
-- Options UI: Actions View Checklist
-- ============================================================================

-- This is the new "Middle" panel logic replacing RefreshActionList in Options.lua
function Wise:RefreshActionsView(container)
    local groupName = Wise.selectedGroup
    
    -- Cleanup
    if container.slots then
        for _, slot in ipairs(container.slots) do slot:Hide() end
    end
    if container.emptyLabel then container.emptyLabel:Hide() end
    container.slots = container.slots or {}

    -- Update the sticky AddSlotBtn script to use current groupName
    local addSlotBtn = Wise.OptionsFrame and Wise.OptionsFrame.Middle and Wise.OptionsFrame.Middle.AddSlotBtn
    
    if addSlotBtn then
        if not groupName or not WiseDB.groups[groupName] then
            addSlotBtn:Disable()
            addSlotBtn:SetScript("OnClick", nil)
        else
            addSlotBtn:Enable()
            addSlotBtn:SetScript("OnClick", function()
                -- 1. Determine next slot index
                local group = WiseDB.groups[groupName]
                Wise:MigrateGroupToActions(group)

                local nextSlot
                if group.propertyType == "CooldownWiser" then
                    -- CooldownWiser: insert decimal slot after the selected slot (or last slot)
                    -- e.g., selected slot 2 → insert 2.1 (between slot 2 and 3)
                    local baseSlot = Wise.selectedSlot
                    if not baseSlot or not group.actions[baseSlot] then
                        -- No selection: use last integer slot
                        baseSlot = 0
                        for k in pairs(group.actions) do
                            if type(k) == "number" and k == math.floor(k) and k > baseSlot then
                                baseSlot = k
                            end
                        end
                    end
                    local baseInt = math.floor(baseSlot)
                    local decimal = 1
                    while group.actions[baseInt + decimal * 0.1] do
                        decimal = decimal + 1
                    end
                    nextSlot = baseInt + decimal * 0.1
                else
                    nextSlot = 0
                    for k in pairs(group.actions) do
                        if type(k) == "number" and k > nextSlot then
                            nextSlot = k
                        end
                    end
                    nextSlot = nextSlot + 1
                end
                
                -- 2. Create the empty slot immediately
                if not group.actions[nextSlot] then
                    group.actions[nextSlot] = {} -- Empty state list
                end
                
                -- 3. Select this new slot
                Wise.selectedSlot = nextSlot
                Wise.selectedState = nil
                
                -- 4. Refresh View to show the new empty slot
                Wise:RefreshActionsView(container)
                
                -- 5. Open Picker for this new slot
                Wise.pickingAction = true
                Wise.PickerCallback = function(type, value, extra)
                    Wise:AddAction(groupName, nextSlot, type, value, nil, extra)
                    Wise:RefreshActionsView(container)
                    Wise:RefreshPropertiesPanel()
                    C_Timer.After(0, function()
                        if not InCombatLockdown() then Wise:UpdateGroupDisplay(Wise.selectedGroup) end
                    end)
                end
                Wise.PickerCurrentCategory = "Spell"
                Wise:RefreshPropertiesPanel()
            end)
        end
    end

    if not groupName or not WiseDB.groups[groupName] then return end

    local group = WiseDB.groups[groupName]
    Wise:MigrateGroupToActions(group)

    local y = -10

    -- Find max slot
    local maxSlot = 0
    for k, v in pairs(group.actions) do
        if type(k) == "number" and k > maxSlot then maxSlot = k end
    end
    
    if maxSlot == 0 then
        if not container.emptyLabel then
             container.emptyLabel = container:CreateFontString(nil, "OVERLAY", "GameFontDisable")
             container.emptyLabel:SetText("No slots defined.")
        end
        container.emptyLabel:SetPoint("TOP", 0, y)
        container.emptyLabel:Show()
        return
    end
    
    -- Render Slots 1 to Max
    -- (User might have gaps if they deleted slot 2 but kept 3. We show them spaced or just iterate?)
    -- "clearly delineated divider between each number."
    
    local slotIndex = 0 
    
    -- Sort keys to iterate
    local keys = {}
    for k in pairs(group.actions) do tinsert(keys, k) end
    table.sort(keys)
    
    for _, sIdx in ipairs(keys) do
        local actions = group.actions[sIdx]
        
        slotIndex = slotIndex + 1
        local slotFrame = container.slots[slotIndex]
        
        if not slotFrame then
            slotFrame = CreateFrame("Button", nil, container, "BackdropTemplate")
            slotFrame:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 12,
                insets = { left = 2, right = 2, top = 2, bottom = 2 }
            })
            slotFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
            slotFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            
            slotFrame.Header = slotFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            slotFrame.Header:SetPoint("TOPLEFT", 5, -5)

            slotFrame.kbLabel = slotFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            slotFrame.kbLabel:SetPoint("TOPRIGHT", -5, -5)
            slotFrame.kbLabel:SetTextColor(1, 1, 1, 1) -- White
            
            -- State container
            slotFrame.ActionButtons = {}

            -- Add State Button
            slotFrame.AddStateBtn = CreateFrame("Button", nil, slotFrame, "GameMenuButtonTemplate")
            slotFrame.AddStateBtn:SetSize(20, 20)
            slotFrame.AddStateBtn:SetText("+")
            
            tinsert(container.slots, slotFrame)
        end
        slotFrame:Show()
        slotFrame.slotID = sIdx
        slotFrame.AddStateBtn.slotID = sIdx
        
        slotFrame.AddStateBtn.slotID = sIdx
        
        
        -- Selection Highlight
        if Wise.selectedSlot == sIdx then
            slotFrame:SetBackdropBorderColor(1, 0.8, 0, 1) -- Gold Selected
        else
            slotFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        end
        
        -- Slot Drag-to-Reorder (mousedown + movement threshold)
        local capturedVisualIdx = slotIndex
        slotFrame:SetScript("OnMouseDown", function(self, button)
            if button ~= "LeftButton" then return end
            if reorderDrag.active or reorderDrag.pending then return end
            local grp = WiseDB.groups[groupName]
            if grp and grp.isLocked then return end
            if GetCursorInfo() then return end

            local scale = container:GetEffectiveScale()
            local cx, cy = GetCursorPosition()

            reorderDrag.pending = true
            reorderDrag.dragType = "slot"
            reorderDrag.sourceSlotID = self.slotID
            reorderDrag.sourceVisualIdx = capturedVisualIdx
            reorderDrag.targetVisualIdx = nil
            reorderDrag.container = container
            reorderDrag.sourceFrame = self
            reorderDrag.startX = cx / scale
            reorderDrag.startY = cy / scale

            container:SetScript("OnUpdate", ReorderDrag_OnUpdate)
        end)

        slotFrame.AddStateBtn:SetScript("OnClick", function(self)
             local capturedSlotID = self.slotID
             local type = GetCursorInfo()
             if type then
                 Wise:OnDragReceive(groupName, capturedSlotID, true)
             else
                 Wise.pickingAction = true
                 Wise.PickerCallback = function(type, value, extra)
                     -- Pass nil for category so Wise:AddAction resolves it from extra (or defaults to global)
                     Wise:AddAction(groupName, capturedSlotID, type, value, nil, extra)
                     Wise:RefreshActionsView(container)
                     Wise:RefreshPropertiesPanel()
                     C_Timer.After(0, function()
                        if not InCombatLockdown() then Wise:UpdateGroupDisplay(Wise.selectedGroup) end
                     end)
                 end
                 Wise.PickerCurrentCategory = "Spell"
                 Wise:RefreshPropertiesPanel()
             end
        end)
        slotFrame.AddStateBtn:SetScript("OnReceiveDrag", function(self)
             local capturedSlotID = self.slotID
             Wise:OnDragReceive(groupName, capturedSlotID, true)
        end)

        -- OPTIONS PANEL DRAG AND DROP
        slotFrame:SetScript("OnReceiveDrag", function(self)
            Wise:OnDragReceive(groupName, self.slotID, false)
        end)
        slotFrame:SetScript("OnMouseUp", function(self, button)
            if button ~= "LeftButton" then return end
            if reorderDrag.active then return end
            -- If pending (threshold not met), cancel and treat as normal click
            if reorderDrag.pending then
                reorderDrag.pending = false
                reorderDrag.dragType = nil
                reorderDrag.container = nil
                reorderDrag.sourceFrame = nil
                container:SetScript("OnUpdate", nil)
            end
            -- Check if cursor has something to drop
            local type = GetCursorInfo()
            if type then
                Wise:OnDragReceive(groupName, self.slotID, false)
            else
                -- Normal click logic (select slot)
                Wise.selectedSlot = self.slotID
                Wise.selectedState = nil
                Wise.pickingIcon = false
                Wise:RefreshActionsView(container)
                Wise:RefreshPropertiesPanel()
            end
        end)
        
        -- Format slot header (clean decimal display for CooldownWiser custom slots)
        if sIdx ~= math.floor(sIdx) then
            slotFrame.Header:SetText("Slot " .. string.format("%.1f", sIdx) .. " |cff66ccff(custom)|r")
        else
            slotFrame.Header:SetText("Slot " .. sIdx)
        end

        -- Keybind
        local keyText = Wise:GetKeybind(groupName, sIdx)
        if keyText then
            slotFrame.kbLabel:SetText(keyText)
            slotFrame.kbLabel:Show()
        else
            slotFrame.kbLabel:Hide()
        end
        
        -- Render States
        local innerY = -25
        
        -- Cleanup inner buttons
        for _, b in ipairs(slotFrame.ActionButtons) do b:Hide() end
        
        local totalStates = #actions
        for aIdx, action in ipairs(actions) do
             local btn = slotFrame.ActionButtons[aIdx]
             if not btn then
                 btn = CreateFrame("Button", nil, slotFrame, "BackdropTemplate")
                 btn:SetSize(240, 36)
                 btn:SetBackdrop({
                     bgFile = "Interface\\Buttons\\WHITE8X8",
                     edgeFile = nil,
                     tile = false, tileSize = 0, edgeSize = 0,
                     insets = { left = 0, right = 0, top = 0, bottom = 0 }
                 })
                 btn:SetBackdropColor(0.2, 0.2, 0.2, 1)

                 btn.iconFrame = CreateFrame("Button", nil, btn)
                 btn.iconFrame:SetSize(28, 28)
                 btn.iconFrame:SetPoint("LEFT", 4, 0)
                 btn.iconFrame:EnableMouse(false)

                 btn.icon = btn.iconFrame:CreateTexture(nil, "ARTWORK")
                 btn.icon:SetAllPoints()

                 if Wise.MasqueGroup then
                     Wise.MasqueGroup:AddButton(btn.iconFrame, { Icon = btn.icon })
                 end

                 btn.castReadout = Wise:CreateCastReadout(btn)

                 btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                 btn.label:SetJustifyH("LEFT")

                 btn.suffix = btn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                 btn.suffix:SetJustifyH("LEFT")

                 btn.errorIcon = btn:CreateTexture(nil, "OVERLAY")
                 btn.errorIcon:SetSize(16, 16)
                 btn.errorIcon:SetPoint("BOTTOMRIGHT", btn.iconFrame, "BOTTOMRIGHT", 4, -4)
                 btn.errorIcon:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
                 btn.errorIcon:Hide()

                 tinsert(slotFrame.ActionButtons, btn)
             end

             -- Filtering Check
             if Wise:ShouldShowAction(action) then
                 btn:Show()
                 btn:SetPoint("TOPLEFT", 10, innerY)
                 
                 local isValidCond, condErr = Wise:ValidateVisibilityCondition(action.conditions)
                 if isValidCond then
                     btn.errorIcon:Hide()
                     btn.condError = nil
                 else
                     btn.errorIcon:Show()
                     btn.condError = condErr
                 end

                 local icon = Wise:GetActionIcon(action.type, action.value, action)
                 local name = Wise:GetActionName(action.type, action.value, action)
                 
                 btn.icon:SetTexture(icon)

                 -- Build suffix text from visibility arrays
                 local suffixText = ""
                 local enables = action.visibilityEnable or {}
                 local disables = action.visibilityDisable or {}

                 local function formatTag(tag)
                     if tag == "global" then return "Global" end
                     local prefix, val = strsplit(":", tag, 2)
                     if not val then return tag end
                     if prefix == "role" then return Wise.RoleLabels and Wise.RoleLabels[val] or val
                     elseif prefix == "class" then return val -- already a class tag
                     elseif prefix == "spec" then
                         local _, name = GetSpecializationInfoByID(tonumber(val))
                         return name or val
                     elseif prefix == "talent" then
                         local spellInfo = C_Spell.GetSpellInfo(tonumber(val))
                         return spellInfo and spellInfo.name or val
                     elseif prefix == "char" then
                         local name = strsplit("-", val)
                         return name or val
                     end
                     return val
                 end

                 if #enables == 0 and #disables == 0 then
                     -- Legacy fallback text
                     local cat = action.category or "global"
                     if cat == "class" then suffixText = action.addedByClass or "Class"
                     elseif cat == "spec" then
                         local sp = action.addedBySpec
                         if sp then local _, sn = GetSpecializationInfoByID(sp); suffixText = sn or "Spec" end
                     elseif cat == "character" then suffixText = "Char"
                     end
                 else
                     local parts = {}
                     if #enables > 0 then
                         local eStrs = {}
                         for i = 1, math.min(2, #enables) do table.insert(eStrs, formatTag(enables[i])) end
                         if #enables > 2 then table.insert(eStrs, "...") end
                         table.insert(parts, "+(" .. table.concat(eStrs, ", ") .. ")")
                     end
                     if #disables > 0 then
                         local dStrs = {}
                         for i = 1, math.min(2, #disables) do table.insert(dStrs, formatTag(disables[i])) end
                         if #disables > 2 then table.insert(dStrs, "...") end
                         table.insert(parts, "-(" .. table.concat(dStrs, ", ") .. ")")
                     end
                     suffixText = table.concat(parts, " ")
                 end

                 -- Addon Magic: show addon count as suffix
                 if action.type == "misc" and type(action.value) == "string" and action.value:sub(1, 12) == "addon_magic_" then
                     local amIdx = tonumber(action.value:sub(13))
                     if amIdx and WiseDB.addonMagicSlots and WiseDB.addonMagicSlots[amIdx] then
                         local count = WiseDB.addonMagicSlots[amIdx].addons and #WiseDB.addonMagicSlots[amIdx].addons or 0
                         if count == 0 then
                             suffixText = "No addons selected"
                         elseif count == 1 then
                             suffixText = "1 addon"
                         else
                             suffixText = count .. " addons"
                         end
                     end
                 end

                 -- Handle Layout & Cast Text
                 btn.label:ClearAllPoints()
                 btn.label:SetPoint("TOPLEFT", btn.iconFrame, "TOPRIGHT", 5, -2)

                 local hasReadout = Wise:SetCastReadout(btn.castReadout, action.type, action.value, groupName)
                 local rightOffset = -15

                 if hasReadout then
                     btn.castReadout:ClearAllPoints()
                     btn.castReadout:SetPoint("RIGHT", rightOffset, 0)
                     btn.label:SetPoint("RIGHT", btn.castReadout, "LEFT", -5, 0)
                 else
                     btn.castReadout:Hide()
                     btn.label:SetPoint("RIGHT", rightOffset, 0)
                 end

                 if isValidCond then
                     btn.label:SetText(name)
                 else
                     btn.label:SetText("|cffff0000" .. name .. "|r")
                 end

                 btn.suffix:ClearAllPoints()
                 btn.suffix:SetPoint("TOPLEFT", btn.label, "BOTTOMLEFT", 0, -1)

                 if hasReadout then
                     btn.suffix:SetPoint("RIGHT", btn.castReadout, "LEFT", -5, 0)
                 else
                     btn.suffix:SetPoint("RIGHT", rightOffset, 0)
                 end

                 if suffixText ~= "" then
                     btn.suffix:SetText("|cffaaaaaa(" .. suffixText .. ")|r")
                     btn.suffix:Show()
                 else
                     btn.suffix:SetText("")
                     btn.suffix:Hide()
                 end
                 
                 -- Click to Select (for properties)
                 if Wise.selectedSlot == sIdx and Wise.selectedState == aIdx then
                     btn:SetBackdropColor(0.5, 0.5, 0.2, 1)
                 else
                     btn:SetBackdropColor(0.2, 0.2, 0.2, 1)
                 end
                 
                 local capturedSlotForDrag = sIdx
                 local capturedStateForDrag = aIdx

                 btn:SetScript("OnReceiveDrag", function()
                     Wise:OnDragReceive(groupName, capturedSlotForDrag, false, capturedStateForDrag)
                 end)

                 -- State Drag-to-Reorder (mousedown + movement threshold)
                 btn:SetScript("OnMouseDown", function(self, button)
                     if button ~= "LeftButton" then return end
                     if reorderDrag.active or reorderDrag.pending then return end
                     if GetCursorInfo() then return end
                     local grp = WiseDB.groups[groupName]
                     if grp and grp.isLocked then return end

                     local scale = container:GetEffectiveScale()
                     local cx, cy = GetCursorPosition()

                     reorderDrag.pending = true
                     reorderDrag.dragType = "state"
                     reorderDrag.sourceSlotID = capturedSlotForDrag
                     reorderDrag.sourceStateIdx = capturedStateForDrag
                     reorderDrag.targetStateIdx = nil
                     reorderDrag.container = container
                     reorderDrag.sourceFrame = self
                     reorderDrag.startX = cx / scale
                     reorderDrag.startY = cy / scale

                     container:SetScript("OnUpdate", ReorderDrag_OnUpdate)
                 end)
                 btn:SetScript("OnMouseUp", function(self, button)
                     if button ~= "LeftButton" then return end
                     if reorderDrag.active then return end
                     -- If pending (threshold not met), cancel and treat as normal click
                     if reorderDrag.pending then
                         reorderDrag.pending = false
                         reorderDrag.dragType = nil
                         reorderDrag.container = nil
                         reorderDrag.sourceFrame = nil
                         container:SetScript("OnUpdate", nil)
                     end
                     -- Normal click / WoW cursor drop
                     if GetCursorInfo() then
                         Wise:OnDragReceive(groupName, capturedSlotForDrag, false, capturedStateForDrag)
                         return
                     end
                     Wise.selectedSlot = sIdx
                     Wise.selectedState = aIdx
                     Wise.pickingIcon = false
                     Wise:RefreshActionsView(container)
                     Wise:RefreshPropertiesPanel()
                 end)

                 btn:SetScript("OnEnter", function(self)
                     if self.condError then
                         GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                         GameTooltip:SetText("Invalid Condition", 1, 0, 0)
                         GameTooltip:AddLine(self.condError, 1, 1, 1)
                         GameTooltip:Show()
                     end
                 end)
                 btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

                 innerY = innerY - 38
             else
                 -- Hidden
                 btn:Hide()
             end
        end
        
        -- "+" Button at bottom of slot
        slotFrame.AddStateBtn:ClearAllPoints()
        slotFrame.AddStateBtn:SetPoint("TOP", 0, innerY)
        innerY = innerY - 25
        
        -- Sizing
        local slotHeight = math.abs(innerY) + 5
        slotFrame:SetSize(260, slotHeight)

        slotFrame:ClearAllPoints()
        slotFrame:SetPoint("TOPLEFT", 0, y)
        y = y - slotHeight - 10
    end
    
    -- Hide unused slots
    for k = slotIndex + 1, #container.slots do container.slots[k]:Hide() end
    
    container:SetHeight(math.abs(y) + 50)
end

-- Helper to create the Icon Picker UI
function Wise:CreateIconPicker(parent)
    local ip = Wise.IconPicker

    -- If picker elements already exist and are parented to this container, just show them
    if ip and ip.parent == parent then
        ip.Frame:Show()
        ip.Frame.iconSelector:Show()
        ip.Frame.iconSelector:SetSelectedAsset(nil)
        ip.Frame.iconSelector:FocusManualInput()
        return
    end

    -- Build new picker UI into parent
    ip = {}
    ip.parent = parent
    Wise.IconPicker = ip

    -- Cancel / Back button
    ip.CancelBtn = CreateFrame("Button", nil, parent, "GameMenuButtonTemplate")
    ip.CancelBtn:SetSize(80, 22)
    ip.CancelBtn:SetPoint("TOPLEFT", 10, -20)
    ip.CancelBtn:SetText("< Back")
    ip.CancelBtn:SetScript("OnClick", function()
        Wise.pickingIcon = false
        Wise:RefreshPropertiesPanel()
    end)
    -- Start with this button hidden if we want cleaner init, but parent logic handles it
    
    -- Container for OPie IconSelector
    ip.Frame = CreateFrame("Frame", nil, parent)
    ip.Frame:SetPoint("TOPLEFT", 10, -50)
    ip.Frame:SetPoint("BOTTOMRIGHT", -10, 10)
    -- ip.Frame is NOT inserted into parent.controls because we manage it manually in RefreshPropertiesPanel overlay logic


    -- Create IconSelector widget
    -- We assume Wise.exUI is available (attached in Libs/exui/exui.lua)
    if Wise.exUI then
        local isd = Wise.exUI:Create("IconSelector", nil, ip.Frame)
        isd:SetPoint("TOPLEFT", 0, 0)
        isd:SetPoint("BOTTOMRIGHT", 0, 0)
        -- Compute grid dimensions from available space.
        -- ip.Frame padding: 10L+10R, 50T+10B relative to parent.
        -- IconSelector internal padding: 12L+31R (scrollbar), 32T+12B.
        local hostW, hostH = parent:GetWidth(), parent:GetHeight()
        local clipW = hostW - 20 - 43  -- ip.Frame insets + IconSelector padding
        local clipH = hostH - 60 - 44
        local cols = math.max(1, math.floor(clipW / 36))
        local rows = math.max(1, math.floor(clipH / 36))
        isd:SetGridSize(rows, cols)
        isd:SetManualInputHintText("Search icons...")
        isd:Show() -- Ensure it is visible (factory hides it by default)
        
        isd:SetScript("OnIconSelect", function(_, asset)
            if Wise.PickerCallback then
                Wise.PickerCallback("icon", asset)
                Wise.pickingIcon = false
                Wise:RefreshPropertiesPanel()
            end
        end)
        
        -- Hide the close button built into IconSelector if we want to rely on our Back button
        -- or keep it. The sample code hides it often.
        if isd.closeButton then isd.closeButton:Hide() end

        ip.Frame.iconSelector = isd
    else
        local err = ip.Frame:CreateFontString(nil, "OVERLAY", "GameFontRed")
        err:SetPoint("CENTER")
        err:SetText("Error: exUI library not loaded.")
    end
end
