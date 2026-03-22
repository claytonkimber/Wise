-- SlotConfigurator.lua
-- Visual slot configurator: graphical macro/sequence/condition editor
local addonName, Wise = ...

local _G = _G
local pairs = pairs
local ipairs = ipairs
local type = type
local string = string
local table = table
local math = math
local tinsert = table.insert
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local GameTooltip = GameTooltip
local C_Timer = C_Timer

-- ═══════════════════════════════════════════════════════════════
-- Constants
-- ═══════════════════════════════════════════════════════════════
local CELL_WIDTH = 76
local CELL_HEIGHT = 76
local CELL_PADDING = 6
local ROW_HEADER_WIDTH = 130
local COL_HEADER_HEIGHT = 28
local MOD_BREAK_HEIGHT = 26
local DRAG_THRESHOLD = 8

-- Modifier break colors
local MOD_COLORS = {
    shift = { r = 0.85, g = 0.55, b = 0.1 },
    alt   = { r = 0.15, g = 0.7, b = 0.35 },
    ctrl  = { r = 0.2, g = 0.45, b = 0.85 },
}

-- ═══════════════════════════════════════════════════════════════
-- Internal State
-- ═══════════════════════════════════════════════════════════════
local configuratorState = {
    groupName = nil,
    slotIdx = nil,
    -- grid[row][col] = actionData (shallow copy) or nil
    grid = {},
    -- rowConditions[row] = condition string (e.g. "[combat]") or ""
    rowConditions = {},
    -- modBreaks[afterRow] = "shift" | "alt" | "ctrl" | nil
    modBreaks = {},
    -- rowExclusive[row] = true/false (auto-negate other rows)
    rowExclusive = {},
    numCols = 1,
    numRows = 1,
    -- Drag state
    dragActive = false,
    dragSourceRow = nil,
    dragSourceCol = nil,
    dragAction = nil,
    -- Original strategy for preserving random
    originalStrategy = nil,
}

-- Forward declarations
local ActionPassesFilter
local HideAllModDropZones
local RenderConditionalList

-- UI element pools
local cellPool = {}
local colHeaderPool = {}
local modBreakPool = {}
local rowHeaderPool = {}
local emptyDropPool = {}

-- ═══════════════════════════════════════════════════════════════
-- Deep Copy Utility
-- ═══════════════════════════════════════════════════════════════
local function ShallowCopyAction(action)
    if not action then return nil end
    local copy = {}
    for k, v in pairs(action) do
        if type(v) == "table" then
            -- Shallow copy nested tables (visibilityEnable, visibilityDisable)
            local sub = {}
            for sk, sv in pairs(v) do sub[sk] = sv end
            copy[k] = sub
        else
            copy[k] = v
        end
    end
    return copy
end

-- ═══════════════════════════════════════════════════════════════
-- Condition String <-> Structured Groups
-- ═══════════════════════════════════════════════════════════════
-- Parses "[combat,flying][mounted]" into { {tokens}, {tokens} }
-- Each token: { token = "combat", negated = false }
local function ParseConditionString(str)
    if not str or str == "" then
        return { {} } -- one empty group
    end

    local groups = {}
    for bracket in string.gmatch(str, "%[([^%]]*)%]") do
        local group = {}
        for part in string.gmatch(bracket, "[^,]+") do
            part = part:match("^%s*(.-)%s*$") -- trim
            if part ~= "" then
                local negated = false
                local token = part
                -- Detect "no" prefix (but not "none", not targets like @...)
                if not string.find(part, "^@") and string.sub(part, 1, 2) == "no" then
                    -- Check it's not a real conditional that starts with "no"
                    local stripped = string.sub(part, 3)
                    if stripped ~= "" and stripped ~= "ne" then
                        negated = true
                        token = stripped
                    end
                end
                tinsert(group, { token = token, negated = negated })
            end
        end
        tinsert(groups, group)
    end

    -- If nothing was parsed (no brackets found), treat whole string as a single token
    if #groups == 0 then
        if str ~= "" then
            groups = { { { token = str, negated = false } } }
        else
            groups = { {} }
        end
    end

    return groups
end

-- Converts structured groups back to bracket string
local function BuildConditionString(groups)
    if not groups or #groups == 0 then return "" end

    local parts = {}
    for _, group in ipairs(groups) do
        if #group > 0 then
            local tokens = {}
            for _, item in ipairs(group) do
                local t = item.token
                if item.negated then
                    t = "no" .. t
                end
                tinsert(tokens, t)
            end
            tinsert(parts, "[" .. table.concat(tokens, ",") .. "]")
        end
    end

    return table.concat(parts, "")
end

-- ═══════════════════════════════════════════════════════════════
-- Import: Slot Data -> Grid
-- ═══════════════════════════════════════════════════════════════
local function ParseModifiers(condStr)
    if not condStr or condStr == "" then return {}, condStr end
    local mods = {}
    local remaining = condStr

    -- Extract [mod:X] patterns
    for mod in string.gmatch(condStr, "%[mod:(%w+)%]") do
        mods[string.lower(mod)] = true
    end
    -- Also handle combined like [combat,mod:shift]
    for mod in string.gmatch(condStr, "mod:(%w+)") do
        mods[string.lower(mod)] = true
    end

    -- Remove mod:X from condition string
    remaining = remaining:gsub(",?%s*mod:%w+", "")
    remaining = remaining:gsub("%[%s*,%s*", "[")
    remaining = remaining:gsub(",%s*%]", "]")
    remaining = remaining:gsub("%[%s*%]", "")
    remaining = remaining:match("^%s*(.-)%s*$") or ""

    return mods, remaining
end

local function ImportSlotData(groupName, slotIdx)
    local state = configuratorState
    state.groupName = groupName
    state.slotIdx = slotIdx
    state.grid = {}
    state.rowConditions = {}
    state.modBreaks = {}
    state.rowExclusive = {}

    local group = WiseDB and WiseDB.groups and WiseDB.groups[groupName]
    if not group or not group.actions then return end
    Wise:MigrateGroupToActions(group)

    local actions = group.actions[slotIdx]
    if not actions then return end

    state.originalStrategy = actions.conflictStrategy or "priority"
    local strategy = state.originalStrategy

    -- Collect allowed actions
    local items = {}
    for i = 1, #actions do
        local a = actions[i]
        if type(a) == "table" then
            tinsert(items, ShallowCopyAction(a))
        end
    end

    if #items == 0 then
        state.numRows = 1
        state.numCols = 1
        state.grid[1] = {}
        state.rowConditions[1] = ""
        state.rowExclusive[1] = false
        return
    end

    -- Parse modifiers out of conditions, group by base condition
    local parsed = {} -- { action, mods, baseCond }
    for _, a in ipairs(items) do
        local mods, base = ParseModifiers(a.conditions)
        tinsert(parsed, { action = a, mods = mods, baseCond = base or "" })
    end

    -- Group by modifier set to determine break placement
    -- Then within each modifier group, group by baseCond for rows
    -- For priority: all in col 1, each row = each action
    -- For sequence: spread across columns

    if strategy == "priority" or strategy == "random" then
        -- Each action gets its own row, all in column 1
        for i, p in ipairs(parsed) do
            state.grid[i] = { [1] = p.action }
            -- Strip mod conditions since they become breaks
            state.rowConditions[i] = p.baseCond
            state.rowExclusive[i] = p.action.exclusive or false
        end
        state.numRows = #parsed
        state.numCols = 1

        -- Insert mod breaks: if action has mod:shift, add break before it
        for i, p in ipairs(parsed) do
            if i > 1 then
                for mod in pairs(p.mods) do
                    if mod == "shift" or mod == "alt" or mod == "ctrl" then
                        state.modBreaks[i - 1] = mod
                        break -- one break per position
                    end
                end
            end
        end
    else
        -- Sequence: group by baseCond, spread within group across columns
        local condGroups = {} -- baseCond -> { actions }
        local condOrder = {}
        for _, p in ipairs(parsed) do
            if not condGroups[p.baseCond] then
                condGroups[p.baseCond] = {}
                tinsert(condOrder, p.baseCond)
            end
            tinsert(condGroups[p.baseCond], p)
        end

        local maxCols = 1
        local row = 0
        for _, cond in ipairs(condOrder) do
            row = row + 1
            state.grid[row] = {}
            state.rowConditions[row] = cond
            local group = condGroups[cond]
            state.rowExclusive[row] = (group[1] and group[1].action.exclusive) or false
            for col, p in ipairs(group) do
                state.grid[row][col] = p.action
                if col > maxCols then maxCols = col end
            end

            -- Mod breaks from first action in group
            if row > 1 and group[1] then
                for mod in pairs(group[1].mods) do
                    if mod == "shift" or mod == "alt" or mod == "ctrl" then
                        state.modBreaks[row - 1] = mod
                        break
                    end
                end
            end
        end
        state.numRows = row
        state.numCols = maxCols
    end

    -- Ensure at least 1 row and 1 col
    if state.numRows < 1 then state.numRows = 1 end
    if state.numCols < 1 then state.numCols = 1 end
    if not state.grid[1] then state.grid[1] = {} end
    if not state.rowConditions[1] then state.rowConditions[1] = "" end
end

-- ═══════════════════════════════════════════════════════════════
-- Export: Grid -> Slot Data
-- ═══════════════════════════════════════════════════════════════
local function ExportToSlotData()
    local state = configuratorState
    local groupName = state.groupName
    local slotIdx = state.slotIdx

    local group = WiseDB and WiseDB.groups and WiseDB.groups[groupName]
    if not group or not group.actions then return end

    local actions = group.actions[slotIdx]
    if not actions then return end

    -- Determine max columns actually used
    local maxCol = 0
    for r = 1, state.numRows do
        if state.grid[r] then
            for c = 1, state.numCols do
                if state.grid[r][c] then
                    if c > maxCol then maxCol = c end
                end
            end
        end
    end

    -- Determine conflict strategy
    local strategy
    if maxCol <= 1 then
        -- All in column 1: use priority, or preserve random if that was original
        if state.originalStrategy == "random" then
            strategy = "random"
        else
            strategy = "priority"
        end
    else
        strategy = "sequence"
    end

    -- Build modifier accumulation: track which mods apply after each break
    local modStack = {}
    for afterRow, mod in pairs(state.modBreaks) do
        modStack[afterRow] = mod
    end

    -- Compute accumulated modifiers per row
    local rowMods = {} -- rowMods[row] = { "shift" = true, ... }
    local activeMods = {}
    for r = 1, state.numRows do
        rowMods[r] = {}
        for m in pairs(activeMods) do rowMods[r][m] = true end
        -- Check if there's a break BEFORE this row (stored as modBreaks[r-1])
        if r > 1 and modStack[r - 1] then
            activeMods[modStack[r - 1]] = true
            rowMods[r][modStack[r - 1]] = true
        end
    end

    -- Build actions array
    local newActions = {}
    -- Preserve hash keys
    newActions.conflictStrategy = strategy
    newActions.keybind = actions.keybind
    newActions.resetOnCombat = actions.resetOnCombat
    newActions.suppressErrors = actions.suppressErrors

    for r = 1, state.numRows do
        if state.grid[r] then
            for c = 1, state.numCols do
                local a = state.grid[r][c]
                if a then
                    local exported = ShallowCopyAction(a)

                    -- Build conditions: baseCond + accumulated mods
                    local baseCond = state.rowConditions[r] or ""
                    local modParts = {}
                    if rowMods[r] then
                        for m in pairs(rowMods[r]) do
                            tinsert(modParts, "mod:" .. m)
                        end
                    end

                    if #modParts > 0 then
                        local modStr = table.concat(modParts, ",")
                        if baseCond ~= "" then
                            -- Merge into existing brackets
                            local merged = ""
                            local found = false
                            for bracket in string.gmatch(baseCond, "%[([^%]]*)%]") do
                                found = true
                                if bracket == "" then
                                    merged = merged .. "[" .. modStr .. "]"
                                else
                                    merged = merged .. "[" .. bracket .. "," .. modStr .. "]"
                                end
                            end
                            if not found then
                                merged = "[" .. baseCond .. "," .. modStr .. "]"
                            end
                            exported.conditions = merged
                        else
                            exported.conditions = "[" .. modStr .. "]"
                        end
                    else
                        exported.conditions = baseCond
                    end

                    exported.exclusive = state.rowExclusive[r] or false
                    tinsert(newActions, exported)
                end
            end
        end
    end

    -- Write back
    group.actions[slotIdx] = newActions

    -- Refresh displays
    Wise:RefreshActionsView(Wise.OptionsFrame.Middle.Content)
    C_Timer.After(0, function()
        if not InCombatLockdown() then
            Wise:UpdateGroupDisplay(groupName)
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════
-- UI Frame Factories
-- ═══════════════════════════════════════════════════════════════
local function GetOrCreateCell(parent, index)
    if cellPool[index] then
        cellPool[index]:SetParent(parent)
        return cellPool[index]
    end

    local cell = CreateFrame("Button", nil, parent, "BackdropTemplate")
    cell:SetSize(CELL_WIDTH, CELL_HEIGHT)
    cell:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    cell:SetBackdropColor(0.12, 0.12, 0.12, 0.95)
    cell:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    cell.icon = cell:CreateTexture(nil, "ARTWORK")
    cell.icon:SetSize(40, 40)
    cell.icon:SetPoint("TOP", 0, -6)
    cell.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    cell.nameLabel = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cell.nameLabel:SetPoint("TOP", cell.icon, "BOTTOM", 0, -2)
    cell.nameLabel:SetPoint("LEFT", 4, 0)
    cell.nameLabel:SetPoint("RIGHT", -4, 0)
    cell.nameLabel:SetJustifyH("CENTER")
    cell.nameLabel:SetMaxLines(2)

    cell.removeBtn = CreateFrame("Button", nil, cell)
    cell.removeBtn:SetSize(14, 14)
    cell.removeBtn:SetPoint("TOPRIGHT", -2, -2)
    cell.removeBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    cell.removeBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")
    cell.removeBtn:Hide()

    -- Highlight on hover
    cell.highlight = cell:CreateTexture(nil, "HIGHLIGHT")
    cell.highlight:SetAllPoints()
    cell.highlight:SetColorTexture(1, 0.82, 0, 0.12)

    cellPool[index] = cell
    return cell
end

local function GetOrCreateEmptyDrop(parent, index)
    if emptyDropPool[index] then
        emptyDropPool[index]:SetParent(parent)
        return emptyDropPool[index]
    end

    local drop = CreateFrame("Button", nil, parent, "BackdropTemplate")
    drop:SetSize(CELL_WIDTH, CELL_HEIGHT)
    drop:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    drop:SetBackdropColor(0.08, 0.08, 0.08, 0.6)
    drop:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)

    drop.plusLabel = drop:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    drop.plusLabel:SetPoint("CENTER")
    drop.plusLabel:SetText("+")
    drop.plusLabel:SetFont(drop.plusLabel:GetFont(), 20, "OUTLINE")

    drop.highlight = drop:CreateTexture(nil, "HIGHLIGHT")
    drop.highlight:SetAllPoints()
    drop.highlight:SetColorTexture(0.2, 0.8, 0.2, 0.15)

    emptyDropPool[index] = drop
    return drop
end

local function GetOrCreateColHeader(parent, index)
    if colHeaderPool[index] then
        colHeaderPool[index]:SetParent(parent)
        return colHeaderPool[index]
    end

    local header = CreateFrame("Frame", nil, parent)
    header:SetSize(CELL_WIDTH, COL_HEADER_HEIGHT)

    header.label = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header.label:SetPoint("CENTER")

    header.removeBtn = CreateFrame("Button", nil, header)
    header.removeBtn:SetSize(12, 12)
    header.removeBtn:SetPoint("TOPRIGHT", -2, -2)
    header.removeBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    header.removeBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")
    header.removeBtn:Hide()

    colHeaderPool[index] = header
    return header
end

local function GetOrCreateRowHeader(parent, index)
    if rowHeaderPool[index] then
        rowHeaderPool[index]:SetParent(parent)
        return rowHeaderPool[index]
    end

    local header = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    header:SetSize(ROW_HEADER_WIDTH - 10, CELL_HEIGHT)
    header:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    header:SetBackdropColor(0.1, 0.1, 0.15, 0.8)
    header:SetBackdropBorderColor(0.35, 0.35, 0.5, 0.8)

    header.condLabel = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    header.condLabel:SetPoint("TOP", 0, -8)
    header.condLabel:SetPoint("LEFT", 6, 0)
    header.condLabel:SetPoint("RIGHT", -6, 0)
    header.condLabel:SetJustifyH("CENTER")
    header.condLabel:SetMaxLines(2)

    header.editBtn = CreateFrame("Button", nil, header)
    header.editBtn:SetSize(16, 16)
    header.editBtn:SetPoint("BOTTOMRIGHT", -4, 4)
    header.editBtn:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-OfficerNote-Up")
    header.editBtn:SetHighlightTexture("Interface\\Buttons\\UI-GuildButton-OfficerNote-Up", "ADD")

    header.rowRemoveBtn = CreateFrame("Button", nil, header)
    header.rowRemoveBtn:SetSize(12, 12)
    header.rowRemoveBtn:SetPoint("TOPRIGHT", -4, -4)
    header.rowRemoveBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    header.rowRemoveBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")
    header.rowRemoveBtn:Hide()

    -- EditBox (hidden until editing)
    header.editBox = CreateFrame("EditBox", nil, header, "InputBoxTemplate")
    header.editBox:SetSize(ROW_HEADER_WIDTH - 30, 20)
    header.editBox:SetPoint("CENTER", 0, 0)
    header.editBox:SetAutoFocus(false)
    header.editBox:SetFontObject("GameFontHighlightSmall")
    header.editBox:Hide()

    rowHeaderPool[index] = header
    return header
end

local function GetOrCreateModBreak(parent, index)
    if modBreakPool[index] then
        modBreakPool[index]:SetParent(parent)
        return modBreakPool[index]
    end

    local brk = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    brk:SetHeight(MOD_BREAK_HEIGHT)
    brk:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })

    brk.label = brk:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    brk.label:SetPoint("CENTER")

    brk.removeBtn = CreateFrame("Button", nil, brk)
    brk.removeBtn:SetSize(14, 14)
    brk.removeBtn:SetPoint("RIGHT", -6, 0)
    brk.removeBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    brk.removeBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")

    -- Drop zone indicator (thin line for inserting new breaks)
    brk.dropZone = brk:CreateTexture(nil, "HIGHLIGHT")
    brk.dropZone:SetAllPoints()
    brk.dropZone:SetColorTexture(1, 1, 1, 0.1)

    modBreakPool[index] = brk
    return brk
end

-- ═══════════════════════════════════════════════════════════════
-- Drag Ghost
-- ═══════════════════════════════════════════════════════════════
local configDragGhost = nil
local function GetOrCreateConfigDragGhost()
    if configDragGhost then return configDragGhost end
    configDragGhost = CreateFrame("Frame", "WiseConfigDragGhost", UIParent, "BackdropTemplate")
    configDragGhost:SetFrameStrata("TOOLTIP")
    configDragGhost:SetSize(CELL_WIDTH, CELL_HEIGHT)
    configDragGhost:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    configDragGhost:SetBackdropColor(0.15, 0.15, 0.15, 0.85)
    configDragGhost:SetBackdropBorderColor(1, 0.82, 0, 1)
    configDragGhost:EnableMouse(false)
    configDragGhost:Hide()

    configDragGhost.icon = configDragGhost:CreateTexture(nil, "ARTWORK")
    configDragGhost.icon:SetSize(36, 36)
    configDragGhost.icon:SetPoint("TOP", 0, -6)
    configDragGhost.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    configDragGhost.nameLabel = configDragGhost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    configDragGhost.nameLabel:SetPoint("TOP", configDragGhost.icon, "BOTTOM", 0, -2)
    configDragGhost.nameLabel:SetPoint("LEFT", 4, 0)
    configDragGhost.nameLabel:SetPoint("RIGHT", -4, 0)
    configDragGhost.nameLabel:SetJustifyH("CENTER")

    return configDragGhost
end

-- ═══════════════════════════════════════════════════════════════
-- Insert Indicators
-- ═══════════════════════════════════════════════════════════════
local configInsertIndicator = nil
local function GetOrCreateConfigInsertIndicator(parent)
    if configInsertIndicator then
        configInsertIndicator:SetParent(parent)
        return configInsertIndicator
    end
    configInsertIndicator = parent:CreateTexture(nil, "OVERLAY")
    configInsertIndicator:SetColorTexture(0, 0.8, 1, 0.9)
    configInsertIndicator:SetSize(CELL_WIDTH, 3)
    configInsertIndicator:Hide()
    return configInsertIndicator
end

-- Row insert indicator (between rows)
local rowInsertIndicator = nil
local function GetOrCreateRowInsertIndicator(parent)
    if rowInsertIndicator then
        rowInsertIndicator:SetParent(parent)
        return rowInsertIndicator
    end
    rowInsertIndicator = parent:CreateTexture(nil, "OVERLAY")
    rowInsertIndicator:SetColorTexture(1, 0.82, 0, 0.9)
    rowInsertIndicator:SetHeight(3)
    rowInsertIndicator:Hide()
    return rowInsertIndicator
end

-- ═══════════════════════════════════════════════════════════════
-- Canvas Rendering
-- ═══════════════════════════════════════════════════════════════
local function HideAllPooled()
    for _, c in pairs(cellPool) do c:Hide() end
    for _, c in pairs(emptyDropPool) do c:Hide() end
    for _, c in pairs(colHeaderPool) do c:Hide() end
    for _, c in pairs(rowHeaderPool) do c:Hide() end
    for _, c in pairs(modBreakPool) do c:Hide() end
    HideAllModDropZones()
    if configInsertIndicator then configInsertIndicator:Hide() end
    if rowInsertIndicator then rowInsertIndicator:Hide() end
end

local function RenderCanvas()
    local sc = Wise.SlotConfigurator
    if not sc or not sc.canvas then return end

    local canvas = sc.canvas
    local state = configuratorState

    HideAllPooled()

    local cellIdx = 1
    local emptyIdx = 1
    local colIdx = 1
    local rowHdrIdx = 1
    local brkIdx = 1

    local x0 = ROW_HEADER_WIDTH
    local y0 = -COL_HEADER_HEIGHT

    -- Column headers
    for c = 1, state.numCols do
        local hdr = GetOrCreateColHeader(canvas, colIdx)
        colIdx = colIdx + 1
        hdr:ClearAllPoints()
        hdr:SetPoint("TOPLEFT", canvas, "TOPLEFT", x0 + (c - 1) * (CELL_WIDTH + CELL_PADDING), 0)
        hdr.label:SetText("Step " .. c)

        -- Remove column button (only if more than 1 column)
        if state.numCols > 1 then
            hdr.removeBtn:Show()
            local removeCol = c
            hdr.removeBtn:SetScript("OnClick", function()
                -- Remove this column from every row
                for r = 1, state.numRows do
                    if state.grid[r] then
                        table.remove(state.grid[r], removeCol)
                    end
                end
                state.numCols = state.numCols - 1
                if state.numCols < 1 then state.numCols = 1 end
                RenderCanvas()
            end)
        else
            hdr.removeBtn:Hide()
        end
        hdr:Show()
    end

    -- "+" column header (add step)
    local addColHdr = GetOrCreateColHeader(canvas, colIdx)
    colIdx = colIdx + 1
    addColHdr:ClearAllPoints()
    addColHdr:SetPoint("TOPLEFT", canvas, "TOPLEFT", x0 + state.numCols * (CELL_WIDTH + CELL_PADDING), 0)
    addColHdr.label:SetText("+")
    addColHdr.removeBtn:Hide()
    addColHdr:Show()

    -- Make the "+" clickable with a button overlay
    if not addColHdr.clickBtn then
        addColHdr.clickBtn = CreateFrame("Button", nil, addColHdr)
        addColHdr.clickBtn:SetAllPoints()
        addColHdr.clickBtn:SetScript("OnClick", function()
            state.numCols = state.numCols + 1
            RenderCanvas()
        end)
        addColHdr.clickBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Add Sequence Step", 1, 1, 1)
            GameTooltip:AddLine("Add another column for sequencing actions.", 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        addColHdr.clickBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local yOffset = y0

    -- Track row Y positions for modifier drop zones
    local sc = Wise.SlotConfigurator
    if sc then sc._rowYPositions = {} end

    -- Render rows
    for r = 1, state.numRows do
        if not state.grid[r] then state.grid[r] = {} end

        -- Check for mod break BEFORE this row (stored as modBreaks[r-1])
        if r > 1 and state.modBreaks[r - 1] then
            local mod = state.modBreaks[r - 1]
            local brk = GetOrCreateModBreak(canvas, brkIdx)
            brkIdx = brkIdx + 1
            brk:ClearAllPoints()
            brk:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, yOffset)
            local brkWidth = ROW_HEADER_WIDTH + state.numCols * (CELL_WIDTH + CELL_PADDING)
            brk:SetWidth(brkWidth)

            local col = MOD_COLORS[mod] or MOD_COLORS.shift
            brk:SetBackdropColor(col.r, col.g, col.b, 0.7)
            brk:SetBackdropBorderColor(col.r, col.g, col.b, 1)
            brk.label:SetText(string.upper(mod) .. " Modifier")
            brk.label:SetTextColor(1, 1, 1, 1)

            local breakRow = r - 1
            brk.removeBtn:SetScript("OnClick", function()
                state.modBreaks[breakRow] = nil
                RenderCanvas()
            end)

            brk:Show()
            yOffset = yOffset - MOD_BREAK_HEIGHT - 4
        end

        -- Store row Y position for modifier drop zones
        if sc then sc._rowYPositions[r] = yOffset end

        -- Row header (condition label)
        local rowHdr = GetOrCreateRowHeader(canvas, rowHdrIdx)
        rowHdrIdx = rowHdrIdx + 1
        rowHdr:ClearAllPoints()
        rowHdr:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, yOffset)

        local condText = state.rowConditions[r] or ""
        local exclusiveTag = state.rowExclusive[r] and " |cffffcc00[E]|r" or ""
        if condText == "" then
            rowHdr.condLabel:SetText("|cff888888Always|r" .. exclusiveTag)
        else
            rowHdr.condLabel:SetText(condText .. exclusiveTag)
        end

        -- Edit button to open condition picker in Right column
        rowHdr.editBox:Hide()
        rowHdr.editBtn:SetScript("OnClick", function()
            -- Save any currently open condition picker
            if Wise.pickingCondition and Wise._conditionPickerState then
                local prevRow = Wise._configuratorConditionRow
                if prevRow and state.rowConditions then
                    state.rowConditions[prevRow] = BuildConditionString(Wise._conditionPickerState.groups)
                end
            end
            -- Parse current row condition into structured model
            Wise._conditionPickerState = {
                row = r,
                groups = ParseConditionString(state.rowConditions[r] or ""),
                activeGroup = 1,
            }
            Wise._configuratorConditionRow = r
            Wise.pickingCondition = true
            Wise:RefreshPropertiesPanel()
        end)

        -- Row remove button (only if more than 1 row)
        if state.numRows > 1 then
            rowHdr.rowRemoveBtn:Show()
            local removeRow = r
            rowHdr.rowRemoveBtn:SetScript("OnClick", function()
                table.remove(state.grid, removeRow)
                table.remove(state.rowConditions, removeRow)
                table.remove(state.rowExclusive, removeRow)
                -- Shift mod breaks down
                local newBreaks = {}
                for afterRow, mod in pairs(state.modBreaks) do
                    if afterRow < removeRow then
                        newBreaks[afterRow] = mod
                    elseif afterRow >= removeRow and afterRow < state.numRows then
                        newBreaks[afterRow - 1] = mod
                    end
                end
                state.modBreaks = newBreaks
                state.numRows = state.numRows - 1
                if state.numRows < 1 then
                    state.numRows = 1
                    state.grid[1] = {}
                    state.rowConditions[1] = ""
                    state.rowExclusive[1] = false
                end
                RenderCanvas()
            end)
        else
            rowHdr.rowRemoveBtn:Hide()
        end

        -- Tooltip on row header
        rowHdr:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Row Condition", 1, 1, 1)
            local cond = state.rowConditions[r] or ""
            if cond == "" then
                GameTooltip:AddLine("No condition - always active", 0.8, 0.8, 0.8, true)
            else
                GameTooltip:AddLine("Condition: " .. cond, 0.8, 0.8, 0.8, true)
            end
            GameTooltip:AddLine("Click the pencil to edit.", 0.6, 0.6, 0.6, true)
            GameTooltip:Show()
        end)
        rowHdr:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rowHdr:Show()

        -- Cells for this row
        for c = 1, state.numCols do
            local action = state.grid[r][c]
            local cellX = x0 + (c - 1) * (CELL_WIDTH + CELL_PADDING)

            if action then
                -- Filled cell
                local cell = GetOrCreateCell(canvas, cellIdx)
                cellIdx = cellIdx + 1
                cell:ClearAllPoints()
                cell:SetPoint("TOPLEFT", canvas, "TOPLEFT", cellX, yOffset)

                -- Set icon
                local iconTex = Wise:GetActionIcon(action.type, action.value, action)
                if iconTex then
                    cell.icon:SetTexture(iconTex)
                    cell.icon:Show()
                else
                    cell.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                    cell.icon:Show()
                end

                -- Set name
                local name = Wise:GetActionName(action.type, action.value, action) or "Unknown"
                cell.nameLabel:SetText(name)

                -- Apply filter dimming
                local passesFilter = ActionPassesFilter(action)
                if passesFilter then
                    cell:SetAlpha(1)
                    cell:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
                else
                    cell:SetAlpha(0.35)
                    cell:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)
                end

                -- Remove button
                cell.removeBtn:Show()
                local removeRow, removeCol = r, c
                cell.removeBtn:SetScript("OnClick", function()
                    state.grid[removeRow][removeCol] = nil
                    RenderCanvas()
                end)

                -- Drag handling
                local dragRow, dragCol = r, c
                cell:RegisterForDrag("LeftButton")
                cell:SetScript("OnDragStart", function(self)
                    if InCombatLockdown() then return end
                    configuratorState.dragActive = true
                    configuratorState.dragSourceRow = dragRow
                    configuratorState.dragSourceCol = dragCol
                    configuratorState.dragAction = state.grid[dragRow][dragCol]

                    local ghost = GetOrCreateConfigDragGhost()
                    ghost.icon:SetTexture(iconTex or "Interface\\Icons\\INV_Misc_QuestionMark")
                    ghost.nameLabel:SetText(name)
                    ghost:Show()

                    -- Dim source cell
                    self:SetAlpha(0.4)

                    -- Start OnUpdate for ghost tracking
                    ghost:SetScript("OnUpdate", function(g)
                        local cx, cy = GetCursorPosition()
                        local scale = UIParent:GetEffectiveScale()
                        g:ClearAllPoints()
                        g:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx / scale, cy / scale)
                    end)
                end)

                cell:SetScript("OnDragStop", function(self)
                    self:SetAlpha(1)
                    local ghost = GetOrCreateConfigDragGhost()
                    ghost:Hide()
                    ghost:SetScript("OnUpdate", nil)

                    if not configuratorState.dragActive then return end
                    configuratorState.dragActive = false

                    -- Find drop target based on cursor position
                    local cx, cy = GetCursorPosition()
                    local scale = UIParent:GetEffectiveScale()
                    cx, cy = cx / scale, cy / scale

                    local dropped = false
                    -- Check all cells and empty drops for hit
                    for ci, cf in pairs(cellPool) do
                        if cf:IsShown() and cf ~= self then
                            local l, b, w, h = cf:GetRect()
                            if l and cx >= l and cx <= l + w and cy >= b and cy <= b + h then
                                -- Swap
                                local tr, tc = cf.gridRow, cf.gridCol
                                if tr and tc then
                                    local srcAction = configuratorState.dragAction
                                    state.grid[configuratorState.dragSourceRow][configuratorState.dragSourceCol] = state.grid[tr][tc]
                                    state.grid[tr][tc] = srcAction
                                    dropped = true
                                end
                                break
                            end
                        end
                    end

                    if not dropped then
                        for ei, ef in pairs(emptyDropPool) do
                            if ef:IsShown() then
                                local l, b, w, h = ef:GetRect()
                                if l and cx >= l and cx <= l + w and cy >= b and cy <= b + h then
                                    local tr, tc = ef.gridRow, ef.gridCol
                                    if tr and tc then
                                        state.grid[configuratorState.dragSourceRow][configuratorState.dragSourceCol] = nil
                                        state.grid[tr][tc] = configuratorState.dragAction
                                        dropped = true
                                    end
                                    break
                                end
                            end
                        end
                    end

                    if not dropped then
                        -- Drop cancelled, do nothing
                    end

                    configuratorState.dragAction = nil
                    configuratorState.dragSourceRow = nil
                    configuratorState.dragSourceCol = nil
                    RenderCanvas()
                end)

                -- Tooltip
                cell:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(name, 1, 1, 1)
                    if action.type then
                        GameTooltip:AddLine("Type: " .. action.type, 0.8, 0.8, 0.8)
                    end
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Drag to reorder. Click X to remove.", 0.6, 0.6, 0.6, true)
                    GameTooltip:Show()
                end)
                cell:SetScript("OnLeave", function() GameTooltip:Hide() end)

                -- Store grid position on the cell for drag target detection
                cell.gridRow = r
                cell.gridCol = c

                cell:Show()
            else
                -- Empty drop target
                local drop = GetOrCreateEmptyDrop(canvas, emptyIdx)
                emptyIdx = emptyIdx + 1
                drop:ClearAllPoints()
                drop:SetPoint("TOPLEFT", canvas, "TOPLEFT", cellX, yOffset)
                drop.gridRow = r
                drop.gridCol = c

                -- Accept cursor drops or open picker
                drop:RegisterForClicks("LeftButtonUp")
                local dropRow, dropCol = r, c
                drop:SetScript("OnClick", function(self)
                    -- Check for cursor item first
                    local cursorType, id, subType = GetCursorInfo()
                    if cursorType then
                        local actionData = Wise:CursorToActionData(cursorType, id)
                        if actionData then
                            state.grid[dropRow][dropCol] = actionData
                            ClearCursor()
                            RenderCanvas()
                        end
                    else
                        -- No cursor item — open the spell picker
                        Wise:OpenConfiguratorPicker(dropRow, dropCol)
                    end
                end)

                -- Also handle internal drag drops via OnReceiveDrag
                drop:SetScript("OnReceiveDrag", function(self)
                    local cursorType, id = GetCursorInfo()
                    if cursorType then
                        local actionData = Wise:CursorToActionData(cursorType, id)
                        if actionData then
                            state.grid[dropRow][dropCol] = actionData
                            ClearCursor()
                            RenderCanvas()
                        end
                    end
                end)

                drop:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Empty Slot", 1, 1, 1)
                    GameTooltip:AddLine("Click to open spell picker.", 0.8, 0.8, 0.8, true)
                    GameTooltip:AddLine("Or drag from the spellbook.", 0.6, 0.6, 0.6, true)
                    GameTooltip:Show()
                end)
                drop:SetScript("OnLeave", function() GameTooltip:Hide() end)

                drop:Show()
            end
        end

        yOffset = yOffset - CELL_HEIGHT - CELL_PADDING
    end

    -- "+ Add Row" area
    local addRowY = yOffset - 6
    if not sc.addRowBtn then
        sc.addRowBtn = CreateFrame("Button", nil, canvas, "GameMenuButtonTemplate")
        sc.addRowBtn:SetSize(ROW_HEADER_WIDTH - 10, 22)
        sc.addRowBtn:SetText("+ Row")
        sc.addRowBtn:SetScript("OnClick", function()
            state.numRows = state.numRows + 1
            state.grid[state.numRows] = {}
            state.rowConditions[state.numRows] = ""
            state.rowExclusive[state.numRows] = false
            RenderCanvas()
        end)
        Wise:AddTooltip(sc.addRowBtn, "Add a new condition row.")
    end
    sc.addRowBtn:ClearAllPoints()
    sc.addRowBtn:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, addRowY)
    sc.addRowBtn:Show()

    -- Calculate total content size
    local totalWidth = ROW_HEADER_WIDTH + (state.numCols + 1) * (CELL_WIDTH + CELL_PADDING) + 20
    local totalHeight = math.abs(addRowY) + 40
    canvas:SetSize(totalWidth, totalHeight)

    -- Update info label
    if sc.infoLabel then
        local strat = "Priority (single column)"
        if state.numCols > 1 then strat = "Sequence (" .. state.numCols .. " steps)" end
        sc.infoLabel:SetText("Layout: " .. state.numRows .. " row(s), " .. state.numCols .. " step(s) | Mode: " .. strat)
    end
end

-- ═══════════════════════════════════════════════════════════════
-- Modifier Drag State
-- ═══════════════════════════════════════════════════════════════
local modDrag = {
    active = false,
    modifier = nil, -- "shift" | "alt" | "ctrl"
}

-- Modifier drag ghost
local modDragGhost = nil
local function GetOrCreateModDragGhost()
    if modDragGhost then return modDragGhost end
    modDragGhost = CreateFrame("Frame", "WiseModDragGhost", UIParent, "BackdropTemplate")
    modDragGhost:SetFrameStrata("TOOLTIP")
    modDragGhost:SetSize(80, 22)
    modDragGhost:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    modDragGhost:EnableMouse(false)
    modDragGhost:Hide()

    modDragGhost.label = modDragGhost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    modDragGhost.label:SetPoint("CENTER")

    return modDragGhost
end

-- Row drop zone indicators (rendered between rows during mod drag)
local modDropZones = {}
local function GetOrCreateModDropZone(parent, index)
    if modDropZones[index] then
        modDropZones[index]:SetParent(parent)
        return modDropZones[index]
    end
    local zone = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    zone:SetHeight(14)
    zone:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 6,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    zone:SetBackdropColor(0.5, 0.5, 0.5, 0.3)
    zone:SetBackdropBorderColor(0.8, 0.8, 0.8, 0.5)

    zone.label = zone:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    zone.label:SetPoint("CENTER")
    zone.label:SetText("Drop here")

    zone:Hide()
    modDropZones[index] = zone
    return zone
end

HideAllModDropZones = function()
    for _, z in pairs(modDropZones) do z:Hide() end
end

-- ═══════════════════════════════════════════════════════════════
-- Modifier Palette (draggable tokens)
-- ═══════════════════════════════════════════════════════════════
local function CreateModifierPalette(parent)
    local palette = CreateFrame("Frame", nil, parent)
    palette:SetSize(280, 22)

    local modLabel = palette:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    modLabel:SetPoint("LEFT", 0, 0)
    modLabel:SetText("Modifiers:")

    local mods = { "shift", "alt", "ctrl" }
    local xOff = 60
    for _, mod in ipairs(mods) do
        local col = MOD_COLORS[mod]
        local token = CreateFrame("Button", nil, palette, "BackdropTemplate")
        token:SetSize(60, 20)
        token:SetPoint("LEFT", xOff, 0)
        token:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 8,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        token:SetBackdropColor(col.r, col.g, col.b, 0.6)
        token:SetBackdropBorderColor(col.r, col.g, col.b, 1)

        token.label = token:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        token.label:SetPoint("CENTER")
        token.label:SetText(string.upper(mod))

        -- Draggable
        token:RegisterForDrag("LeftButton")
        token:SetScript("OnDragStart", function(self)
            modDrag.active = true
            modDrag.modifier = mod

            local ghost = GetOrCreateModDragGhost()
            ghost:SetBackdropColor(col.r, col.g, col.b, 0.8)
            ghost:SetBackdropBorderColor(col.r, col.g, col.b, 1)
            ghost.label:SetText(string.upper(mod))
            ghost:Show()

            -- Show drop zones between rows on the canvas
            local sc = Wise.SlotConfigurator
            if sc and sc.canvas and sc._rowYPositions then
                local zoneIdx = 1
                local canvasWidth = ROW_HEADER_WIDTH + configuratorState.numCols * (CELL_WIDTH + CELL_PADDING)
                for afterRow = 1, configuratorState.numRows - 1 do
                    if not configuratorState.modBreaks[afterRow] then
                        local zoneY = sc._rowYPositions[afterRow + 1]
                        if zoneY then
                            local zone = GetOrCreateModDropZone(sc.canvas, zoneIdx)
                            zoneIdx = zoneIdx + 1
                            zone:ClearAllPoints()
                            zone:SetPoint("TOPLEFT", sc.canvas, "TOPLEFT", 0, zoneY + 8)
                            zone:SetWidth(canvasWidth)
                            zone.afterRow = afterRow
                            zone:SetBackdropColor(col.r, col.g, col.b, 0.3)
                            zone:SetBackdropBorderColor(col.r, col.g, col.b, 0.6)
                            zone.label:SetText("Drop " .. string.upper(mod) .. " here")
                            zone:Show()
                        end
                    end
                end
            end

            ghost:SetScript("OnUpdate", function(g)
                local cx, cy = GetCursorPosition()
                local scale = UIParent:GetEffectiveScale()
                g:ClearAllPoints()
                g:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx / scale, cy / scale)
            end)
        end)

        token:SetScript("OnDragStop", function(self)
            local ghost = GetOrCreateModDragGhost()
            ghost:Hide()
            ghost:SetScript("OnUpdate", nil)
            HideAllModDropZones()

            if not modDrag.active then return end
            modDrag.active = false

            -- Hit test against drop zones
            local cx, cy = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale

            for _, zone in pairs(modDropZones) do
                if zone:IsShown() and zone.afterRow then
                    local l, b, w, h = zone:GetRect()
                    if l and cx >= l and cx <= l + w and cy >= b and cy <= b + h then
                        configuratorState.modBreaks[zone.afterRow] = modDrag.modifier
                        RenderCanvas()
                        return
                    end
                end
            end

            modDrag.modifier = nil
        end)

        token:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(string.upper(mod) .. " Modifier", col.r, col.g, col.b)
            GameTooltip:AddLine("Drag between rows to add a modifier break.", 0.8, 0.8, 0.8, true)
            GameTooltip:AddLine("Actions below the break only fire with " .. string.upper(mod) .. " held.", 0.6, 0.6, 0.6, true)
            GameTooltip:Show()
        end)
        token:SetScript("OnLeave", function() GameTooltip:Hide() end)

        xOff = xOff + 66
    end

    return palette
end

-- ═══════════════════════════════════════════════════════════════
-- Cursor -> Action Data helper
-- ═══════════════════════════════════════════════════════════════
function Wise:CursorToActionData(cursorType, id)
    local C_Spell = C_Spell
    if cursorType == "spell" then
        local spellInfo = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
        return {
            type = "spell",
            value = id,
            name = spellInfo and spellInfo.name or "",
            icon = spellInfo and spellInfo.iconID or nil,
        }
    elseif cursorType == "item" then
        return { type = "item", value = id }
    elseif cursorType == "macro" then
        return { type = "macro", value = id }
    elseif cursorType == "mount" then
        return { type = "mount", value = id }
    end
    return nil
end

-- ═══════════════════════════════════════════════════════════════
-- Picker Integration (opens spell picker from within configurator)
-- ═══════════════════════════════════════════════════════════════
function Wise:OpenConfiguratorPicker(targetRow, targetCol)
    -- Save and close condition picker if open (without full refresh)
    if Wise.pickingCondition and Wise._conditionPickerState then
        local prevRow = Wise._configuratorConditionRow
        if prevRow and configuratorState.rowConditions then
            configuratorState.rowConditions[prevRow] = BuildConditionString(Wise._conditionPickerState.groups)
        end
        Wise.pickingCondition = false
        Wise._conditionPickerState = nil
        Wise._configuratorConditionRow = nil
    end

    -- Store which cell we're picking for
    Wise._configuratorPickTarget = { row = targetRow, col = targetCol }

    -- Use the existing picker system with a custom callback
    Wise.pickingAction = true
    Wise.PickerCallback = function(actionType, value, extra)
        local target = Wise._configuratorPickTarget
        if target and configuratorState.grid then
            if not configuratorState.grid[target.row] then
                configuratorState.grid[target.row] = {}
            end
            configuratorState.grid[target.row][target.col] = {
                type = actionType,
                value = value,
                name = extra and extra.name or nil,
                icon = extra and extra.icon or nil,
                category = extra and extra.category or "global",
            }
        end
        Wise._configuratorPickTarget = nil
    end

    -- The picker's OnClick sets pickingAction = false and calls RefreshPropertiesPanel.
    -- Since configuringSlot is still true, it will return to the configurator.
    -- But we need to re-render the canvas after the picker closes.
    -- Hook into the existing flow: when pickingAction goes false and configuringSlot is true,
    -- RefreshPropertiesPanel will show the configurator again and call RenderCanvas.

    Wise:RefreshPropertiesPanel()
end

-- Check if an action passes the current filter (uses Wise.ActionFilter from main editor)
ActionPassesFilter = function(action)
    if not action then return false end
    local filter = Wise.ActionFilter or "global"
    if filter == "global" then return true end

    -- Use the same category-based filtering as the main editor
    local category = action.category or "global"

    if filter == "class" then
        return category == "class" or category == "global"
    elseif filter == "role" then
        return category == "role" or category == "global"
    elseif filter == "spec" then
        return category == "spec" or category == "global"
    elseif filter == "talent" then
        return category == "talent" or category == "global"
    elseif filter == "character" then
        return category == "character" or category == "global"
    end

    return true
end

-- ═══════════════════════════════════════════════════════════════
-- Condition Picker (visual condition builder in Right column)
-- ═══════════════════════════════════════════════════════════════

-- Close the condition picker, saving current state
local function CloseConditionPicker()
    if Wise.pickingCondition and Wise._conditionPickerState then
        local row = Wise._configuratorConditionRow
        if row and configuratorState.rowConditions then
            configuratorState.rowConditions[row] = BuildConditionString(Wise._conditionPickerState.groups)
        end
    end
    Wise.pickingCondition = false
    Wise._conditionPickerState = nil
    Wise._configuratorConditionRow = nil
    Wise:RefreshPropertiesPanel()
end

-- Refresh the builder area and preview inside the condition picker
local function RefreshConditionBuilder(pickerFrame)
    local ps = Wise._conditionPickerState
    if not ps or not pickerFrame or not pickerFrame.builderContent then return end

    local content = pickerFrame.builderContent
    -- Hide all existing chips and group frames
    if content._groupFrames then
        for _, gf in ipairs(content._groupFrames) do gf:Hide() end
    end
    content._groupFrames = content._groupFrames or {}

    local yOff = 0
    local contentWidth = content:GetWidth()
    if contentWidth < 100 then contentWidth = 560 end

    for gi, group in ipairs(ps.groups) do
        -- OR divider between groups
        if gi > 1 then
            yOff = yOff - 4
            local divIdx = gi - 1
            if not content._orDividers then content._orDividers = {} end
            local div = content._orDividers[divIdx]
            if not div then
                div = CreateFrame("Frame", nil, content)
                div:SetHeight(16)
                div.line1 = div:CreateTexture(nil, "ARTWORK")
                div.line1:SetColorTexture(0.4, 0.4, 0.4, 0.6)
                div.line1:SetHeight(1)
                div.line1:SetPoint("LEFT", 10, 0)
                div.line1:SetPoint("RIGHT", div, "CENTER", -20, 0)
                div.line2 = div:CreateTexture(nil, "ARTWORK")
                div.line2:SetColorTexture(0.4, 0.4, 0.4, 0.6)
                div.line2:SetHeight(1)
                div.line2:SetPoint("LEFT", div, "CENTER", 20, 0)
                div.line2:SetPoint("RIGHT", -10, 0)
                div.label = div:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                div.label:SetPoint("CENTER")
                div.label:SetText("OR")
                content._orDividers[divIdx] = div
            end
            div:ClearAllPoints()
            div:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOff)
            div:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            div:Show()
            yOff = yOff - 18
        end

        -- Group frame
        local gf = content._groupFrames[gi]
        if not gf then
            gf = CreateFrame("Frame", nil, content, "BackdropTemplate")
            gf:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 10,
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            gf._chips = {}
            gf._removeBtn = CreateFrame("Button", nil, gf)
            gf._removeBtn:SetSize(12, 12)
            gf._removeBtn:SetPoint("TOPRIGHT", -3, -3)
            gf._removeBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
            gf._removeBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")
            content._groupFrames[gi] = gf
        end

        local isActive = (gi == ps.activeGroup)
        if isActive then
            gf:SetBackdropColor(0.12, 0.15, 0.22, 1)
            gf:SetBackdropBorderColor(0.3, 0.5, 0.8, 1)
        else
            gf:SetBackdropColor(0.1, 0.1, 0.1, 1)
            gf:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        end

        -- Click group to make active
        gf:EnableMouse(true)
        gf:SetScript("OnMouseDown", function()
            ps.activeGroup = gi
            RefreshConditionBuilder(pickerFrame)
            -- Re-render list to update target blocking for new active group
            local cp = Wise.ConditionPicker
            if cp then
                RenderConditionalList(pickerFrame, cp._activeTab or "builtin")
            end
        end)

        -- Group remove button (only if >1 group)
        if #ps.groups > 1 then
            gf._removeBtn:Show()
            gf._removeBtn:SetScript("OnClick", function()
                table.remove(ps.groups, gi)
                if ps.activeGroup > #ps.groups then ps.activeGroup = #ps.groups end
                if ps.activeGroup < 1 then ps.activeGroup = 1 end
                if #ps.groups == 0 then ps.groups = { {} } end
                RefreshConditionBuilder(pickerFrame)
            end)
        else
            gf._removeBtn:Hide()
        end

        -- Hide old chips
        for _, chip in ipairs(gf._chips) do chip:Hide() end

        -- Render chips for each token in group
        local chipX = 6
        local chipY = -6
        local chipRowHeight = 24
        local chipIdx = 0

        for ti, item in ipairs(group) do
            chipIdx = chipIdx + 1
            local chip = gf._chips[chipIdx]
            if not chip then
                chip = CreateFrame("Button", nil, gf, "BackdropTemplate")
                chip:SetHeight(20)
                chip:SetBackdrop({
                    bgFile = "Interface\\Buttons\\WHITE8X8",
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    tile = true, tileSize = 16, edgeSize = 8,
                    insets = { left = 1, right = 1, top = 1, bottom = 1 },
                })
                chip.label = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                chip.label:SetPoint("LEFT", 4, 0)
                chip.removeBtn = CreateFrame("Button", nil, chip)
                chip.removeBtn:SetSize(10, 10)
                chip.removeBtn:SetPoint("RIGHT", -3, 0)
                chip.removeBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
                chip.removeBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")
                gf._chips[chipIdx] = chip
            end

            local displayText = item.negated and ("no" .. item.token) or item.token
            chip.label:SetText(displayText)
            local textWidth = chip.label:GetStringWidth()
            chip:SetWidth(math.max(textWidth + 22, 40))

            -- Color: negated = reddish, normal = blue-ish
            if item.negated then
                chip:SetBackdropColor(0.4, 0.12, 0.12, 1)
                chip:SetBackdropBorderColor(0.7, 0.25, 0.25, 1)
            else
                chip:SetBackdropColor(0.12, 0.2, 0.35, 1)
                chip:SetBackdropBorderColor(0.2, 0.4, 0.7, 1)
            end

            -- Wrap to next line if needed
            if chipX + chip:GetWidth() > contentWidth - 20 and chipX > 6 then
                chipX = 6
                chipY = chipY - chipRowHeight - 2
            end

            chip:ClearAllPoints()
            chip:SetPoint("TOPLEFT", gf, "TOPLEFT", chipX, chipY)
            chipX = chipX + chip:GetWidth() + 4
            chip:Show()

            -- Click chip to toggle negation
            chip:SetScript("OnClick", function()
                item.negated = not item.negated
                RefreshConditionBuilder(pickerFrame)
            end)

            -- Remove button
            chip.removeBtn:SetScript("OnClick", function()
                table.remove(group, ti)
                -- Remove empty groups (but keep at least 1)
                if #group == 0 and #ps.groups > 1 then
                    table.remove(ps.groups, gi)
                    if ps.activeGroup > #ps.groups then ps.activeGroup = #ps.groups end
                end
                RefreshConditionBuilder(pickerFrame)
                -- Re-render list to update target blocking state
                local cp = Wise.ConditionPicker
                if cp then
                    RenderConditionalList(pickerFrame, cp._activeTab or "builtin")
                end
            end)
        end

        -- Compute group frame height from chip layout
        local groupHeight = math.abs(chipY) + chipRowHeight + 8
        gf:ClearAllPoints()
        gf:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOff)
        gf:SetPoint("RIGHT", content, "RIGHT", 0, 0)
        gf:SetHeight(groupHeight)
        gf:Show()

        yOff = yOff - groupHeight - 2
    end

    -- Hide extra OR dividers
    if content._orDividers then
        for i = #ps.groups, #content._orDividers do
            if content._orDividers[i] then content._orDividers[i]:Hide() end
        end
    end

    -- "+ Add OR Group" button
    if not content._addGroupBtn then
        content._addGroupBtn = CreateFrame("Button", nil, content, "GameMenuButtonTemplate")
        content._addGroupBtn:SetSize(140, 20)
        content._addGroupBtn:SetText("+ Add OR Group")
        content._addGroupBtn:SetNormalFontObject("GameFontHighlightSmall")
    end
    content._addGroupBtn:ClearAllPoints()
    content._addGroupBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOff - 4)
    content._addGroupBtn:Show()
    content._addGroupBtn:SetScript("OnClick", function()
        tinsert(ps.groups, {})
        ps.activeGroup = #ps.groups
        RefreshConditionBuilder(pickerFrame)
        -- Re-render list (new empty group = no target blocking)
        local cp = Wise.ConditionPicker
        if cp then
            RenderConditionalList(pickerFrame, cp._activeTab or "builtin")
        end
    end)
    yOff = yOff - 28

    -- Preview string
    if not content._previewLabel then
        content._previewLabel = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        content._previewLabel:SetJustifyH("LEFT")
    end
    content._previewLabel:ClearAllPoints()
    content._previewLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 4, yOff - 4)
    content._previewLabel:SetPoint("RIGHT", content, "RIGHT", -4, 0)
    local previewStr = BuildConditionString(ps.groups)
    if previewStr == "" then
        content._previewLabel:SetText("|cff888888Preview: (no condition - always)|r")
    else
        content._previewLabel:SetText("Preview: |cff00ccff" .. previewStr .. "|r")
    end
    content._previewLabel:Show()

    -- Update total height
    content:SetHeight(math.abs(yOff) + 24)
end

-- Render the scrollable conditional list
RenderConditionalList = function(pickerFrame, listType)
    local ps = Wise._conditionPickerState
    if not ps or not pickerFrame or not pickerFrame.listContent then return end

    local content = pickerFrame.listContent
    local list = (listType == "wise") and Wise.opieConditionals or Wise.builtinConditionals
    if not list then return end

    -- Hide existing rows
    if not content._rows then content._rows = {} end
    for _, row in ipairs(content._rows) do row:Hide() end

    -- Check if active group already has a target conditional (@...)
    local activeGroupHasTarget = false
    local activeGroup = ps.groups[ps.activeGroup]
    if activeGroup then
        for _, tok in ipairs(activeGroup) do
            if string.sub(tok.token, 1, 1) == "@" then
                activeGroupHasTarget = true
                break
            end
        end
    end

    local yOff = -4
    local rowIdx = 0

    for _, item in ipairs(list) do
        rowIdx = rowIdx + 1
        local row = content._rows[rowIdx]
        if not row then
            row = CreateFrame("Button", nil, content)
            row:SetHeight(22)

            -- [+] button on the LEFT
            row.addBtn = CreateFrame("Button", nil, row)
            row.addBtn:SetSize(18, 18)
            row.addBtn:SetPoint("LEFT", 4, 0)
            row.addBtn.tex = row.addBtn:CreateTexture(nil, "ARTWORK")
            row.addBtn.tex:SetAllPoints()
            row.addBtn.tex:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
            row.addBtn:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")

            -- Name after the [+] button
            row.nameLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.nameLabel:SetPoint("LEFT", row.addBtn, "RIGHT", 6, 0)
            row.nameLabel:SetWidth(160)
            row.nameLabel:SetJustifyH("LEFT")

            -- Description fills the rest
            row.descLabel = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            row.descLabel:SetPoint("LEFT", row.nameLabel, "RIGHT", 8, 0)
            row.descLabel:SetPoint("RIGHT", row, "RIGHT", -8, 0)
            row.descLabel:SetJustifyH("LEFT")

            -- Inline arg input (hidden by default, appears after name)
            row.argBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
            row.argBox:SetSize(80, 18)
            row.argBox:SetPoint("LEFT", row.nameLabel, "RIGHT", 8, 0)
            row.argBox:SetAutoFocus(false)
            row.argBox:SetFontObject("GameFontHighlightSmall")
            row.argBox:Hide()

            row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
            row.highlight:SetAllPoints()
            row.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row.highlight:SetBlendMode("ADD")
            row.highlight:SetAlpha(0.3)

            content._rows[rowIdx] = row
        end

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOff)
        row:SetPoint("RIGHT", content, "RIGHT", 0, 0)

        if item.type == "header" then
            -- Section header — spans full width, no [+] button
            row:SetHeight(26)
            row.addBtn:Hide()
            row.nameLabel:SetWidth(0)
            row.nameLabel:ClearAllPoints()
            row.nameLabel:SetPoint("LEFT", 6, 0)
            row.nameLabel:SetPoint("RIGHT", -6, 0)
            row.nameLabel:SetJustifyH("CENTER")
            row.nameLabel:SetText("|cffffd200" .. item.text .. "|r")
            row.descLabel:Hide()
            row.argBox:Hide()
            row.highlight:Hide()
            row:Show()
            yOff = yOff - 26
        else
            -- Conditional row — [+] on left, name, then description
            row:SetHeight(22)
            row.nameLabel:SetWidth(160)
            row.nameLabel:ClearAllPoints()
            row.nameLabel:SetPoint("LEFT", row.addBtn, "RIGHT", 6, 0)
            row.nameLabel:SetJustifyH("LEFT")
            row.descLabel:ClearAllPoints()
            row.descLabel:SetPoint("LEFT", row.nameLabel, "RIGHT", 8, 0)
            row.descLabel:SetPoint("RIGHT", row, "RIGHT", -8, 0)

            local isTarget = string.sub(item.name, 1, 1) == "@"
            local blocked = isTarget and activeGroupHasTarget

            local displayName = item.name
            if item.combatRestricted then
                displayName = displayName .. " |cffff4444*|r"
            end
            if blocked then
                row.nameLabel:SetText("|cff994444" .. item.name .. "|r")
                row.descLabel:SetText("|cff994444" .. (item.desc or "") .. "|r")
            else
                row.nameLabel:SetText(displayName)
                row.descLabel:SetText(item.desc or "")
            end
            row.descLabel:Show()
            row.highlight:Show()
            row.argBox:Hide()

            -- Determine the base token (strip placeholder args like ":name", ":type")
            local baseName = item.name
            local needsArg = item.skipeval and string.find(baseName, ":") and true or false

            -- Always reset addBtn anchor for conditional rows
            row.addBtn:ClearAllPoints()
            row.addBtn:SetPoint("LEFT", 4, 0)

            if blocked then
                row.addBtn:Hide()
            else
                row.addBtn:Show()
                row.addBtn:SetScript("OnClick", function()
                    if not ps.groups[ps.activeGroup] then
                        ps.groups[ps.activeGroup] = {}
                    end
                    if needsArg then
                        -- Show arg input
                        row.argBox:Show()
                        row.argBox:SetText("")
                        row.argBox:SetFocus()
                    else
                        tinsert(ps.groups[ps.activeGroup], { token = baseName, negated = false })
                        RefreshConditionBuilder(pickerFrame)
                        -- Re-render list to update target blocking
                        if isTarget then
                            RenderConditionalList(pickerFrame, listType)
                        end
                    end
                end)
            end

            -- Arg input handlers
            row.argBox:SetScript("OnEnterPressed", function(self)
                local arg = self:GetText()
                self:ClearFocus()
                self:Hide()
                -- Build token: use base (before :) + user arg
                local base = string.match(baseName, "^([^:]+)")
                local token = base .. ":" .. arg
                if not ps.groups[ps.activeGroup] then
                    ps.groups[ps.activeGroup] = {}
                end
                tinsert(ps.groups[ps.activeGroup], { token = token, negated = false })
                RefreshConditionBuilder(pickerFrame)
            end)
            row.argBox:SetScript("OnEscapePressed", function(self)
                self:ClearFocus()
                self:Hide()
            end)

            -- Tooltip
            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(item.name, 1, 1, 1)
                if item.desc then
                    GameTooltip:AddLine(item.desc, 0.8, 0.8, 0.8, true)
                end
                if item.combatRestricted then
                    GameTooltip:AddLine("Only evaluates outside combat", 1, 0.4, 0.4, true)
                end
                GameTooltip:AddLine("Click [+] to add to the active AND group", 0.5, 0.7, 1, true)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)

            row:Show()
            yOff = yOff - 22
        end
    end

    content:SetHeight(math.abs(yOff) + 8)
end

function Wise:CreateConditionPickerUI(host)
    local cp = Wise.ConditionPicker
    local ps = Wise._conditionPickerState
    if not ps then return end

    local row = Wise._configuratorConditionRow or 1

    -- Reuse existing UI if same host
    if cp and cp.host == host then
        cp.titleLabel:SetText("Row " .. row .. " Condition")
        cp.backBtn:Show()
        cp.titleLabel:Show()
        cp.exclusiveCheck:Show()
        cp.exclusiveLabel:Show()
        cp.inheritedLabel:Show()
        cp.divider:Show()
        cp.builderScroll:Show()
        cp.listDivider:Show()
        cp.tabBuiltin:Show()
        cp.tabWise:Show()
        cp.listScroll:Show()

        cp.exclusiveCheck:SetChecked(configuratorState.rowExclusive[row] or false)
        RefreshConditionBuilder(cp.frame)
        RenderConditionalList(cp.frame, cp._activeTab or "builtin")
        Wise:UpdateConditionPickerExclusionDisplay(cp, row)
        return
    end

    cp = {}
    Wise.ConditionPicker = cp
    cp.host = host
    cp.frame = host
    cp._activeTab = "builtin"

    -- Back button
    cp.backBtn = CreateFrame("Button", nil, host, "GameMenuButtonTemplate")
    cp.backBtn:SetSize(70, 22)
    cp.backBtn:SetPoint("TOPLEFT", 8, -8)
    cp.backBtn:SetText("< Back")
    cp.backBtn:SetScript("OnClick", function()
        CloseConditionPicker()
    end)

    -- Title
    cp.titleLabel = host:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cp.titleLabel:SetPoint("LEFT", cp.backBtn, "RIGHT", 8, 0)
    cp.titleLabel:SetText("Row " .. row .. " Condition")

    -- Exclusive checkbox
    cp.exclusiveCheck = CreateFrame("CheckButton", nil, host, "UICheckButtonTemplate")
    cp.exclusiveCheck:SetSize(22, 22)
    cp.exclusiveCheck:SetPoint("TOPLEFT", host, "TOPLEFT", 8, -34)
    cp.exclusiveCheck:SetChecked(configuratorState.rowExclusive[row] or false)
    cp.exclusiveCheck:SetScript("OnClick", function(self)
        configuratorState.rowExclusive[row] = self:GetChecked() and true or false
        Wise:UpdateConditionPickerExclusionDisplay(cp, row)
    end)

    cp.exclusiveLabel = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cp.exclusiveLabel:SetPoint("LEFT", cp.exclusiveCheck, "RIGHT", 2, 0)
    cp.exclusiveLabel:SetText("Exclusive condition")

    cp.inheritedLabel = host:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    cp.inheritedLabel:SetPoint("TOPLEFT", cp.exclusiveCheck, "BOTTOMLEFT", 22, -2)
    cp.inheritedLabel:SetPoint("RIGHT", host, "RIGHT", -8, 0)
    cp.inheritedLabel:SetJustifyH("LEFT")
    cp.inheritedLabel:SetMaxLines(3)

    Wise:UpdateConditionPickerExclusionDisplay(cp, row)

    -- Divider
    cp.divider = host:CreateTexture(nil, "ARTWORK")
    cp.divider:SetColorTexture(0.3, 0.3, 0.3, 0.8)
    cp.divider:SetHeight(1)
    cp.divider:SetPoint("TOPLEFT", host, "TOPLEFT", 8, -72)
    cp.divider:SetPoint("TOPRIGHT", host, "TOPRIGHT", -8, -72)

    -- Builder scroll area (condition chips)
    cp.builderScroll = CreateFrame("ScrollFrame", nil, host, "UIPanelScrollFrameTemplate")
    cp.builderScroll:SetPoint("TOPLEFT", host, "TOPLEFT", 8, -76)
    cp.builderScroll:SetPoint("RIGHT", host, "RIGHT", -28, 0)
    cp.builderScroll:SetHeight(160)

    cp.builderContent = CreateFrame("Frame", nil, cp.builderScroll)
    cp.builderContent:SetSize(560, 160)
    cp.builderScroll:SetScrollChild(cp.builderContent)
    host.builderContent = cp.builderContent
    -- Keep scroll child width in sync with scroll frame
    cp.builderScroll:SetScript("OnSizeChanged", function(self, w)
        if w and w > 50 then cp.builderContent:SetWidth(w - 4) end
    end)

    RefreshConditionBuilder(host)

    -- List divider
    cp.listDivider = host:CreateTexture(nil, "ARTWORK")
    cp.listDivider:SetColorTexture(0.3, 0.3, 0.3, 0.8)
    cp.listDivider:SetHeight(1)
    cp.listDivider:SetPoint("TOPLEFT", cp.builderScroll, "BOTTOMLEFT", 0, -4)
    cp.listDivider:SetPoint("RIGHT", host, "RIGHT", -8, 0)

    -- Sub-tabs: Built-in / Wise
    cp.tabBuiltin = CreateFrame("Button", nil, host, "GameMenuButtonTemplate")
    cp.tabBuiltin:SetSize(120, 20)
    cp.tabBuiltin:SetPoint("TOPLEFT", cp.listDivider, "BOTTOMLEFT", 0, -4)
    cp.tabBuiltin:SetText("Built-in")
    cp.tabBuiltin:SetNormalFontObject("GameFontHighlightSmall")

    cp.tabWise = CreateFrame("Button", nil, host, "GameMenuButtonTemplate")
    cp.tabWise:SetSize(120, 20)
    cp.tabWise:SetPoint("LEFT", cp.tabBuiltin, "RIGHT", 4, 0)
    cp.tabWise:SetText("Wise")
    cp.tabWise:SetNormalFontObject("GameFontHighlightSmall")

    local function UpdateTabHighlight()
        if cp._activeTab == "builtin" then
            cp.tabBuiltin:Disable()
            cp.tabWise:Enable()
        else
            cp.tabBuiltin:Enable()
            cp.tabWise:Disable()
        end
    end

    cp.tabBuiltin:SetScript("OnClick", function()
        cp._activeTab = "builtin"
        UpdateTabHighlight()
        RenderConditionalList(host, "builtin")
    end)
    cp.tabWise:SetScript("OnClick", function()
        cp._activeTab = "wise"
        UpdateTabHighlight()
        RenderConditionalList(host, "wise")
    end)
    UpdateTabHighlight()

    -- List scroll area
    cp.listScroll = CreateFrame("ScrollFrame", nil, host, "UIPanelScrollFrameTemplate")
    cp.listScroll:SetPoint("TOPLEFT", cp.tabBuiltin, "BOTTOMLEFT", 0, -4)
    cp.listScroll:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -28, 8)

    cp.listContent = CreateFrame("Frame", nil, cp.listScroll)
    cp.listContent:SetSize(560, 400)
    cp.listScroll:SetScrollChild(cp.listContent)
    host.listContent = cp.listContent
    -- Keep scroll child width in sync with scroll frame
    cp.listScroll:SetScript("OnSizeChanged", function(self, w)
        if w and w > 50 then cp.listContent:SetWidth(w - 4) end
    end)

    RenderConditionalList(host, "builtin")
end

function Wise:UpdateConditionPickerExclusionDisplay(cp, row)
    if not cp or not cp.inheritedLabel then return end

    local exclusions = {}
    for r = 1, configuratorState.numRows do
        if r ~= row and configuratorState.rowExclusive[r] then
            local cond = configuratorState.rowConditions[r] or ""
            if cond ~= "" and Wise.NegateConditional then
                local negated = Wise:NegateConditional(cond)
                if negated then
                    tinsert(exclusions, negated)
                end
            end
        end
    end

    if #exclusions > 0 then
        cp.inheritedLabel:SetText("|cff888888Inherits: " .. table.concat(exclusions, " ") .. "|r")
        cp.inheritedLabel:Show()
    else
        cp.inheritedLabel:SetText("")
        cp.inheritedLabel:Hide()
    end
end

-- ═══════════════════════════════════════════════════════════════
-- Main UI Creation
-- ═══════════════════════════════════════════════════════════════
function Wise:CreateSlotConfiguratorUI(host)
    local sc = Wise.SlotConfigurator
    if sc and sc.host == host then
        -- Reuse existing UI
        sc.cancelBtn:Show()
        sc.titleLabel:Show()
        sc.divider:Show()
        sc.canvasScroll:Show()
        -- Hide toolbar items when condition picker is open (they'd overlap)
        if Wise.pickingCondition then
            sc.modPalette:Hide()
            sc.applyBtn:Hide()
            sc.infoLabel:Hide()
        else
            sc.modPalette:Show()
            sc.applyBtn:Show()
            sc.infoLabel:Show()
        end
        RenderCanvas()
        return
    end

    sc = {}
    Wise.SlotConfigurator = sc
    sc.host = host

    -- Row 1: < Back | Title | [Modifiers] | Info | Apply
    -- Back button
    sc.cancelBtn = CreateFrame("Button", nil, host, "GameMenuButtonTemplate")
    sc.cancelBtn:SetSize(70, 22)
    sc.cancelBtn:SetPoint("TOPLEFT", 8, -8)
    sc.cancelBtn:SetText("< Back")
    sc.cancelBtn:SetScript("OnClick", function()
        -- Close condition picker if open
        Wise.pickingCondition = false
        Wise._conditionPickerState = nil
        Wise._configuratorConditionRow = nil
        Wise.configuringSlot = false
        Wise.configuringSlotGroup = nil
        Wise.configuringSlotIdx = nil
        HideAllModDropZones()
        Wise._configuratorPickTarget = nil
        Wise:RefreshPropertiesPanel()
    end)

    -- Title
    sc.titleLabel = host:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sc.titleLabel:SetPoint("LEFT", sc.cancelBtn, "RIGHT", 8, 0)
    sc.titleLabel:SetText("Slot Configurator")

    -- Modifier palette (same row, after title)
    sc.modPalette = CreateModifierPalette(host)
    sc.modPalette:SetPoint("LEFT", sc.titleLabel, "RIGHT", 12, 0)

    -- Apply button (right-aligned)
    sc.applyBtn = CreateFrame("Button", nil, host, "GameMenuButtonTemplate")
    sc.applyBtn:SetSize(110, 22)
    sc.applyBtn:SetPoint("TOPRIGHT", -8, -8)
    sc.applyBtn:SetText("Apply Changes")
    sc.applyBtn:SetScript("OnClick", function()
        ExportToSlotData()
        sc.applyBtn:SetText("Applied!")
        C_Timer.After(1.2, function()
            if sc.applyBtn then sc.applyBtn:SetText("Apply Changes") end
        end)
    end)
    Wise:AddTooltip(sc.applyBtn, "Save changes back to the slot data and update the interface display.")

    -- Info label (right of modifiers, before apply)
    sc.infoLabel = host:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sc.infoLabel:SetPoint("RIGHT", sc.applyBtn, "LEFT", -10, 0)
    sc.infoLabel:SetText("")

    -- Divider line
    sc.divider = host:CreateTexture(nil, "ARTWORK")
    sc.divider:SetColorTexture(0.3, 0.3, 0.3, 0.8)
    sc.divider:SetHeight(1)
    sc.divider:SetPoint("TOPLEFT", host, "TOPLEFT", 8, -34)
    sc.divider:SetPoint("TOPRIGHT", host, "TOPRIGHT", -8, -34)

    -- Canvas scroll (starts right below divider)
    sc.canvasScroll = CreateFrame("ScrollFrame", nil, host, "UIPanelScrollFrameTemplate")
    sc.canvasScroll:SetPoint("TOPLEFT", host, "TOPLEFT", 8, -38)
    sc.canvasScroll:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -28, 8)

    sc.canvas = CreateFrame("Frame", nil, sc.canvasScroll)
    sc.canvas:SetSize(800, 400)
    sc.canvasScroll:SetScrollChild(sc.canvas)

    RenderCanvas()
end

-- ═══════════════════════════════════════════════════════════════
-- Entry Point
-- ═══════════════════════════════════════════════════════════════
function Wise:OpenSlotConfigurator(groupName, slotIdx)
    if InCombatLockdown() then
        print("|cff00ccff[Wise]|r Cannot open configurator during combat.")
        return
    end

    -- Import data
    ImportSlotData(groupName, slotIdx)

    -- Set flags
    Wise.configuringSlot = true
    Wise.configuringSlotGroup = groupName
    Wise.configuringSlotIdx = slotIdx

    -- Trigger overlay
    Wise:RefreshPropertiesPanel()
end

-- ═══════════════════════════════════════════════════════════════
-- Close helper (for use by other modules)
-- ═══════════════════════════════════════════════════════════════
function Wise:CloseSlotConfigurator()
    if not Wise.configuringSlot then return end
    Wise.pickingCondition = false
    Wise._conditionPickerState = nil
    Wise._configuratorConditionRow = nil
    Wise.configuringSlot = false
    Wise.configuringSlotGroup = nil
    Wise.configuringSlotIdx = nil
    Wise._configuratorPickTarget = nil
    HideAllModDropZones()
    Wise:RefreshPropertiesPanel()
end
