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

-- A stacked cell shows N actions vertically. The first action uses the full
-- CELL_HEIGHT; each additional stacked action adds STACK_ROW_HEIGHT and gets a
-- compact mini-row inside the cell.
local STACK_ROW_HEIGHT = 28
local STACK_ICON_SIZE = 22

-- Nodes view constants (vertical flow, Image #3 style)
local NODE_ICON_SIZE = 56
local NODE_CARD_WIDTH = 260
local NODE_CARD_HEIGHT = 68
local NODE_V_SPACING = 36 -- arrow gap between nodes
local NODE_HEADER_HEIGHT = 80 -- play-button header area
local NODE_COND_OFFSET = 14 -- horizontal offset of the condition bubble from the icon

-- Modifier break colors
local MOD_COLORS = {
	shift = { r = 0.85, g = 0.55, b = 0.1 },
	alt = { r = 0.15, g = 0.7, b = 0.35 },
	ctrl = { r = 0.2, g = 0.45, b = 0.85 },
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
	-- modBreaks[afterRow] = "shift" | "alt" | "ctrl" | nil — visual hint between rows
	modBreaks = {},
	-- rowMods[row] = { shift = true, alt = true, ... } — actual per-row modifiers
	rowMods = {},
	-- rowExclusive[row] = true/false (auto-negate other rows)
	rowExclusive = {},
	numCols = 1,
	numRows = 1,
	-- Drag state
	dragActive = false,
	dragSourceRow = nil,
	dragSourceCol = nil,
	dragAction = nil,
	-- Active tab: "grid" (existing table view) or "nodes" (vertical flow, Image #3)
	activeTab = "grid",
}

-- Nodes-view UI element pools
local nodeCardPool = {}
local nodeArrowPool = {}
local nodeCondBubblePool = {}

-- Forward declarations
local ActionPassesFilter
local IsFilterHiding
local IsActionLive
local HideAllModDropZones
local RenderConditionalList
local RenderNodesCanvas
local RenderActiveTab

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
	if not action then
		return nil
	end
	local copy = {}
	for k, v in pairs(action) do
		if type(v) == "table" then
			-- Shallow copy nested tables (visibilityEnable, visibilityDisable)
			local sub = {}
			for sk, sv in pairs(v) do
				sub[sk] = sv
			end
			copy[k] = sub
		else
			copy[k] = v
		end
	end
	return copy
end

-- ═══════════════════════════════════════════════════════════════
-- Cell helpers
-- ═══════════════════════════════════════════════════════════════
-- A grid cell is a list of action records (the "stack" of actions that fire
-- together as a waterfall under the row's condition at this step). nil and
-- {} both mean "empty cell". CellList returns the underlying list creating it
-- on demand; CellHead returns the first action for icon/preview purposes.
local function CellList(r, c, create)
	local state = configuratorState
	if not state.grid[r] then
		if not create then
			return nil
		end
		state.grid[r] = {}
	end
	local cell = state.grid[r][c]
	if not cell then
		if not create then
			return nil
		end
		cell = {}
		state.grid[r][c] = cell
	end
	return cell
end

local function CellSetSingle(r, c, action)
	local state = configuratorState
	if not state.grid[r] then
		state.grid[r] = {}
	end
	if action then
		state.grid[r][c] = { action }
	else
		state.grid[r][c] = nil
	end
end

local function CellRemoveAt(r, c, index)
	local cell = CellList(r, c, false)
	if not cell then
		return
	end
	table.remove(cell, index)
	if #cell == 0 then
		configuratorState.grid[r][c] = nil
	end
end

-- Swap entire cells (full stacks) between (r1,c1) and (r2,c2).
local function CellSwap(r1, c1, r2, c2)
	local state = configuratorState
	if not state.grid[r1] then
		state.grid[r1] = {}
	end
	if not state.grid[r2] then
		state.grid[r2] = {}
	end
	local a = state.grid[r1][c1]
	state.grid[r1][c1] = state.grid[r2][c2]
	state.grid[r2][c2] = a
end

-- Returns true if any action in the given cell stack is hidden by the current
-- filter (i.e. belongs to a different toon/spec/class than the user is
-- currently viewing). Destructive operations on a region containing hidden
-- actions are blocked so that one spec/class can't silently delete data
-- belonging to another.
local function CellHasHidden(r, c)
	local cell = configuratorState.grid[r] and configuratorState.grid[r][c]
	if not cell or #cell == 0 then
		return false
	end
	for i = 1, #cell do
		if IsFilterHiding(cell[i]) then
			return true
		end
	end
	return false
end

local function ColumnHasHidden(c)
	local state = configuratorState
	for r = 1, state.numRows do
		if CellHasHidden(r, c) then
			return true
		end
	end
	return false
end

local function RowHasHidden(r)
	local state = configuratorState
	for c = 1, state.numCols do
		if CellHasHidden(r, c) then
			return true
		end
	end
	return false
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
	if not groups or #groups == 0 then
		return ""
	end

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
	if not condStr or condStr == "" then
		return {}, condStr
	end
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

-- Apply a mod-break drop: rows below afterRow (until the next break or the end of
-- the grid) gain the dropped modifier. rowMods is the source of truth; modBreaks is
-- the cosmetic marker between rows whose mods differ.
local function ApplyBreakDrop(afterRow, mod)
	local state = configuratorState
	if not mod or not afterRow then
		return
	end
	state.modBreaks[afterRow] = mod
	-- Find the next break below afterRow to bound the zone.
	local nextBreak = state.numRows
	for ar in pairs(state.modBreaks) do
		if ar > afterRow and ar < nextBreak then
			nextBreak = ar
		end
	end
	for r = afterRow + 1, nextBreak do
		state.rowMods[r] = state.rowMods[r] or {}
		state.rowMods[r][mod] = true
	end
end

-- Remove a mod-break marker and clear the mod it introduced from rows in its zone.
local function RemoveBreak(afterRow)
	local state = configuratorState
	local mod = state.modBreaks[afterRow]
	state.modBreaks[afterRow] = nil
	if not mod then
		return
	end
	local nextBreak = state.numRows
	for ar in pairs(state.modBreaks) do
		if ar > afterRow and ar < nextBreak then
			nextBreak = ar
		end
	end
	for r = afterRow + 1, nextBreak do
		if state.rowMods[r] then
			state.rowMods[r][mod] = nil
		end
	end
end

-- Build a stable key for a mod set so two actions with the same modifiers group together.
local function ModSetKey(mods)
	if not mods then
		return ""
	end
	local keys = {}
	for m in pairs(mods) do
		tinsert(keys, m)
	end
	table.sort(keys)
	return table.concat(keys, ",")
end

local function ImportSlotData(groupName, slotIdx)
	local state = configuratorState
	state.groupName = groupName
	state.slotIdx = slotIdx
	state.grid = {}
	state.rowConditions = {}
	state.modBreaks = {}
	state.rowMods = {}
	state.rowExclusive = {}

	local group = WiseDB and WiseDB.groups and WiseDB.groups[groupName]
	if not group or not group.actions then
		return
	end
	Wise:MigrateGroupToActions(group)

	local actions = group.actions[slotIdx]
	if not actions then
		return
	end

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
		state.rowMods[1] = {}
		state.rowExclusive[1] = false
		return
	end

	-- Parse modifiers out of conditions, group by (baseCond, modSet)
	local parsed = {} -- { action, mods, baseCond, modKey }
	for _, a in ipairs(items) do
		local mods, base = ParseModifiers(a.conditions)
		tinsert(parsed, { action = a, mods = mods, baseCond = base or "", modKey = ModSetKey(mods) })
	end

	-- Group actions sharing the same (baseCond, modKey). The saved
	-- conflictStrategy decides how multi-action groups lay out:
	--   waterfall → all actions stack into the same cell (column 1) and fire
	--               together on press.
	--   sequence  → actions spread across columns and cycle on repeat press.
	-- Different baseConds OR different mod sets become separate rows so
	-- per-row mods are preserved exactly through round-trip.
	local strategy = actions.conflictStrategy
	if strategy ~= "sequence" then
		strategy = "waterfall"
	end

	local condGroups = {} -- "baseCond|modKey" -> { actions }
	local condOrder = {}
	for _, p in ipairs(parsed) do
		local key = p.baseCond .. "|" .. p.modKey
		if not condGroups[key] then
			condGroups[key] = { items = {}, baseCond = p.baseCond, mods = p.mods }
			tinsert(condOrder, key)
		end
		tinsert(condGroups[key].items, p)
	end

	local maxCols = 1
	local prevModKey = nil
	local row = 0
	for _, key in ipairs(condOrder) do
		row = row + 1
		state.grid[row] = {}
		local g = condGroups[key]
		state.rowConditions[row] = g.baseCond
		state.rowMods[row] = {}
		for m in pairs(g.mods) do
			state.rowMods[row][m] = true
		end
		state.rowExclusive[row] = (g.items[1] and g.items[1].action.exclusive) or false
		if strategy == "waterfall" then
			-- All actions in this group stack into a single cell at column 1.
			local stack = {}
			for _, p in ipairs(g.items) do
				tinsert(stack, p.action)
			end
			state.grid[row][1] = stack
		else
			-- Sequence: each action takes its own column as a single-action stack.
			for col, p in ipairs(g.items) do
				state.grid[row][col] = { p.action }
				if col > maxCols then
					maxCols = col
				end
			end
		end

		-- Visual break between rows whose mods differ. Pick any new mod for the break label.
		local thisModKey = ModSetKey(g.mods)
		if row > 1 and thisModKey ~= prevModKey then
			for m in pairs(g.mods) do
				if m == "shift" or m == "alt" or m == "ctrl" then
					state.modBreaks[row - 1] = m
					break
				end
			end
		end
		prevModKey = thisModKey
	end
	state.numRows = row
	state.numCols = maxCols

	-- Ensure at least 1 row and 1 col
	if state.numRows < 1 then
		state.numRows = 1
	end
	if state.numCols < 1 then
		state.numCols = 1
	end
	if not state.grid[1] then
		state.grid[1] = {}
	end
	if not state.rowConditions[1] then
		state.rowConditions[1] = ""
	end
	if not state.rowMods[1] then
		state.rowMods[1] = {}
	end
end

-- ═══════════════════════════════════════════════════════════════
-- Export: Grid -> Slot Data
-- ═══════════════════════════════════════════════════════════════
local function ExportToSlotData()
	-- Guard: only export when we have valid state
	if not configuratorState.groupName or not configuratorState.slotIdx then
		return
	end
	local state = configuratorState
	local groupName = state.groupName
	local slotIdx = state.slotIdx

	local group = WiseDB and WiseDB.groups and WiseDB.groups[groupName]
	if not group or not group.actions then
		return
	end

	local actions = group.actions[slotIdx]
	if not actions then
		return
	end

	-- Determine max columns actually used (a column counts if any row has a
	-- non-empty stack at that column).
	local maxCol = 0
	for r = 1, state.numRows do
		if state.grid[r] then
			for c = 1, state.numCols do
				local cell = state.grid[r][c]
				if cell and #cell > 0 then
					if c > maxCol then
						maxCol = c
					end
				end
			end
		end
	end

	-- Strategy is derived from grid shape: a single column is waterfall (one /cast
	-- macro stacks any matching rows), multiple columns within a row form a sequence
	-- (cycle through columns on each press). Stacked actions within a single cell
	-- always fire together — they don't change the strategy choice.
	local strategy = (maxCol > 1) and "sequence" or "waterfall"

	-- Each row carries its own mod set in state.rowMods (populated on import or by
	-- mod-break drag-drop). Export emits those mods verbatim — no cumulative
	-- accumulation across rows, so a row with no mod stays mod-free even if a
	-- different row above it has one.
	local rowMods = state.rowMods or {}

	-- Build actions array
	local newActions = {}
	-- Preserve hash keys
	newActions.conflictStrategy = strategy
	newActions.keybind = actions.keybind
	newActions.resetOnCombat = actions.resetOnCombat
	newActions.suppressErrors = actions.suppressErrors
	newActions.pressAndHold = actions.pressAndHold

	for r = 1, state.numRows do
		if state.grid[r] then
			for c = 1, state.numCols do
				local cell = state.grid[r][c]
				if cell and #cell > 0 then
					-- Build conditions: baseCond + accumulated mods, computed
					-- once per cell so every stacked action in this cell shares
					-- the same condition string.
					local baseCond = state.rowConditions[r] or ""
					local modParts = {}
					if rowMods[r] then
						for m in pairs(rowMods[r]) do
							tinsert(modParts, "mod:" .. m)
						end
					end

					local conditions
					if #modParts > 0 then
						local modStr = table.concat(modParts, ",")
						if baseCond ~= "" then
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
							conditions = merged
						else
							conditions = "[" .. modStr .. "]"
						end
					else
						conditions = baseCond
					end

					for i = 1, #cell do
						local exported = ShallowCopyAction(cell[i])
						exported.conditions = conditions
						exported.exclusive = state.rowExclusive[r] or false
						tinsert(newActions, exported)
					end
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

-- Expose for use by other modules (Options.lua close paths)
function Wise:ExportSlotConfiguratorData()
	ExportToSlotData()
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
		tile = true,
		tileSize = 16,
		edgeSize = 12,
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

	-- Pool of stack-row frames inside this cell (for actions 2..N).
	cell.stackRows = {}
	cell.GetStackRow = function(self, idx)
		if self.stackRows[idx] then
			return self.stackRows[idx]
		end
		local row = CreateFrame("Button", nil, self, "BackdropTemplate")
		row:SetHeight(STACK_ROW_HEIGHT)
		row:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true,
			tileSize = 16,
			edgeSize = 8,
			insets = { left = 1, right = 1, top = 1, bottom = 1 },
		})
		row:SetBackdropColor(0.16, 0.16, 0.18, 0.9)
		row:SetBackdropBorderColor(0.35, 0.35, 0.4, 0.8)

		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(STACK_ICON_SIZE, STACK_ICON_SIZE)
		row.icon:SetPoint("LEFT", 3, 0)
		row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

		row.nameLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.nameLabel:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
		row.nameLabel:SetPoint("RIGHT", -18, 0)
		row.nameLabel:SetJustifyH("LEFT")
		row.nameLabel:SetMaxLines(1)

		row.removeBtn = CreateFrame("Button", nil, row)
		row.removeBtn:SetSize(12, 12)
		row.removeBtn:SetPoint("RIGHT", -2, 0)
		row.removeBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
		row.removeBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")

		row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
		row.highlight:SetAllPoints()
		row.highlight:SetColorTexture(1, 0.82, 0, 0.1)

		self.stackRows[idx] = row
		return row
	end

	-- "+" affordance to push another stacked action onto this cell.
	cell.addStackBtn = CreateFrame("Button", nil, cell)
	cell.addStackBtn:SetSize(STACK_ROW_HEIGHT, STACK_ROW_HEIGHT)
	cell.addStackBtn.label = cell.addStackBtn:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	cell.addStackBtn.label:SetPoint("CENTER")
	cell.addStackBtn.label:SetText("+")
	cell.addStackBtn.label:SetFont(cell.addStackBtn.label:GetFont(), 16, "OUTLINE")
	cell.addStackBtn.highlight = cell.addStackBtn:CreateTexture(nil, "HIGHLIGHT")
	cell.addStackBtn.highlight:SetAllPoints()
	cell.addStackBtn.highlight:SetColorTexture(0.2, 0.8, 0.2, 0.2)
	cell.addStackBtn:Hide()

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
		tile = true,
		tileSize = 16,
		edgeSize = 12,
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
		tile = true,
		tileSize = 16,
		edgeSize = 10,
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
		tile = true,
		tileSize = 16,
		edgeSize = 8,
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
	if configDragGhost then
		return configDragGhost
	end
	configDragGhost = CreateFrame("Frame", "WiseConfigDragGhost", UIParent, "BackdropTemplate")
	configDragGhost:SetFrameStrata("TOOLTIP")
	configDragGhost:SetSize(CELL_WIDTH, CELL_HEIGHT)
	configDragGhost:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 12,
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
-- Nodes View Pool Hiding
-- ═══════════════════════════════════════════════════════════════
local function HideAllNodePooled()
	for _, c in pairs(nodeCardPool) do
		c:Hide()
		if c.stackRows then
			for _, sr in pairs(c.stackRows) do
				sr:Hide()
			end
		end
		if c.addStackBtn then
			c.addStackBtn:Hide()
		end
	end
	for _, a in pairs(nodeArrowPool) do
		a:Hide()
	end
	for _, b in pairs(nodeCondBubblePool) do
		b:Hide()
	end
end

-- ═══════════════════════════════════════════════════════════════
-- Canvas Rendering
-- ═══════════════════════════════════════════════════════════════
local function HideAllPooled()
	for _, c in pairs(cellPool) do
		c:Hide()
		if c.stackRows then
			for _, sr in pairs(c.stackRows) do
				sr:Hide()
			end
		end
		if c.addStackBtn then
			c.addStackBtn:Hide()
		end
	end
	for _, c in pairs(emptyDropPool) do
		c:Hide()
	end
	for _, c in pairs(colHeaderPool) do
		c:Hide()
	end
	for _, c in pairs(rowHeaderPool) do
		c:Hide()
	end
	for _, c in pairs(modBreakPool) do
		c:Hide()
	end
	HideAllModDropZones()
	if configInsertIndicator then
		configInsertIndicator:Hide()
	end
	if rowInsertIndicator then
		rowInsertIndicator:Hide()
	end
end

local function RenderCanvas()
	local sc = Wise.SlotConfigurator
	if not sc or not sc.canvas then
		return
	end

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

		-- Remove column button (only if more than 1 column). Disabled when
		-- the column contains actions that belong to other specs/classes than
		-- the current filter — otherwise removing a column from one spec
		-- would silently destroy data the user can't see.
		if state.numCols > 1 then
			hdr.removeBtn:Show()
			local removeCol = c
			local blocked = ColumnHasHidden(removeCol)
			if blocked then
				hdr.removeBtn:GetNormalTexture():SetDesaturated(true)
				hdr.removeBtn:SetAlpha(0.4)
				hdr.removeBtn:SetScript("OnClick", function()
					GameTooltip:SetOwner(hdr.removeBtn, "ANCHOR_RIGHT")
					GameTooltip:SetText("Cannot remove step", 1, 0.4, 0.4)
					GameTooltip:AddLine("This step contains actions for other specs or classes.", 0.9, 0.9, 0.9, true)
					GameTooltip:AddLine("Switch the filter to All to remove it.", 0.7, 0.7, 0.7, true)
					GameTooltip:Show()
				end)
			else
				hdr.removeBtn:GetNormalTexture():SetDesaturated(false)
				hdr.removeBtn:SetAlpha(1)
				hdr.removeBtn:SetScript("OnClick", function()
					for r = 1, state.numRows do
						if state.grid[r] then
							table.remove(state.grid[r], removeCol)
						end
					end
					state.numCols = state.numCols - 1
					if state.numCols < 1 then
						state.numCols = 1
					end
					RenderCanvas()
				end)
			end
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
		addColHdr.clickBtn:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
	end

	local yOffset = y0

	-- Track row Y positions for modifier drop zones
	local sc = Wise.SlotConfigurator
	if sc then
		sc._rowYPositions = {}
	end

	-- Decide up-front which rows are wholly hidden by the current filter, so
	-- we can skip both the row content and the mod break that would sit
	-- above it. A row is hidden only when it has at least one populated
	-- cell and *every* action across every cell stack is filter-rejected;
	-- rows that are entirely empty still render as drop targets.
	local rowHidden = {}
	-- Per-row tallest stack so each row gets just enough vertical space.
	local rowStackHeight = {}
	for r = 1, state.numRows do
		if state.grid[r] then
			local anyAction, anyVisible = false, false
			local maxStack = 1
			for c = 1, state.numCols do
				local cell = state.grid[r][c]
				if cell and #cell > 0 then
					anyAction = true
					if #cell > maxStack then
						maxStack = #cell
					end
					for i = 1, #cell do
						if not IsFilterHiding(cell[i]) then
							anyVisible = true
						end
					end
				end
			end
			rowHidden[r] = anyAction and not anyVisible
			rowStackHeight[r] = maxStack
		else
			rowStackHeight[r] = 1
		end
	end

	-- Render rows
	for r = 1, state.numRows do
		if not state.grid[r] then
			state.grid[r] = {}
		end

		if rowHidden[r] then
			-- Skip this row entirely; its mod break (if any) is suppressed too
			-- since it would otherwise detach from both neighbours.
		else
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
					RemoveBreak(breakRow)
					RenderCanvas()
				end)

				brk:Show()
				yOffset = yOffset - MOD_BREAK_HEIGHT - 4
			end

			-- Store row Y position for modifier drop zones
			if sc then
				sc._rowYPositions[r] = yOffset
			end

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

			-- Row remove button (only if more than 1 row). Disabled when the row
			-- contains actions hidden by the current filter — see column-remove
			-- for the rationale.
			if state.numRows > 1 then
				rowHdr.rowRemoveBtn:Show()
				local removeRow = r
				local rowBlocked = RowHasHidden(removeRow)
				if rowBlocked then
					rowHdr.rowRemoveBtn:GetNormalTexture():SetDesaturated(true)
					rowHdr.rowRemoveBtn:SetAlpha(0.4)
					rowHdr.rowRemoveBtn:SetScript("OnClick", function()
						GameTooltip:SetOwner(rowHdr.rowRemoveBtn, "ANCHOR_RIGHT")
						GameTooltip:SetText("Cannot remove row", 1, 0.4, 0.4)
						GameTooltip:AddLine(
							"This row contains actions for other specs or classes.",
							0.9,
							0.9,
							0.9,
							true
						)
						GameTooltip:AddLine("Switch the filter to All to remove it.", 0.7, 0.7, 0.7, true)
						GameTooltip:Show()
					end)
				else
					rowHdr.rowRemoveBtn:GetNormalTexture():SetDesaturated(false)
					rowHdr.rowRemoveBtn:SetAlpha(1)
					rowHdr.rowRemoveBtn:SetScript("OnClick", function()
						table.remove(state.grid, removeRow)
						table.remove(state.rowConditions, removeRow)
						table.remove(state.rowExclusive, removeRow)
						table.remove(state.rowMods, removeRow)
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
							state.rowMods[1] = {}
						end
						RenderCanvas()
					end)
				end
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
			rowHdr:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)
			rowHdr:Show()

			-- Row's vertical extent: tallest stack in the row dictates row height.
			local rowMaxStack = rowStackHeight[r] or 1
			local rowHeight = CELL_HEIGHT + math.max(0, rowMaxStack - 1) * STACK_ROW_HEIGHT

			-- Cells for this row
			for c = 1, state.numCols do
				local cellList = state.grid[r] and state.grid[r][c]
				local stackSize = (cellList and #cellList) or 0
				local cellX = x0 + (c - 1) * (CELL_WIDTH + CELL_PADDING)

				-- A populated cell is filter-hidden only if every action in its
				-- stack is filter-rejected. Mixed cells render only the visible
				-- entries.
				local anyVisible = false
				if stackSize > 0 then
					for i = 1, stackSize do
						if not IsFilterHiding(cellList[i]) then
							anyVisible = true
							break
						end
					end
				end

				if stackSize > 0 and not anyVisible then
				-- Whole stack filter-hidden; render nothing here.
				elseif stackSize > 0 then
					local head = cellList[1]
					local cellHeight = CELL_HEIGHT + (stackSize - 1) * STACK_ROW_HEIGHT
					local cell = GetOrCreateCell(canvas, cellIdx)
					cellIdx = cellIdx + 1
					cell:SetSize(CELL_WIDTH, cellHeight)
					cell:ClearAllPoints()
					cell:SetPoint("TOPLEFT", canvas, "TOPLEFT", cellX, yOffset)

					local iconTex = Wise:GetActionIcon(head.type, head.value, head)
					cell.icon:SetTexture(iconTex or "Interface\\Icons\\INV_Misc_QuestionMark")
					cell.icon:Show()

					local name = Wise:GetActionName(head.type, head.value, head) or "Unknown"
					cell.nameLabel:SetText(name)

					if IsActionLive(head) then
						cell:SetAlpha(1)
						cell:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
					else
						cell:SetAlpha(0.45)
						cell:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)
					end

					-- Head remove button: removes the head; if the cell still has
					-- a stack the next item promotes; if empty the cell clears.
					cell.removeBtn:Show()
					local headRow, headCol = r, c
					cell.removeBtn:SetScript("OnClick", function()
						CellRemoveAt(headRow, headCol, 1)
						RenderCanvas()
					end)

					-- Hide stack rows that aren't in use this render. We have to
					-- explicitly hide any pooled stack-row beyond the current
					-- stack size in case the cell shrank since last render.
					if cell.stackRows then
						for _, sr in pairs(cell.stackRows) do
							sr:Hide()
						end
					end

					-- Render stack rows for entries 2..N below the head.
					for i = 2, stackSize do
						local stacked = cellList[i]
						local sr = cell:GetStackRow(i)
						sr:SetWidth(CELL_WIDTH - 4)
						sr:ClearAllPoints()
						sr:SetPoint("TOPLEFT", cell, "TOPLEFT", 2, -(CELL_HEIGHT + (i - 2) * STACK_ROW_HEIGHT))

						local sIcon = Wise:GetActionIcon(stacked.type, stacked.value, stacked)
						sr.icon:SetTexture(sIcon or "Interface\\Icons\\INV_Misc_QuestionMark")
						local sName = Wise:GetActionName(stacked.type, stacked.value, stacked) or "Unknown"
						sr.nameLabel:SetText(sName)
						if IsActionLive(stacked) then
							sr:SetAlpha(1)
						else
							sr:SetAlpha(0.5)
						end

						local rmRow, rmCol, rmIdx = r, c, i
						sr.removeBtn:SetScript("OnClick", function()
							CellRemoveAt(rmRow, rmCol, rmIdx)
							RenderCanvas()
						end)

						local stackedType = stacked.type
						sr:SetScript("OnEnter", function(self)
							GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
							GameTooltip:SetText(sName, 1, 1, 1)
							if stackedType then
								GameTooltip:AddLine("Type: " .. stackedType, 0.8, 0.8, 0.8)
							end
							GameTooltip:AddLine("Stacked — fires together with this step.", 0.7, 0.7, 0.9, true)
							GameTooltip:Show()
						end)
						sr:SetScript("OnLeave", function()
							GameTooltip:Hide()
						end)
						sr:Show()
					end

					-- "+" inside the cell appends another stacked action.
					cell.addStackBtn:ClearAllPoints()
					cell.addStackBtn:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -2, 2)
					local pushRow, pushCol = r, c
					cell.addStackBtn:SetScript("OnClick", function()
						Wise:OpenConfiguratorPicker(pushRow, pushCol, "stack")
					end)
					cell.addStackBtn:SetScript("OnEnter", function(self)
						GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
						GameTooltip:SetText("Stack action", 1, 1, 1)
						GameTooltip:AddLine(
							"Add another action that fires together with this one.",
							0.8,
							0.8,
							0.8,
							true
						)
						GameTooltip:Show()
					end)
					cell.addStackBtn:SetScript("OnLeave", function()
						GameTooltip:Hide()
					end)
					cell.addStackBtn:Show()

					-- Drag handling moves the entire stack.
					local dragRow, dragCol = r, c
					cell:RegisterForDrag("LeftButton")
					cell:SetScript("OnDragStart", function(self)
						if InCombatLockdown() then
							return
						end
						configuratorState.dragActive = true
						configuratorState.dragSourceRow = dragRow
						configuratorState.dragSourceCol = dragCol
						configuratorState.dragAction = state.grid[dragRow][dragCol]

						local ghost = GetOrCreateConfigDragGhost()
						ghost.icon:SetTexture(iconTex or "Interface\\Icons\\INV_Misc_QuestionMark")
						ghost.nameLabel:SetText(name)
						ghost:Show()

						self:SetAlpha(0.4)

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

						if not configuratorState.dragActive then
							return
						end
						configuratorState.dragActive = false

						local cx, cy = GetCursorPosition()
						local scale = UIParent:GetEffectiveScale()
						cx, cy = cx / scale, cy / scale

						local dropped = false
						for _, cf in pairs(cellPool) do
							if cf:IsShown() and cf ~= self then
								local l, b, w, h = cf:GetRect()
								if l and cx >= l and cx <= l + w and cy >= b and cy <= b + h then
									local tr, tc = cf.gridRow, cf.gridCol
									if tr and tc then
										CellSwap(
											configuratorState.dragSourceRow,
											configuratorState.dragSourceCol,
											tr,
											tc
										)
										dropped = true
									end
									break
								end
							end
						end

						if not dropped then
							for _, ef in pairs(emptyDropPool) do
								if ef:IsShown() then
									local l, b, w, h = ef:GetRect()
									if l and cx >= l and cx <= l + w and cy >= b and cy <= b + h then
										local tr, tc = ef.gridRow, ef.gridCol
										if tr and tc then
											state.grid[configuratorState.dragSourceRow][configuratorState.dragSourceCol] =
												nil
											if not state.grid[tr] then
												state.grid[tr] = {}
											end
											state.grid[tr][tc] = configuratorState.dragAction
											dropped = true
										end
										break
									end
								end
							end
						end

						configuratorState.dragAction = nil
						configuratorState.dragSourceRow = nil
						configuratorState.dragSourceCol = nil
						RenderCanvas()
					end)

					local headType = head.type
					local stackForTip = stackSize
					cell:SetScript("OnEnter", function(self)
						GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
						GameTooltip:SetText(name, 1, 1, 1)
						if headType then
							GameTooltip:AddLine("Type: " .. headType, 0.8, 0.8, 0.8)
						end
						if stackForTip > 1 then
							GameTooltip:AddLine(
								"Stack of " .. stackForTip .. " actions — all fire together.",
								0.7,
								0.7,
								0.9,
								true
							)
						end
						GameTooltip:AddLine(" ")
						GameTooltip:AddLine("Drag to move. + to stack. X to remove.", 0.6, 0.6, 0.6, true)
						GameTooltip:Show()
					end)
					cell:SetScript("OnLeave", function()
						GameTooltip:Hide()
					end)

					cell.gridRow = r
					cell.gridCol = c
					cell:Show()
				else
					-- Empty drop target. Sized to match the row's tallest stack so
					-- the empty slot still aligns with neighbour cells.
					local drop = GetOrCreateEmptyDrop(canvas, emptyIdx)
					emptyIdx = emptyIdx + 1
					drop:SetSize(CELL_WIDTH, rowHeight)
					drop:ClearAllPoints()
					drop:SetPoint("TOPLEFT", canvas, "TOPLEFT", cellX, yOffset)
					drop.gridRow = r
					drop.gridCol = c

					drop:RegisterForClicks("LeftButtonUp")
					local dropRow, dropCol = r, c
					drop:SetScript("OnClick", function(self)
						local cursorType, id = GetCursorInfo()
						if cursorType then
							local actionData = Wise:CursorToActionData(cursorType, id)
							if actionData then
								CellSetSingle(dropRow, dropCol, actionData)
								ClearCursor()
								RenderCanvas()
							end
						else
							Wise:OpenConfiguratorPicker(dropRow, dropCol)
						end
					end)

					drop:SetScript("OnReceiveDrag", function(self)
						local cursorType, id = GetCursorInfo()
						if cursorType then
							local actionData = Wise:CursorToActionData(cursorType, id)
							if actionData then
								CellSetSingle(dropRow, dropCol, actionData)
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
					drop:SetScript("OnLeave", function()
						GameTooltip:Hide()
					end)

					drop:Show()
				end
			end

			yOffset = yOffset - rowHeight - CELL_PADDING
		end -- end of: if not rowHidden[r]
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
			-- Inherit the previous row's mods so a new row at the bottom of an
			-- existing mod zone stays inside that zone rather than dropping out.
			local inherit = state.rowMods[state.numRows - 1] or {}
			local copy = {}
			for m in pairs(inherit) do
				copy[m] = true
			end
			state.rowMods[state.numRows] = copy
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
		if state.numCols > 1 then
			strat = "Sequence (" .. state.numCols .. " steps)"
		end
		sc.infoLabel:SetText(
			"Layout: " .. state.numRows .. " row(s), " .. state.numCols .. " step(s) | Mode: " .. strat
		)
	end
end

-- ═══════════════════════════════════════════════════════════════
-- Nodes View Factories
-- ═══════════════════════════════════════════════════════════════
local function GetOrCreateNodeCard(parent, index)
	if nodeCardPool[index] then
		nodeCardPool[index]:SetParent(parent)
		return nodeCardPool[index]
	end

	local card = CreateFrame("Button", nil, parent, "BackdropTemplate")
	card:SetSize(NODE_CARD_WIDTH, NODE_CARD_HEIGHT)
	card:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 12,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	card:SetBackdropColor(0.10, 0.10, 0.14, 0.95)
	card:SetBackdropBorderColor(0.45, 0.45, 0.55, 1)

	card.icon = card:CreateTexture(nil, "ARTWORK")
	card.icon:SetSize(NODE_ICON_SIZE, NODE_ICON_SIZE)
	card.icon:SetPoint("LEFT", 6, 0)
	card.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	card.iconBorder = card:CreateTexture(nil, "OVERLAY")
	card.iconBorder:SetPoint("TOPLEFT", card.icon, -2, 2)
	card.iconBorder:SetPoint("BOTTOMRIGHT", card.icon, 2, -2)
	card.iconBorder:SetColorTexture(0, 0.7, 1, 0.25)

	card.nameLabel = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	card.nameLabel:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 10, -2)
	card.nameLabel:SetPoint("RIGHT", -22, 0)
	card.nameLabel:SetJustifyH("LEFT")
	card.nameLabel:SetMaxLines(1)

	card.removeBtn = CreateFrame("Button", nil, card)
	card.removeBtn:SetSize(14, 14)
	card.removeBtn:SetPoint("TOPRIGHT", -4, -4)
	card.removeBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
	card.removeBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")

	card.highlight = card:CreateTexture(nil, "HIGHLIGHT")
	card.highlight:SetAllPoints()
	card.highlight:SetColorTexture(1, 0.82, 0, 0.1)

	-- Stack rows for actions 2..N inside this card.
	card.stackRows = {}
	card.GetStackRow = function(self, idx)
		if self.stackRows[idx] then
			return self.stackRows[idx]
		end
		local row = CreateFrame("Button", nil, self, "BackdropTemplate")
		row:SetHeight(STACK_ROW_HEIGHT)
		row:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true,
			tileSize = 16,
			edgeSize = 8,
			insets = { left = 1, right = 1, top = 1, bottom = 1 },
		})
		row:SetBackdropColor(0.14, 0.14, 0.18, 0.85)
		row:SetBackdropBorderColor(0.35, 0.35, 0.4, 0.7)

		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(STACK_ICON_SIZE, STACK_ICON_SIZE)
		row.icon:SetPoint("LEFT", 4, 0)
		row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

		row.nameLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.nameLabel:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
		row.nameLabel:SetPoint("RIGHT", -20, 0)
		row.nameLabel:SetJustifyH("LEFT")
		row.nameLabel:SetMaxLines(1)

		row.removeBtn = CreateFrame("Button", nil, row)
		row.removeBtn:SetSize(12, 12)
		row.removeBtn:SetPoint("RIGHT", -4, 0)
		row.removeBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
		row.removeBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")

		row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
		row.highlight:SetAllPoints()
		row.highlight:SetColorTexture(1, 0.82, 0, 0.1)

		self.stackRows[idx] = row
		return row
	end

	-- "+" affordance to push another stacked action onto this card's cell.
	card.addStackBtn = CreateFrame("Button", nil, card)
	card.addStackBtn:SetSize(STACK_ROW_HEIGHT, STACK_ROW_HEIGHT)
	card.addStackBtn.label = card.addStackBtn:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	card.addStackBtn.label:SetPoint("CENTER")
	card.addStackBtn.label:SetText("+")
	card.addStackBtn.label:SetFont(card.addStackBtn.label:GetFont(), 16, "OUTLINE")
	card.addStackBtn.highlight = card.addStackBtn:CreateTexture(nil, "HIGHLIGHT")
	card.addStackBtn.highlight:SetAllPoints()
	card.addStackBtn.highlight:SetColorTexture(0.2, 0.8, 0.2, 0.2)
	card.addStackBtn:Hide()

	nodeCardPool[index] = card
	return card
end

local function GetOrCreateNodeArrow(parent, index)
	if nodeArrowPool[index] then
		nodeArrowPool[index]:SetParent(parent)
		return nodeArrowPool[index]
	end

	local arrow = CreateFrame("Frame", nil, parent)
	arrow:SetSize(4, NODE_V_SPACING)

	arrow.line = arrow:CreateTexture(nil, "ARTWORK")
	arrow.line:SetColorTexture(0.2, 0.75, 1, 0.9)
	arrow.line:SetPoint("TOP", 0, 0)
	arrow.line:SetPoint("BOTTOM", 0, 6)
	arrow.line:SetWidth(3)

	arrow.head = arrow:CreateTexture(nil, "OVERLAY")
	arrow.head:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
	arrow.head:SetSize(16, 16)
	arrow.head:SetPoint("BOTTOM", 0, -2)
	arrow.head:SetVertexColor(0.2, 0.75, 1, 1)

	arrow.tagLabel = arrow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	arrow.tagLabel:SetPoint("LEFT", arrow, "RIGHT", 6, 0)
	arrow.tagLabel:SetTextColor(0.4, 0.85, 1, 1)

	nodeArrowPool[index] = arrow
	return arrow
end

local function GetOrCreateCondBubble(parent, index)
	if nodeCondBubblePool[index] then
		nodeCondBubblePool[index]:SetParent(parent)
		return nodeCondBubblePool[index]
	end

	local bubble = CreateFrame("Button", nil, parent, "BackdropTemplate")
	bubble:SetSize(140, 28)
	bubble:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 10,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	bubble:SetBackdropColor(0.14, 0.14, 0.18, 0.95)
	bubble:SetBackdropBorderColor(0.5, 0.5, 0.6, 1)

	bubble.label = bubble:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	bubble.label:SetPoint("LEFT", 8, 0)
	bubble.label:SetPoint("RIGHT", -8, 0)
	bubble.label:SetJustifyH("LEFT")
	bubble.label:SetMaxLines(1)

	bubble.highlight = bubble:CreateTexture(nil, "HIGHLIGHT")
	bubble.highlight:SetAllPoints()
	bubble.highlight:SetColorTexture(0.3, 0.6, 1, 0.15)

	nodeCondBubblePool[index] = bubble
	return bubble
end

-- ═══════════════════════════════════════════════════════════════
-- Nodes View Rendering (vertical flow, Image #3 style)
-- Shares the same configuratorState.grid as the Grid tab. Every populated
-- cell (row, col) in the grid becomes a node, ordered by row-then-column so
-- the same dataset is represented faithfully in both tabs. Entirely empty
-- rows still render a single placeholder card as a drop target.
-- ═══════════════════════════════════════════════════════════════
RenderNodesCanvas = function()
	local sc = Wise.SlotConfigurator
	if not sc or not sc.nodesCanvas then
		return
	end

	local canvas = sc.nodesCanvas
	local state = configuratorState

	HideAllNodePooled()

	-- Header: play-button graphic at the top
	if not sc.nodesHeaderPlay then
		sc.nodesHeaderPlay = canvas:CreateTexture(nil, "ARTWORK")
		sc.nodesHeaderPlay:SetTexture("Interface\\TimerFrame\\BigTimerButton-Up")
		sc.nodesHeaderPlay:SetSize(48, 48)
	end
	sc.nodesHeaderPlay:ClearAllPoints()
	sc.nodesHeaderPlay:SetPoint("TOP", canvas, "TOP", 0, -10)
	sc.nodesHeaderPlay:Show()

	local cardIdx = 1
	local arrowIdx = 1
	local bubbleIdx = 1

	local yCursor = -NODE_HEADER_HEIGHT
	local centerX = NODE_CARD_WIDTH / 2 + 20
	local anyRendered = false

	-- Precompute which rows are fully filter-hidden (every action across every
	-- populated cell stack is excluded). Rows with no actions at all still
	-- render one placeholder.
	local rowHidden = {}
	for r = 1, state.numRows do
		if not state.grid[r] then
			state.grid[r] = {}
		end
		local anyAction, anyVisible = false, false
		for c = 1, state.numCols do
			local cell = state.grid[r][c]
			if cell and #cell > 0 then
				anyAction = true
				for i = 1, #cell do
					if not IsFilterHiding(cell[i]) then
						anyVisible = true
					end
				end
			end
		end
		rowHidden[r] = anyAction and not anyVisible
	end

	for r = 1, state.numRows do
		if not rowHidden[r] then
			-- Build list of positions to render for this row. Populated
			-- columns that pass the filter become real nodes; a wholly empty
			-- row renders a single column-1 placeholder.
			local positions = {}
			local hasAny = false
			for c = 1, state.numCols do
				local cell = state.grid[r][c]
				if cell and #cell > 0 then
					hasAny = true
					break
				end
			end
			if hasAny then
				for c = 1, state.numCols do
					local cell = state.grid[r][c]
					if cell and #cell > 0 then
						local anyVisibleHere = false
						for i = 1, #cell do
							if not IsFilterHiding(cell[i]) then
								anyVisibleHere = true
								break
							end
						end
						if anyVisibleHere then
							table.insert(positions, c)
						end
					end
				end
			else
				table.insert(positions, 1) -- placeholder for empty row
			end

			local firstCardInRow = nil
			for i, col in ipairs(positions) do
				local cellList = state.grid[r][col]
				local stackSize = (cellList and #cellList) or 0
				local head = cellList and cellList[1] or nil

				-- Arrow leading into this card. "fallthrough" between rows,
				-- "step" between sequential steps in the same row.
				local arrow = GetOrCreateNodeArrow(canvas, arrowIdx)
				arrowIdx = arrowIdx + 1
				arrow:ClearAllPoints()
				arrow:SetPoint("TOP", canvas, "TOPLEFT", centerX, yCursor + 8)
				if not anyRendered then
					arrow.tagLabel:SetText("")
				elseif i == 1 then
					arrow.tagLabel:SetText("fallthrough")
				else
					arrow.tagLabel:SetText("step " .. col)
				end
				arrow:Show()

				yCursor = yCursor - NODE_V_SPACING

				local card = GetOrCreateNodeCard(canvas, cardIdx)
				cardIdx = cardIdx + 1
				local cardHeight = NODE_CARD_HEIGHT + math.max(0, stackSize - 1) * STACK_ROW_HEIGHT
				if stackSize <= 1 then
					cardHeight = NODE_CARD_HEIGHT
				end
				card:SetSize(NODE_CARD_WIDTH, cardHeight)
				card:ClearAllPoints()
				card:SetPoint("TOP", canvas, "TOPLEFT", centerX, yCursor)

				if head then
					local iconTex = Wise:GetActionIcon(head.type, head.value, head)
					card.icon:SetTexture(iconTex or "Interface\\Icons\\INV_Misc_QuestionMark")
					local name = Wise:GetActionName(head.type, head.value, head) or "Unknown"
					card.nameLabel:SetText(name)

					if IsActionLive(head) then
						card:SetAlpha(1)
						card:SetBackdropBorderColor(0.45, 0.45, 0.55, 1)
					else
						card:SetAlpha(0.4)
						card:SetBackdropBorderColor(0.3, 0.3, 0.35, 0.6)
					end

					-- Hide any pre-existing stack rows in case the stack shrank.
					if card.stackRows then
						for _, sr in pairs(card.stackRows) do
							sr:Hide()
						end
					end

					-- Render stack rows for entries 2..N below the head row.
					for si = 2, stackSize do
						local stacked = cellList[si]
						local sr = card:GetStackRow(si)
						sr:SetWidth(NODE_CARD_WIDTH - 8)
						sr:ClearAllPoints()
						sr:SetPoint("TOPLEFT", card, "TOPLEFT", 4, -(NODE_CARD_HEIGHT + (si - 2) * STACK_ROW_HEIGHT))
						local sIcon = Wise:GetActionIcon(stacked.type, stacked.value, stacked)
						sr.icon:SetTexture(sIcon or "Interface\\Icons\\INV_Misc_QuestionMark")
						local sName = Wise:GetActionName(stacked.type, stacked.value, stacked) or "Unknown"
						sr.nameLabel:SetText(sName)
						if IsActionLive(stacked) then
							sr:SetAlpha(1)
						else
							sr:SetAlpha(0.5)
						end
						local rmRow, rmCol, rmIdx = r, col, si
						sr.removeBtn:SetScript("OnClick", function()
							CellRemoveAt(rmRow, rmCol, rmIdx)
							RenderNodesCanvas()
						end)
						local stackedType = stacked.type
						sr:SetScript("OnEnter", function(self)
							GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
							GameTooltip:SetText(sName, 1, 1, 1)
							if stackedType then
								GameTooltip:AddLine("Type: " .. stackedType, 0.8, 0.8, 0.8)
							end
							GameTooltip:AddLine("Stacked — fires together with this step.", 0.7, 0.7, 0.9, true)
							GameTooltip:Show()
						end)
						sr:SetScript("OnLeave", function()
							GameTooltip:Hide()
						end)
						sr:Show()
					end

					-- "+" inside the card pushes another stacked action.
					card.addStackBtn:ClearAllPoints()
					card.addStackBtn:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -2, 2)
					local pushRow, pushCol = r, col
					card.addStackBtn:SetScript("OnClick", function()
						Wise:OpenConfiguratorPicker(pushRow, pushCol, "stack")
					end)
					card.addStackBtn:SetScript("OnEnter", function(self)
						GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
						GameTooltip:SetText("Stack action", 1, 1, 1)
						GameTooltip:AddLine(
							"Add another action that fires together with this one.",
							0.8,
							0.8,
							0.8,
							true
						)
						GameTooltip:Show()
					end)
					card.addStackBtn:SetScript("OnLeave", function()
						GameTooltip:Hide()
					end)
					card.addStackBtn:Show()

					card.removeBtn:Show()
					local removeRow, removeCol = r, col
					card.removeBtn:SetScript("OnClick", function()
						-- Removing the head pops the head from the stack; if
						-- the cell becomes empty, the row may auto-collapse
						-- — but only when the row has no hidden actions in
						-- other columns. Otherwise we'd silently nuke data
						-- belonging to another spec/class.
						CellRemoveAt(removeRow, removeCol, 1)
						local cell = state.grid[removeRow] and state.grid[removeRow][removeCol]
						if (not cell or #cell == 0) and state.numRows > 1 and not RowHasHidden(removeRow) then
							local allEmpty = true
							if state.grid[removeRow] then
								for _, v in pairs(state.grid[removeRow]) do
									if v and (type(v) ~= "table" or #v > 0) then
										allEmpty = false
										break
									end
								end
							end
							if allEmpty then
								table.remove(state.grid, removeRow)
								table.remove(state.rowConditions, removeRow)
								table.remove(state.rowExclusive, removeRow)
								table.remove(state.rowMods, removeRow)
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
									state.rowMods[1] = {}
								end
							end
						end
						RenderNodesCanvas()
					end)

					card:RegisterForClicks("LeftButtonUp", "RightButtonUp")
					local clickRow, clickCol = r, col
					card:SetScript("OnClick", function(self, button)
						if button == "RightButton" then
							Wise:OpenConfiguratorPicker(clickRow, clickCol)
						end
					end)

					local headType = head.type
					local stackForTip = stackSize
					card:SetScript("OnEnter", function(self)
						GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
						GameTooltip:SetText(name, 1, 1, 1)
						if headType then
							GameTooltip:AddLine("Type: " .. headType, 0.8, 0.8, 0.8)
						end
						GameTooltip:AddLine("Step " .. col, 0.7, 0.7, 0.9)
						if stackForTip > 1 then
							GameTooltip:AddLine(
								"Stack of " .. stackForTip .. " — all fire together.",
								0.7,
								0.9,
								0.7,
								true
							)
						end
						GameTooltip:AddLine(" ")
						GameTooltip:AddLine("Right-click to replace. + to stack. X to pop.", 0.6, 0.6, 0.6, true)
						GameTooltip:Show()
					end)
					card:SetScript("OnLeave", function()
						GameTooltip:Hide()
					end)
				else
					card.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
					card.nameLabel:SetText("|cff888888(empty)|r")
					card:SetAlpha(0.7)
					card:SetBackdropBorderColor(0.35, 0.35, 0.4, 0.7)
					card.removeBtn:Hide()

					card:RegisterForClicks("LeftButtonUp")
					local clickRow, clickCol = r, col
					card:SetScript("OnClick", function(self)
						local cursorType, id = GetCursorInfo()
						if cursorType then
							local actionData = Wise:CursorToActionData(cursorType, id)
							if actionData then
								CellSetSingle(clickRow, clickCol, actionData)
								ClearCursor()
								RenderNodesCanvas()
								return
							end
						end
						Wise:OpenConfiguratorPicker(clickRow, clickCol)
					end)
					card:SetScript("OnReceiveDrag", function(self)
						local cursorType, id = GetCursorInfo()
						if cursorType then
							local actionData = Wise:CursorToActionData(cursorType, id)
							if actionData then
								CellSetSingle(clickRow, clickCol, actionData)
								ClearCursor()
								RenderNodesCanvas()
							end
						end
					end)

					card:SetScript("OnEnter", function(self)
						GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
						GameTooltip:SetText("Empty Node", 1, 1, 1)
						GameTooltip:AddLine("Click to open the spell picker.", 0.8, 0.8, 0.8, true)
						GameTooltip:AddLine("Or drag a spell from the spellbook.", 0.6, 0.6, 0.6, true)
						GameTooltip:Show()
					end)
					card:SetScript("OnLeave", function()
						GameTooltip:Hide()
					end)
				end
				card:Show()

				if not firstCardInRow then
					firstCardInRow = card
				end
				anyRendered = true
				yCursor = yCursor - cardHeight
			end

			-- One condition bubble per row, anchored to the first card
			if firstCardInRow then
				local bubble = GetOrCreateCondBubble(canvas, bubbleIdx)
				bubbleIdx = bubbleIdx + 1
				bubble:ClearAllPoints()
				bubble:SetPoint("LEFT", firstCardInRow, "RIGHT", NODE_COND_OFFSET, 0)

				local condText = state.rowConditions[r] or ""
				if condText == "" then
					bubble.label:SetText("|cff888888[Default/Always]|r")
				else
					bubble.label:SetText(condText)
				end

				local bubbleRow = r
				bubble:SetScript("OnClick", function()
					if Wise.pickingCondition and Wise._conditionPickerState then
						local prevRow = Wise._configuratorConditionRow
						if prevRow and state.rowConditions then
							state.rowConditions[prevRow] = BuildConditionString(Wise._conditionPickerState.groups)
						end
					end
					Wise._conditionPickerState = {
						row = bubbleRow,
						groups = ParseConditionString(state.rowConditions[bubbleRow] or ""),
						activeGroup = 1,
					}
					Wise._configuratorConditionRow = bubbleRow
					Wise.pickingCondition = true
					Wise:RefreshPropertiesPanel()
				end)

				bubble:SetScript("OnEnter", function(self)
					GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
					GameTooltip:SetText("Node Condition", 1, 1, 1)
					if condText == "" then
						GameTooltip:AddLine("No condition - always active", 0.8, 0.8, 0.8, true)
					else
						GameTooltip:AddLine(condText, 0.8, 0.8, 0.8, true)
					end
					GameTooltip:AddLine("Click to edit.", 0.6, 0.6, 0.6, true)
					GameTooltip:Show()
				end)
				bubble:SetScript("OnLeave", function()
					GameTooltip:Hide()
				end)
				bubble:Show()
			end
		end
	end

	-- "+ Add Node" button at the bottom
	if not sc.nodesAddBtn then
		sc.nodesAddBtn = CreateFrame(
			"Button",
			canvas:GetName() and (canvas:GetName() .. "AddBtn") or nil,
			canvas,
			"GameMenuButtonTemplate"
		)
		sc.nodesAddBtn:SetSize(140, 24)
		sc.nodesAddBtn:SetText("+ Add Node")
		sc.nodesAddBtn:SetScript("OnClick", function()
			configuratorState.numRows = configuratorState.numRows + 1
			configuratorState.grid[configuratorState.numRows] = {}
			configuratorState.rowConditions[configuratorState.numRows] = ""
			configuratorState.rowExclusive[configuratorState.numRows] = false
			local inherit = configuratorState.rowMods[configuratorState.numRows - 1] or {}
			local copy = {}
			for m in pairs(inherit) do
				copy[m] = true
			end
			configuratorState.rowMods[configuratorState.numRows] = copy
			RenderNodesCanvas()
		end)
		Wise:AddTooltip(sc.nodesAddBtn, "Add another action node to the flow.")
	end
	sc.nodesAddBtn:ClearAllPoints()
	sc.nodesAddBtn:SetPoint("TOP", canvas, "TOPLEFT", centerX, yCursor - 18)
	sc.nodesAddBtn:Show()

	-- Resize canvas to content
	local totalHeight = math.abs(yCursor) + 60
	local totalWidth = centerX + NODE_CARD_WIDTH / 2 + NODE_COND_OFFSET + 160
	canvas:SetSize(math.max(totalWidth, 500), totalHeight)
end

-- Dispatch render based on active tab
RenderActiveTab = function()
	local sc = Wise.SlotConfigurator
	if not sc then
		return
	end
	if configuratorState.activeTab == "nodes" then
		RenderNodesCanvas()
	else
		RenderCanvas()
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
	if modDragGhost then
		return modDragGhost
	end
	modDragGhost = CreateFrame("Frame", "WiseModDragGhost", UIParent, "BackdropTemplate")
	modDragGhost:SetFrameStrata("TOOLTIP")
	modDragGhost:SetSize(80, 22)
	modDragGhost:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 8,
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
		tile = true,
		tileSize = 16,
		edgeSize = 6,
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
	for _, z in pairs(modDropZones) do
		z:Hide()
	end
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
			tile = true,
			tileSize = 16,
			edgeSize = 8,
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

			if not modDrag.active then
				return
			end
			modDrag.active = false

			-- Hit test against drop zones
			local cx, cy = GetCursorPosition()
			local scale = UIParent:GetEffectiveScale()
			cx, cy = cx / scale, cy / scale

			for _, zone in pairs(modDropZones) do
				if zone:IsShown() and zone.afterRow then
					local l, b, w, h = zone:GetRect()
					if l and cx >= l and cx <= l + w and cy >= b and cy <= b + h then
						ApplyBreakDrop(zone.afterRow, modDrag.modifier)
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
			GameTooltip:AddLine(
				"Actions below the break only fire with " .. string.upper(mod) .. " held.",
				0.6,
				0.6,
				0.6,
				true
			)
			GameTooltip:Show()
		end)
		token:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)

		xOff = xOff + 66
	end

	return palette
end

-- ═══════════════════════════════════════════════════════════════
-- Cursor -> Action Data helper
-- ═══════════════════════════════════════════════════════════════
function Wise:CursorToActionData(cursorType, id)
	local C_Spell = C_Spell
	-- Route every cursor type through BuildActionRecord so configurator drops
	-- get the same metadata as outer-panel drops (visibilityEnable, category,
	-- addedByClass, addedBySpec, talentRequirements). Without this, configurator
	-- drag/drop produces bare records that ignore the spec/class filter.
	if cursorType == "spell" then
		local spellInfo = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
		local extra = {
			name = spellInfo and spellInfo.name or "",
			icon = spellInfo and spellInfo.iconID or nil,
		}
		return Wise:BuildActionRecord("spell", id, nil, extra)
	elseif cursorType == "item" then
		return Wise:BuildActionRecord("item", id, nil, nil)
	elseif cursorType == "macro" then
		return Wise:BuildActionRecord("macro", id, nil, nil)
	elseif cursorType == "mount" then
		return Wise:BuildActionRecord("mount", id, nil, nil)
	end
	return nil
end

-- ═══════════════════════════════════════════════════════════════
-- Picker Integration (opens spell picker from within configurator)
-- ═══════════════════════════════════════════════════════════════
function Wise:OpenConfiguratorPicker(targetRow, targetCol, mode)
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

	-- mode: "stack" → push onto existing cell stack; default → replace cell.
	Wise._configuratorPickTarget = { row = targetRow, col = targetCol, mode = mode or "replace" }

	-- Use the existing picker system with a custom callback
	Wise.pickingAction = true
	Wise.PickerCallback = function(actionType, value, extra)
		local target = Wise._configuratorPickTarget
		if target and configuratorState.grid then
			if not configuratorState.grid[target.row] then
				configuratorState.grid[target.row] = {}
			end
			-- Route through BuildActionRecord so the new state gets the same
			-- visibilityEnable/addedByClass/addedBySpec/talentRequirements
			-- metadata as actions added via the outer Options panel.
			local record = Wise:BuildActionRecord(actionType, value, extra and extra.category, extra)
			if target.mode == "stack" then
				local cell = configuratorState.grid[target.row][target.col]
				if not cell then
					configuratorState.grid[target.row][target.col] = { record }
				else
					tinsert(cell, record)
				end
			else
				configuratorState.grid[target.row][target.col] = { record }
			end
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

-- Check if an action passes the current filter (delegates to shared toon-based filter)
ActionPassesFilter = function(action)
	if not action then
		return false
	end
	return Wise:ShouldShowAction(action)
end

-- True when the current filter is actively hiding this action. Empty slots
-- are never hidden (they are drop targets).
IsFilterHiding = function(action)
	if not action then
		return false
	end
	return not Wise:ShouldShowAction(action)
end

-- True when the action is usable on this character right now (learned, etc).
-- Used for dimming actions that pass the filter but aren't currently live.
IsActionLive = function(action)
	if not action then
		return true
	end
	if not Wise.IsActionKnown then
		return true
	end
	return Wise:IsActionKnown(action.type, action.value) and true or false
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
	if not ps or not pickerFrame or not pickerFrame.builderContent then
		return
	end

	local content = pickerFrame.builderContent
	-- Hide all existing chips and group frames
	if content._groupFrames then
		for _, gf in ipairs(content._groupFrames) do
			gf:Hide()
		end
	end
	content._groupFrames = content._groupFrames or {}

	local yOff = 0
	local contentWidth = content:GetWidth()
	if contentWidth < 100 then
		contentWidth = 560
	end

	for gi, group in ipairs(ps.groups) do
		-- OR divider between groups
		if gi > 1 then
			yOff = yOff - 4
			local divIdx = gi - 1
			if not content._orDividers then
				content._orDividers = {}
			end
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
				tile = true,
				tileSize = 16,
				edgeSize = 10,
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
				if ps.activeGroup > #ps.groups then
					ps.activeGroup = #ps.groups
				end
				if ps.activeGroup < 1 then
					ps.activeGroup = 1
				end
				if #ps.groups == 0 then
					ps.groups = { {} }
				end
				RefreshConditionBuilder(pickerFrame)
			end)
		else
			gf._removeBtn:Hide()
		end

		-- Hide old chips
		for _, chip in ipairs(gf._chips) do
			chip:Hide()
		end

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
					tile = true,
					tileSize = 16,
					edgeSize = 8,
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
					if ps.activeGroup > #ps.groups then
						ps.activeGroup = #ps.groups
					end
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
			if content._orDividers[i] then
				content._orDividers[i]:Hide()
			end
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
	if not ps or not pickerFrame or not pickerFrame.listContent then
		return
	end

	local content = pickerFrame.listContent
	local list = (listType == "wise") and Wise.opieConditionals or Wise.builtinConditionals
	if not list then
		return
	end

	-- Hide existing rows
	if not content._rows then
		content._rows = {}
	end
	for _, row in ipairs(content._rows) do
		row:Hide()
	end

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
			row:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)

			row:Show()
			yOff = yOff - 22
		end
	end

	content:SetHeight(math.abs(yOff) + 8)
end

function Wise:CreateConditionPickerUI(host)
	local cp = Wise.ConditionPicker
	local ps = Wise._conditionPickerState
	if not ps then
		return
	end

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
		if w and w > 50 then
			cp.builderContent:SetWidth(w - 4)
		end
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
		if w and w > 50 then
			cp.listContent:SetWidth(w - 4)
		end
	end)

	RenderConditionalList(host, "builtin")
end

function Wise:UpdateConditionPickerExclusionDisplay(cp, row)
	if not cp or not cp.inheritedLabel then
		return
	end

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
local function GetCurrentSlotActions()
	local groupName = configuratorState.groupName
	local slotIdx = configuratorState.slotIdx
	if not groupName or not slotIdx then
		return nil
	end
	local group = WiseDB and WiseDB.groups and WiseDB.groups[groupName]
	if not group or not group.actions then
		return nil
	end
	return group.actions[slotIdx]
end

local function SyncSlotToggleControls()
	local sc = Wise.SlotConfigurator
	if not sc or not sc.suppressCheck then
		return
	end
	local slot = GetCurrentSlotActions()
	sc.suppressCheck:SetChecked(slot and slot.suppressErrors or false)
	sc.resetCheck:SetChecked(slot and slot.resetOnCombat or false)
	-- Reset-on-combat only applies when the grid is multi-column (sequence on export).
	if (configuratorState.numCols or 1) > 1 then
		sc.resetCheck:Show()
		sc.resetCheck.Text:Show()
	else
		sc.resetCheck:Hide()
		sc.resetCheck.Text:Hide()
	end
end

-- Show/hide the correct tab content and toolbar items, then render.
local function ApplyTabVisibility()
	local sc = Wise.SlotConfigurator
	if not sc then
		return
	end
	local isNodes = (configuratorState.activeTab == "nodes")

	if sc.canvasScroll then
		if isNodes then
			sc.canvasScroll:Hide()
		else
			sc.canvasScroll:Show()
		end
	end
	if sc.nodesCanvasScroll then
		if isNodes then
			sc.nodesCanvasScroll:Show()
		else
			sc.nodesCanvasScroll:Hide()
		end
	end

	-- Modifier palette is a Grid-tab concept (modBreaks are stacked mod rows
	-- across the table). Hide it while on the Nodes tab to avoid suggesting
	-- functionality the nodes view doesn't expose yet.
	if sc.modPalette then
		if isNodes or Wise.pickingCondition then
			sc.modPalette:Hide()
		else
			sc.modPalette:Show()
		end
	end

	-- Tab button visuals
	if sc.tabGrid and sc.tabNodes then
		if isNodes then
			sc.tabGrid:Enable()
			sc.tabNodes:Disable()
		else
			sc.tabGrid:Disable()
			sc.tabNodes:Enable()
		end
	end

	SyncSlotToggleControls()
	RenderActiveTab()
end

function Wise:CreateSlotConfiguratorUI(host)
	local sc = Wise.SlotConfigurator
	if sc and sc.host == host then
		-- Reuse existing UI
		sc.cancelBtn:Show()
		sc.titleLabel:Show()
		sc.divider:Show()
		if sc.tabGrid then
			sc.tabGrid:Show()
		end
		if sc.tabNodes then
			sc.tabNodes:Show()
		end
		if sc.suppressCheck then
			sc.suppressCheck:Show()
		end
		-- Hide toolbar items when condition picker is open (they'd overlap)
		if Wise.pickingCondition then
			sc.applyBtn:Hide()
			sc.infoLabel:Hide()
		else
			sc.applyBtn:Show()
			sc.infoLabel:Show()
		end
		ApplyTabVisibility()
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
		-- Auto-save changes before closing
		ExportToSlotData()
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

	-- Modifier palette (same row, after title) - only used by Grid tab
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
			if sc.applyBtn then
				sc.applyBtn:SetText("Apply Changes")
			end
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

	-- Tab bar (Grid / Nodes)
	sc.tabGrid = CreateFrame("Button", nil, host, "GameMenuButtonTemplate")
	sc.tabGrid:SetSize(90, 22)
	sc.tabGrid:SetPoint("TOPLEFT", sc.divider, "BOTTOMLEFT", 0, -4)
	sc.tabGrid:SetText("Grid")
	sc.tabGrid:SetNormalFontObject("GameFontHighlightSmall")
	sc.tabGrid:SetScript("OnClick", function()
		configuratorState.activeTab = "grid"
		ApplyTabVisibility()
	end)

	sc.tabNodes = CreateFrame("Button", nil, host, "GameMenuButtonTemplate")
	sc.tabNodes:SetSize(90, 22)
	sc.tabNodes:SetPoint("LEFT", sc.tabGrid, "RIGHT", 4, 0)
	sc.tabNodes:SetText("Nodes")
	sc.tabNodes:SetNormalFontObject("GameFontHighlightSmall")
	sc.tabNodes:SetScript("OnClick", function()
		configuratorState.activeTab = "nodes"
		ApplyTabVisibility()
	end)

	-- Per-slot toggles: suppress errors (always available), reset sequence on combat end
	-- (only meaningful for multi-column grids that export as sequence). These persist
	-- on the slot's actions hash and are written through directly — no Apply needed.
	sc.suppressCheck = CreateFrame("CheckButton", nil, host, "InterfaceOptionsCheckButtonTemplate")
	sc.suppressCheck:SetPoint("LEFT", sc.tabNodes, "RIGHT", 16, 0)
	sc.suppressCheck.Text:SetText("Suppress errors")
	sc.suppressCheck.Text:SetFontObject("GameFontHighlightSmall")
	sc.suppressCheck:SetScript("OnClick", function(self)
		local slot = GetCurrentSlotActions()
		if slot then
			slot.suppressErrors = self:GetChecked()
		end
	end)
	Wise:AddTooltip(sc.suppressCheck, "Silence cast errors (e.g., out of range, target lost) when this slot fires.")

	sc.resetCheck = CreateFrame("CheckButton", nil, host, "InterfaceOptionsCheckButtonTemplate")
	sc.resetCheck:SetPoint("LEFT", sc.suppressCheck.Text, "RIGHT", 4, 0)
	sc.resetCheck.Text:SetText("Reset sequence on combat end")
	sc.resetCheck.Text:SetFontObject("GameFontHighlightSmall")
	sc.resetCheck:SetScript("OnClick", function(self)
		local slot = GetCurrentSlotActions()
		if slot then
			slot.resetOnCombat = self:GetChecked()
		end
	end)
	Wise:AddTooltip(sc.resetCheck, "Restart from the first column of the sequence when you leave combat.")

	SyncSlotToggleControls()

	-- Grid canvas scroll
	sc.canvasScroll = CreateFrame("ScrollFrame", nil, host, "UIPanelScrollFrameTemplate")
	sc.canvasScroll:SetPoint("TOPLEFT", sc.tabGrid, "BOTTOMLEFT", 0, -6)
	sc.canvasScroll:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -28, 8)

	sc.canvas = CreateFrame("Frame", nil, sc.canvasScroll)
	sc.canvas:SetSize(800, 400)
	sc.canvasScroll:SetScrollChild(sc.canvas)

	-- Nodes canvas scroll (same geometry, hidden by default)
	sc.nodesCanvasScroll = CreateFrame("ScrollFrame", nil, host, "UIPanelScrollFrameTemplate")
	sc.nodesCanvasScroll:SetPoint("TOPLEFT", sc.tabGrid, "BOTTOMLEFT", 0, -6)
	sc.nodesCanvasScroll:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -28, 8)

	sc.nodesCanvas = CreateFrame("Frame", nil, sc.nodesCanvasScroll)
	sc.nodesCanvas:SetSize(600, 400)
	sc.nodesCanvasScroll:SetScrollChild(sc.nodesCanvas)

	ApplyTabVisibility()
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
	if not Wise.configuringSlot then
		return
	end
	-- Auto-save changes before closing
	ExportToSlotData()
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
