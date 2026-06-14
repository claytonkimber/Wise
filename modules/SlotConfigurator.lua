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
local NODE_CARD_HEIGHT = 84
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
	state.isDirty = true
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
	configuratorState.isDirty = true
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
	state.isDirty = true
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
	state.isDirty = true
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
	state.isDirty = true
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

local function ConvertGridToGraph()
	local graph = { nodes = {}, connections = {} }
	local state = configuratorState
	local nodeId = 1
	local cellToNodeId = {}

	for r = 1, state.numRows do
		for c = 1, state.numCols do
			local cell = state.grid[r] and state.grid[r][c]
			if cell and #cell > 0 then
				for i, action in ipairs(cell) do
					local cond = state.rowConditions[r] or ""
					local mods = state.rowMods[r]
					if mods then
						local modParts = {}
						for m in pairs(mods) do
							tinsert(modParts, "mod:" .. m)
						end
						if #modParts > 0 then
							local modStr = table.concat(modParts, ",")
							if cond ~= "" then
								cond = "[" .. cond .. "," .. modStr .. "]"
							else
								cond = "[" .. modStr .. "]"
							end
						end
					end
					if cond ~= "" then
						cond = cond:gsub("^%[%[+", "["):gsub("%]+$", "]")
					end
					local node = {
						id = nodeId,
						action = ShallowCopyAction(action),
						condition = cond,
					}
					tinsert(graph.nodes, node)
					cellToNodeId[r] = cellToNodeId[r] or {}
					cellToNodeId[r][c] = cellToNodeId[r][c] or {}
					cellToNodeId[r][c][i] = nodeId
					nodeId = nodeId + 1
				end
			end
		end
	end

	for r = 1, state.numRows do
		for c = 1, state.numCols do
			local cell = state.grid[r] and state.grid[r][c]
			if cell and #cell > 0 then
				for i = 1, #cell - 1 do
					local fromId = cellToNodeId[r][c][i]
					local toId = cellToNodeId[r][c][i + 1]
					if fromId and toId then
						tinsert(graph.connections, { from = fromId, to = toId, type = "waterfall" })
					end
				end
				local lastInCell = cellToNodeId[r][c][#cell]
				if lastInCell then
					for nr = r + 1, state.numRows do
						local nextCell = state.grid[nr] and state.grid[nr][c]
						if nextCell and #nextCell > 0 then
							local firstInNextCell = cellToNodeId[nr][c][1]
							if firstInNextCell then
								tinsert(
									graph.connections,
									{ from = lastInCell, to = firstInNextCell, type = "waterfall" }
								)
							end
							break
						end
					end
				end
			end
		end
	end

	for r = 1, state.numRows do
		for c = 1, state.numCols - 1 do
			local cell = state.grid[r] and state.grid[r][c]
			if cell and #cell > 0 then
				local firstInCell = cellToNodeId[r][c][1]
				if firstInCell then
					for nc = c + 1, state.numCols do
						local nextCell = state.grid[r] and state.grid[r][nc]
						if nextCell and #nextCell > 0 then
							local firstInNextCell = cellToNodeId[r][nc][1]
							if firstInNextCell then
								tinsert(
									graph.connections,
									{ from = firstInCell, to = firstInNextCell, type = "sequence" }
								)
							end
							break
						end
					end
				end
			end
		end
	end

	return graph
end

local function ComputeNodeLayout(graph)
	local cols = {}
	local rows = {}
	local nodes = graph.nodes
	local conns = graph.connections

	-- Initialize
	for _, n in ipairs(nodes) do
		cols[n.id] = 1
		rows[n.id] = 1
	end

	-- Identify connected nodes
	local isConnected = {}
	for _, c in ipairs(conns) do
		isConnected[c.from] = true
		isConnected[c.to] = true
	end

	-- Propagate columns along sequence & waterfall connections
	local changed = true
	local iterations = 0
	while changed and iterations < 100 do
		changed = false
		iterations = iterations + 1
		for _, c in ipairs(conns) do
			if c.type == "sequence" then
				if cols[c.to] <= cols[c.from] then
					cols[c.to] = cols[c.from] + 1
					changed = true
				end
			elseif c.type == "waterfall" then
				if cols[c.to] < cols[c.from] then
					cols[c.to] = cols[c.from]
					changed = true
				end
			end
		end
	end

	-- Propagate rows along waterfall & sequence connections
	changed = true
	iterations = 0
	while changed and iterations < 100 do
		changed = false
		iterations = iterations + 1
		for _, c in ipairs(conns) do
			if c.type == "waterfall" then
				if rows[c.to] <= rows[c.from] then
					rows[c.to] = rows[c.from] + 1
					changed = true
				end
			elseif c.type == "sequence" then
				if rows[c.to] ~= rows[c.from] then
					rows[c.to] = rows[c.from]
					changed = true
				end
			end
		end
	end

	-- Position unconnected nodes at the bottom of the first column
	local maxConnectedRow = 1
	for _, n in ipairs(nodes) do
		if isConnected[n.id] then
			local r = rows[n.id] or 1
			if r > maxConnectedRow then
				maxConnectedRow = r
			end
		end
	end

	for _, n in ipairs(nodes) do
		if not isConnected[n.id] then
			cols[n.id] = 1
			rows[n.id] = maxConnectedRow + 1
		end
	end

	-- Resolve coordinate collisions (prevent cards from stacking/overlapping)
	local occupied = {}
	for _, n in ipairs(nodes) do
		local c = cols[n.id] or 1
		local r = rows[n.id] or 1
		local key = c .. "," .. r
		while occupied[key] do
			r = r + 1
			key = c .. "," .. r
		end
		occupied[key] = true
		rows[n.id] = r
	end

	-- Compact away gaps left by deleted nodes/connections so cards re-pack tight
	-- instead of leaving empty columns or rows behind. Propagation above can leave
	-- non-consecutive column/row indices (e.g. after a middle connection is cut),
	-- which makes connected cards drift apart visually; remap to dense indices.

	-- Column compaction: collapse empty columns globally.
	local usedCols = {}
	for _, n in ipairs(nodes) do
		usedCols[cols[n.id] or 1] = true
	end
	local sortedCols = {}
	for c in pairs(usedCols) do
		tinsert(sortedCols, c)
	end
	table.sort(sortedCols)
	local colRemap = {}
	for newIdx, oldCol in ipairs(sortedCols) do
		colRemap[oldCol] = newIdx
	end
	for _, n in ipairs(nodes) do
		cols[n.id] = colRemap[cols[n.id] or 1] or 1
	end

	-- Row compaction: collapse empty rows GLOBALLY (not per column). A sequence
	-- connection keeps source and target on the SAME row so the cards sit beside
	-- each other (and so the compiler treats the column-1 chain + its sequenced
	-- partner as one step). Compacting each column independently would pull a lone
	-- sequenced card up to row 1, breaking that alignment. Instead, remap the set
	-- of row values used anywhere in the graph to dense indices, preserving which
	-- nodes share a row.
	local usedRows = {}
	for _, n in ipairs(nodes) do
		usedRows[rows[n.id] or 1] = true
	end
	local sortedRows = {}
	for r in pairs(usedRows) do
		tinsert(sortedRows, r)
	end
	table.sort(sortedRows)
	local rowRemap = {}
	for newIdx, oldRow in ipairs(sortedRows) do
		rowRemap[oldRow] = newIdx
	end
	for _, n in ipairs(nodes) do
		rows[n.id] = rowRemap[rows[n.id] or 1] or 1
	end

	return cols, rows
end

local function RebuildGridFromGraph()
	local state = configuratorState
	state.grid = {}
	state.rowConditions = {}
	state.rowMods = {}
	state.rowExclusive = {}

	if not state.graph or not state.graph.nodes or #state.graph.nodes == 0 then
		state.numRows = 1
		state.numCols = 1
		state.grid[1] = {}
		state.rowConditions[1] = ""
		return
	end

	local cols, rows = ComputeNodeLayout(state.graph)
	local maxCol = 1
	local maxRow = 1

	for _, node in ipairs(state.graph.nodes) do
		local c = cols[node.id] or 1
		local r = rows[node.id] or 1
		if c > maxCol then
			maxCol = c
		end
		if r > maxRow then
			maxRow = r
		end

		state.grid[r] = state.grid[r] or {}
		state.grid[r][c] = state.grid[r][c] or {}
		tinsert(state.grid[r][c], ShallowCopyAction(node.action))

		state.rowConditions[r] = node.condition or ""
		state.rowExclusive[r] = node.action.exclusive or false
		state.rowMods[r] = state.rowMods[r] or {}
	end

	state.numCols = maxCol
	state.numRows = maxRow
end

-- Resolve a single action + condition into one macro command line, reusing the
-- engine's GetSecureAttributes so spell IDs become castable names (incl. the
-- Skyriding subtext qualifier) and items become item:ID references.  Raw IDs do
-- not work in /cast or /use, which is why the configurator must resolve them here
-- rather than emitting a.value verbatim.
local function ResolveActionMacroLine(action, cond)
	cond = cond or ""
	-- GetSecureAttributes already produces a complete "/cmd [cond] target" line
	-- whenever a condition is present.  Pass the bracketed condition straight in.
	local sType, sAttr, sValue = Wise:GetSecureAttributes(action, cond)

	-- macrotext (and the legacy "macro" attr for raw slash text) is already a
	-- ready-to-run command line.
	if sAttr == "macrotext" or sAttr == "macro" then
		return tostring(sValue or "")
	end

	-- No condition: GetSecureAttributes returns the bare secure type/value
	-- (spell name/ID, item:ID, action id, …) rather than a macro line.  Wrap it
	-- in the appropriate slash command so it can live inside a multi-line macro.
	local prefix = (cond ~= "") and (cond .. " ") or ""
	if sType == "spell" then
		return "/cast " .. prefix .. tostring(sValue)
	elseif sType == "item" then
		return "/use " .. prefix .. tostring(sValue)
	elseif sType == "macro" then
		return tostring(sValue or "")
	elseif sType == "click" then
		local name = sValue
		if type(sValue) == "table" and sValue.GetName then
			name = sValue:GetName()
		end
		if name then
			return "/click " .. prefix .. tostring(name)
		end
		return ""
	elseif sType == "action" then
		return "/use " .. prefix .. tostring(sValue)
	end

	return ""
end

-- Build the full "#showtooltip\n/cmd ...\n..." macro text for an ordered list of
-- graph nodes (each {action=..., condition=...}).  Shared by the live compiler
-- and the data-repair migration so both produce identical, castable macros.
--
-- IMPORTANT: this builds the CANONICAL, character-agnostic macro — it includes a
-- line for EVERY node regardless of class/spec/role.  Availability filtering
-- (IsActionAllowed) is applied LIVE per character when the engine builds what
-- actually fires/shows (see Wise:FilterMacroTextForCharacter), and is recomputed
-- whenever availability changes (spec/talents/login).  Baking the filter in here
-- would freeze one character's spells into the shared saved data — which is what
-- corrupted slots like AtMouse across characters.
local function BuildMacroTextFromNodes(nodes)
	local macroLines = {}
	tinsert(macroLines, "#showtooltip")
	for _, node in ipairs(nodes) do
		local a = node.action
		if a then
			local cond = node.condition or ""
			if cond ~= "" then
				-- Strip duplicate or nested brackets if they occurred from previous import/export bugs
				cond = cond:gsub("^%[%[+", "["):gsub("%]+$", "]")
				if not cond:match("^%[") then
					cond = "[" .. cond .. "]"
				end
			end
			local line = ResolveActionMacroLine(a, cond)
			if line and line ~= "" then
				tinsert(macroLines, line)
			end
		end
	end
	return table.concat(macroLines, "\n")
end

-- Live, per-character filter: given a compiled action that carries its source
-- graph, rebuild its macro text including only the nodes the CURRENT character is
-- allowed to use (IsActionAllowed). Returns the filtered macro text, or the
-- original macroText when there is no graph to filter from. This is what the
-- runtime should fire/show, and it must be recomputed whenever availability
-- changes (PLAYER_SPECIALIZATION_CHANGED, TRAIT/talent updates, login).
function Wise:FilterMacroTextForCharacter(compiledAction, graph)
	if type(compiledAction) ~= "table" then
		return compiledAction and compiledAction.macroText or ""
	end
	graph = graph or compiledAction.graph
	-- The per-step compiled action stores which node ids make up its path so we can
	-- re-filter just that step. Fall back to the whole graph's nodes in order.
	local nodes
	if graph and type(graph.nodes) == "table" and compiledAction.pathNodeIds then
		local byId = {}
		for _, n in ipairs(graph.nodes) do
			byId[n.id] = n
		end
		nodes = {}
		for _, id in ipairs(compiledAction.pathNodeIds) do
			if byId[id] then
				tinsert(nodes, byId[id])
			end
		end
	end
	if not nodes then
		return compiledAction.macroText or "", compiledAction.conditions or ""
	end
	local macroLines = { "#showtooltip" }
	-- Also derive the SLOT-level condition from the allowed nodes: if every allowed
	-- node shares one condition (e.g. all [combat]) we return it so the engine's
	-- secure visibility driver can hide the slot when it isn't met. Mixed/none => "".
	local slotCond = nil
	local condMixed = false
	local resolvedIcon = nil
	for _, node in ipairs(nodes) do
		local a = node.action
		if a and Wise:IsActionAllowed(a) then
			local cond = node.condition or ""
			if cond ~= "" then
				cond = cond:gsub("^%[%[+", "["):gsub("%]+$", "]")
				if not cond:match("^%[") then
					cond = "[" .. cond .. "]"
				end
			end
			local line = ResolveActionMacroLine(a, cond)
			if line and line ~= "" then
				tinsert(macroLines, line)
			end
			-- Capture icon from the first allowed node for callers that need a fallback.
			if not resolvedIcon then
				resolvedIcon = Wise:GetActionIcon(a.type, a.value, a)
				if resolvedIcon == 134400 then
					resolvedIcon = nil -- question mark is not useful as a fallback
				end
			end
			-- Track shared condition across the allowed nodes only.
			local rawCond = node.condition or ""
			if rawCond ~= "" then
				if slotCond == nil then
					slotCond = rawCond
				elseif slotCond ~= rawCond then
					condMixed = true
				end
			elseif slotCond ~= nil then
				condMixed = true
			end
		end
	end
	if condMixed then
		slotCond = nil
	end
	return table.concat(macroLines, "\n"), slotCond or "", resolvedIcon
end

-- The set of "castable" lines (/cast, /use, /click) in a per-character macro text,
-- as a { [line] = true } set. Used to compare steps for redundancy: the #showtooltip
-- header and pure support lines (/target, #-comments) are ignored because they don't
-- determine whether a press actually DOES anything distinct.
function Wise:GetMacroCastSet(macroText)
	local set = {}
	if type(macroText) ~= "string" then
		return set
	end
	for line in (macroText .. "\n"):gmatch("(.-)\n") do
		if line:match("^/cast") or line:match("^/use") or line:match("^/click") then
			set[line] = true
		end
	end
	return set
end

-- True when every castable line in `sub` also appears in `super` (sub ⊆ super).
-- A step whose castable lines are a subset of another kept step's lines is redundant:
-- it fires nothing the other step doesn't already fire. This is what removes a
-- collapsed branch that reduces to just the shared trinket/item head once the
-- character-specific spell on it is filtered out.
function Wise:MacroCastSetIsSubset(sub, super)
	for line in pairs(sub) do
		if not super[line] then
			return false
		end
	end
	return true
end

-- Enumerate every distinct root-to-leaf PATH through the graph. Each path is one
-- compiled step: it replays the shared head and then follows one branch to a leaf.
-- A node with no outgoing connection ends the path (e.g. a sequence branch like
-- Smite that doesn't reconnect stops there); a sequence branch that DOES connect
-- back into the main chain collapses onto it and continues. Sequence and waterfall
-- connections are both walked as forward edges here — the distinction only affects
-- the 2D layout, not which actions a given path fires.
local function EnumerateGraphPaths(graph)
	local nodes = graph.nodes
	local conns = graph.connections

	local byId = {}
	for _, n in ipairs(nodes) do
		byId[n.id] = n
	end

	-- Every connection is now a top->bottom (waterfall) edge. SEQUENCES are expressed
	-- purely by BRANCHING: when one node's bottom feeds several children's tops, each
	-- child begins a separate STEP that replays the shared head (root -> branch node)
	-- and then continues down that child's own chain. A node with a single child is a
	-- plain continuation in the same step.
	--
	-- This is exactly root-to-leaf path enumeration: each leaf yields one path, and
	-- all paths through a branch node share the common prefix automatically. So:
	--   penance -> smite (single child)         => 1 path  => 1 step
	--   X -> penance, X -> smite (X has 2 kids)  => 2 paths => 2 steps, both replay X
	local outgoing = {}
	local hasIncoming = {}
	for _, c in ipairs(conns) do
		if byId[c.from] and byId[c.to] then
			outgoing[c.from] = outgoing[c.from] or {}
			tinsert(outgoing[c.from], c.to)
			hasIncoming[c.to] = true
		end
	end

	local paths = {}

	local function walk(nodeId, acc, visited)
		if visited[nodeId] then
			-- Cycle guard: terminate the path here.
			tinsert(paths, { unpack(acc) })
			return
		end
		visited[nodeId] = true
		tinsert(acc, byId[nodeId])

		local nexts = outgoing[nodeId]
		if not nexts or #nexts == 0 then
			-- Leaf: emit this path as a step.
			tinsert(paths, { unpack(acc) })
		else
			for _, target in ipairs(nexts) do
				walk(target, acc, visited)
			end
		end

		acc[#acc] = nil
		visited[nodeId] = nil
	end

	-- Roots are nodes with no incoming edge (walked in graph order for stability).
	for _, n in ipairs(nodes) do
		if not hasIncoming[n.id] then
			walk(n.id, {}, {})
		end
	end

	return paths
end

local function CompileGraphToActions(graph, originalActions)
	-- Layout drives the on-canvas card positions; the compiler builds steps from
	-- the connection topology (paths), so the two stay in sync visually & logically.
	ComputeNodeLayout(graph)

	local newActions = {}
	newActions.keybind = originalActions.keybind
	newActions.resetOnCombat = originalActions.resetOnCombat
	newActions.suppressErrors = originalActions.suppressErrors
	newActions.pressAndHold = originalActions.pressAndHold
	newActions.graph = graph

	local paths = EnumerateGraphPaths(graph)

	-- Deduplicate identical paths (same ordered node ids) so a diamond-shaped
	-- rejoin doesn't emit two byte-identical steps.
	local seenPaths = {}

	for _, pathNodes in ipairs(paths) do
		local key = {}
		for _, n in ipairs(pathNodes) do
			tinsert(key, n.id)
		end
		key = table.concat(key, ">")

		if not seenPaths[key] then
			seenPaths[key] = true

			-- Build the macro via the canonical resolver so spell IDs become
			-- castable names (with Skyriding subtext), items become item:ID, etc.
			-- a.value for spells/items is the numeric ID, which /cast and /use
			-- cannot consume directly — only the resolved name/ref works in a macro.
			local macroText = BuildMacroTextFromNodes(pathNodes)
			-- A real step must actually CAST or USE something. Some nodes emit only
			-- support lines (e.g. a Healer Target node => "/target [@mouseover...]").
			-- A path that reduces to nothing but #showtooltip + /target/#-lines is not
			-- a real step — emitting it inserts a dead press that just retargets and
			-- casts nothing (the spurious "Step 2" on the Disc branch). Require at
			-- least one /cast, /use, or /click line. This is the CANONICAL macro
			-- (all characters); live per-character filtering happens at runtime.
			if macroText:match("\n/cast") or macroText:match("\n/use") or macroText:match("\n/click") then
				-- Record this step's node ids so the runtime can re-filter just this
				-- path per character without re-enumerating the graph.
				local pathNodeIds = {}
				for _, n in ipairs(pathNodes) do
					tinsert(pathNodeIds, n.id)
				end

				-- Promote a shared node condition to the SLOT level so the engine can
				-- hide the whole slot when the condition isn't met (e.g. a [combat]-only
				-- step is hidden out of combat), not merely gate the cast. If every node
				-- in this step carries the same single condition, use it; if they differ
				-- (or some are unconditional), leave slot conditions blank and let the
				-- per-line macro conditions do the gating at cast time.
				local stepCondition = nil
				local mixed = false
				for _, n in ipairs(pathNodes) do
					local c = n.condition or ""
					if c ~= "" then
						if stepCondition == nil then
							stepCondition = c
						elseif stepCondition ~= c then
							mixed = true
							break
						end
					elseif stepCondition ~= nil then
						-- a later node has no condition while an earlier one did
						mixed = true
						break
					end
				end
				if mixed then
					stepCondition = nil
				end

				local compiledAction = {
					type = "misc",
					value = "custom_macro",
					macroText = macroText,
					conditions = stepCondition or "",
					exclusive = false,
					pathNodeIds = pathNodeIds,
				}
				-- Carry metadata from the first node with an action.
				local metaNode
				for _, n in ipairs(pathNodes) do
					if n.action then
						metaNode = n
						break
					end
				end
				if metaNode and metaNode.action then
					local firstAct = metaNode.action
					compiledAction.addedByClass = firstAct.addedByClass
					compiledAction.addedBySpec = firstAct.addedBySpec
					compiledAction.talentRequirements = firstAct.talentRequirements
					compiledAction.category = firstAct.category
				end

				tinsert(newActions, compiledAction)
			end
		end
	end

	-- More than one surviving path => the press cycles through steps (sequence);
	-- a single path is a plain waterfall macro.
	newActions.conflictStrategy = (#newActions > 1) and "sequence" or "waterfall"

	return newActions
end

-- One-time data repair: regenerate a slot's compiled custom_macro actions from
-- its stored graph.  Early builds of the configurator wrote /cast and /use lines
-- using numeric spell/item IDs (action.value) instead of resolved names, so those
-- macros silently cast nothing.  Re-running the compiler over the preserved graph
-- rebuilds correct, castable macros (and clears the [[..]] double-bracket bug).
-- Returns true if the slot was rewritten.  Safe to call repeatedly; the version
-- guard in the loader prevents it from running more than once per profile.
function Wise:RepairCompiledSlotFromGraph(slotActions)
	if type(slotActions) ~= "table" then
		return false
	end
	local graph = slotActions.graph
	if not graph or type(graph.nodes) ~= "table" or #graph.nodes == 0 then
		return false
	end
	-- Only repair slots that were produced by the graph compiler (every state is
	-- a misc/custom_macro). Hand-authored multi-type slots are left untouched.
	local sawCompiled = false
	for _, state in ipairs(slotActions) do
		if type(state) == "table" then
			if state.type == "misc" and state.value == "custom_macro" then
				sawCompiled = true
			else
				return false
			end
		end
	end
	if not sawCompiled then
		return false
	end

	local rebuilt = CompileGraphToActions(graph, slotActions)
	-- Replace the array portion in place so any external references to the slot
	-- table (and its top-level keys like keybind/conflictStrategy) stay valid.
	for i = #slotActions, 1, -1 do
		slotActions[i] = nil
	end
	for i, state in ipairs(rebuilt) do
		slotActions[i] = state
	end
	slotActions.conflictStrategy = rebuilt.conflictStrategy
	slotActions.graph = rebuilt.graph
	return true
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
		state.graph = { nodes = {}, connections = {} }
		return
	end

	local strategy = actions.conflictStrategy or "waterfall"
	local parsed = {}
	for _, a in ipairs(items) do
		local mods, base = ParseModifiers(a.conditions)
		tinsert(parsed, { action = a, mods = mods, baseCond = base or "", modKey = ModSetKey(mods) })
	end

	local condGroups = {}
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
			local stack = {}
			for _, p in ipairs(g.items) do
				tinsert(stack, p.action)
			end
			state.grid[row][1] = stack
		else
			for col, p in ipairs(g.items) do
				state.grid[row][col] = { p.action }
				if col > maxCols then
					maxCols = col
				end
			end
		end

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

	if actions.graph then
		state.graph = { nodes = {}, connections = {} }
		for _, n in ipairs(actions.graph.nodes) do
			local cond = n.condition or ""
			if cond ~= "" then
				cond = cond:gsub("^%[%[+", "["):gsub("%]+$", "]")
			end
			tinsert(state.graph.nodes, {
				id = n.id,
				action = ShallowCopyAction(n.action),
				condition = cond,
			})
		end
		for _, c in ipairs(actions.graph.connections) do
			tinsert(state.graph.connections, {
				from = c.from,
				to = c.to,
				type = c.type,
			})
		end
	else
		state.graph = ConvertGridToGraph()
	end
	state.isDirty = false
end

local function ExportToSlotData()
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

	local newActions = CompileGraphToActions(state.graph, actions)
	group.actions[slotIdx] = newActions

	state.isDirty = false

	Wise:RefreshActionsView(Wise.OptionsFrame.Middle.Content)
	C_Timer.After(0, function()
		if not InCombatLockdown() then
			Wise:UpdateGroupDisplay(groupName)
		end
	end)
end

function Wise:ExportSlotConfiguratorData()
	ExportToSlotData()
end

-- Dedicated popup for the compiled-macro preview. GameTooltip truncates long
-- lines, so we render the full text into a scrollable, sized frame instead.
local macroPreviewPopup = nil
local function GetOrCreateMacroPreviewPopup()
	if macroPreviewPopup then
		return macroPreviewPopup
	end
	local p = CreateFrame("Frame", "WiseMacroPreviewPopup", UIParent, "BackdropTemplate")
	p:SetFrameStrata("TOOLTIP")
	p:SetWidth(440)
	p:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true,
		tileSize = 32,
		edgeSize = 16,
		insets = { left = 5, right = 5, top = 5, bottom = 5 },
	})
	p:Hide()

	p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	p.title:SetPoint("TOPLEFT", 12, -10)
	p.title:SetText("Compiled Macro")
	p.title:SetTextColor(1, 0.82, 0)

	p.footer = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	p.footer:SetPoint("BOTTOMLEFT", 12, 10)
	p.footer:SetPoint("BOTTOMRIGHT", -12, 10)
	p.footer:SetJustifyH("LEFT")
	p.footer:SetText("Reflects unsaved changes. Click Apply to commit.")

	-- Scrollable body so very tall macros stay fully readable.
	p.scroll = CreateFrame("ScrollFrame", "WiseMacroPreviewPopupScroll", p, "UIPanelScrollFrameTemplate")
	p.scroll:SetPoint("TOPLEFT", p.title, "BOTTOMLEFT", 0, -8)
	p.scroll:SetPoint("BOTTOMRIGHT", p.footer, "TOPRIGHT", -22, 8)

	p.content = CreateFrame("Frame", nil, p.scroll)
	p.content:SetSize(400, 10)
	p.scroll:SetScrollChild(p.content)

	p.text = p.content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	p.text:SetPoint("TOPLEFT", 0, 0)
	p.text:SetWidth(400)
	p.text:SetJustifyH("LEFT")
	p.text:SetJustifyV("TOP")
	-- Allow wrapping for genuinely long single lines, but the wide frame means
	-- typical macro lines fit on one line.
	p.text:SetWordWrap(true)
	p.text:SetSpacing(2)

	macroPreviewPopup = p
	return p
end

function Wise:ShowMacroPreviewPopup(anchorTo, pin)
	local p = GetOrCreateMacroPreviewPopup()
	if pin then
		p.pinned = true
	end
	local preview = Wise:BuildSlotMacroPreview()
	p.text:SetText(preview)

	-- Size the content + frame to the text, clamped to a max height with scroll.
	local textHeight = p.text:GetStringHeight() + 4
	p.content:SetHeight(textHeight)

	local chrome = 10 + 16 + 8 + 8 + 18 + 10 -- title, gaps, footer, insets
	local maxBodyHeight = 380
	local bodyHeight = math.min(textHeight, maxBodyHeight)
	p:SetHeight(bodyHeight + chrome)

	p:ClearAllPoints()
	if anchorTo then
		p:SetPoint("TOPRIGHT", anchorTo, "BOTTOMRIGHT", 0, -4)
	else
		p:SetPoint("CENTER")
	end
	p:Show()
end

function Wise:HideMacroPreviewPopup()
	-- A click pins the popup open; mouseleave should not dismiss a pinned popup.
	if macroPreviewPopup and not macroPreviewPopup.pinned then
		macroPreviewPopup:Hide()
	end
end

function Wise:ToggleMacroPreviewPopup(anchorTo)
	local p = GetOrCreateMacroPreviewPopup()
	if p:IsShown() and p.pinned then
		p.pinned = false
		p:Hide()
	else
		Wise:ShowMacroPreviewPopup(anchorTo, true)
	end
end

-- Compile the configurator's CURRENT (possibly unsaved) graph the same way Apply
-- would, and return a human-readable preview of the resulting macro(s) for the
-- mouseover viewer. Each compiled step becomes one macro block; multi-step slots
-- (sequence strategy) are shown as separate numbered steps.
function Wise:BuildSlotMacroPreview()
	local state = configuratorState
	if not state.groupName or not state.slotIdx then
		return "No slot loaded."
	end
	local group = WiseDB and WiseDB.groups and WiseDB.groups[state.groupName]
	local actions = group and group.actions and group.actions[state.slotIdx]
	if not actions then
		return "No slot data."
	end
	if not state.graph or not state.graph.nodes or #state.graph.nodes == 0 then
		return "|cff888888(empty — no actions)|r"
	end

	local compiled = CompileGraphToActions(state.graph, actions)

	-- Pre-filter each step for the current character so the preview matches what
	-- the engine will actually fire. The canonical compiled macro includes nodes for
	-- every class/spec; nodes that don't apply to this toon are stripped here.
	--
	-- A multi-spec branching graph compiles one canonical step per root-to-leaf path,
	-- and for a given character many of those branches strip down to the SAME macro
	-- (e.g. several branches that only leave the shared trinket/item head). Reduce the
	-- filtered steps to the genuinely distinct presses exactly as the live engine does
	-- (see UpdateGroupDisplay's seenLiveMacro + subset suppression) so the preview
	-- reflects what the bar actually fires. Two-stage reduction:
	--   1. Drop empty/#showtooltip-only steps and byte-identical clones.
	--   2. Drop any step whose castable lines are a subset of another kept step's — a
	--      collapsed branch that fires nothing distinct (the spurious head-only step).
	local candidates = {}
	local seenText = {}
	for i = 1, #compiled do
		local st = compiled[i]
		if type(st) == "table" then
			local macroText = (Wise:FilterMacroTextForCharacter(st, compiled.graph))
			if macroText ~= "" and macroText ~= "#showtooltip" and not seenText[macroText] then
				seenText[macroText] = true
				tinsert(candidates, { text = macroText, cast = Wise:GetMacroCastSet(macroText) })
			end
		end
	end

	local filteredSteps = {}
	for i, cand in ipairs(candidates) do
		local dominated = false
		for j, other in ipairs(candidates) do
			if i ~= j and Wise:MacroCastSetIsSubset(cand.cast, other.cast) then
				-- cand ⊆ other. Drop cand if other is strictly larger, or (equal sets,
				-- already byte-distinct text) keep the earlier one to stay deterministic.
				local sizeC, sizeO = 0, 0
				for _ in pairs(cand.cast) do
					sizeC = sizeC + 1
				end
				for _ in pairs(other.cast) do
					sizeO = sizeO + 1
				end
				if sizeC < sizeO or (sizeC == sizeO and j < i) then
					dominated = true
					break
				end
			end
		end
		if not dominated then
			tinsert(filteredSteps, cand.text)
		end
	end

	local visibleStepCount = #filteredSteps

	if visibleStepCount == 0 then
		return "|cffff8080(nothing castable on this character — all actions filtered out by availability)|r"
	end

	-- A single surviving step fires as a plain single-shot regardless of the canonical
	-- strategy, so describe it that way to match the bar's behaviour.
	local strategy = (visibleStepCount > 1) and (compiled.conflictStrategy or "waterfall") or "single"

	local lines = {}
	tinsert(
		lines,
		"|cffffd100Strategy:|r " .. strategy .. (visibleStepCount > 1 and (" (" .. visibleStepCount .. " steps)") or "")
	)

	for stepIdx, macroText in ipairs(filteredSteps) do
		if visibleStepCount > 1 then
			tinsert(lines, " ")
			tinsert(lines, "|cff00ccffStep " .. stepIdx .. ":|r")
		end
		for line in (macroText .. "\n"):gmatch("(.-)\n") do
			tinsert(lines, line)
		end
	end

	return table.concat(lines, "\n")
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
					state.isDirty = true
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
			state.isDirty = true
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
						state.isDirty = true
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
											state.isDirty = true
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
			state.isDirty = true
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
local nodeLinePool = {}
local nodeLineHandlePool = {}
local nodeSectionHeaderPool = {}

-- Branch section header: a label + thin divider naming the availability signature
-- that defines a branch group on the canvas (e.g. "+(Druid)", "Everything else").
local function GetOrCreateSectionHeader(parent, index)
	if nodeSectionHeaderPool[index] then
		nodeSectionHeaderPool[index]:SetParent(parent)
		nodeSectionHeaderPool[index]:Show()
		return nodeSectionHeaderPool[index]
	end
	local h = CreateFrame("Frame", nil, parent)
	h:SetHeight(20)
	h.label = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	h.label:SetPoint("LEFT", h, "LEFT", 0, 0)
	h.label:SetTextColor(1, 0.82, 0)
	h.rule = h:CreateTexture(nil, "ARTWORK")
	h.rule:SetColorTexture(0.4, 0.4, 0.5, 0.6)
	h.rule:SetHeight(1)
	h.rule:SetPoint("LEFT", h.label, "RIGHT", 8, 0)
	h.rule:SetPoint("RIGHT", h, "RIGHT", 0, 0)
	nodeSectionHeaderPool[index] = h
	return h
end

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
	card.icon:SetSize(NODE_ICON_SIZE - 10, NODE_ICON_SIZE - 10)
	card.icon:SetPoint("LEFT", 8, 0)
	card.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	card.iconBorder = card:CreateTexture(nil, "OVERLAY")
	card.iconBorder:SetPoint("TOPLEFT", card.icon, -2, 2)
	card.iconBorder:SetPoint("BOTTOMRIGHT", card.icon, 2, -2)
	card.iconBorder:SetColorTexture(0, 0.7, 1, 0.25)

	card.nameLabel = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	card.nameLabel:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 10, -6)
	card.nameLabel:SetPoint("RIGHT", -24, 0)
	card.nameLabel:SetJustifyH("LEFT")
	card.nameLabel:SetMaxLines(1)

	-- Condition button inside the card
	card.condBtn = CreateFrame("Button", nil, card, "BackdropTemplate")
	card.condBtn:SetSize(130, 18)
	card.condBtn:SetPoint("BOTTOMLEFT", card.icon, "BOTTOMRIGHT", 10, 6)
	card.condBtn:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 12,
		edgeSize = 8,
		insets = { left = 1, right = 1, top = 1, bottom = 1 },
	})
	card.condBtn:SetBackdropColor(0.08, 0.08, 0.10, 0.9)
	card.condBtn:SetBackdropBorderColor(0.35, 0.35, 0.45, 0.8)

	card.condBtn.label = card.condBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	card.condBtn.label:SetPoint("LEFT", 4, 0)
	card.condBtn.label:SetPoint("RIGHT", -4, 0)
	card.condBtn.label:SetJustifyH("LEFT")
	card.condBtn.label:SetMaxLines(1)

	-- Visibility/availability summary, shown beneath the condition bubble — the
	-- same "+(Spec) -(Role)" tag as the Slots and Actions list.
	card.visLabel = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	card.visLabel:SetPoint("TOPLEFT", card.condBtn, "BOTTOMLEFT", 1, -2)
	card.visLabel:SetPoint("RIGHT", card, "RIGHT", -6, 0)
	card.visLabel:SetJustifyH("LEFT")
	card.visLabel:SetMaxLines(1)

	card.removeBtn = CreateFrame("Button", nil, card)
	card.removeBtn:SetSize(14, 14)
	card.removeBtn:SetPoint("TOPRIGHT", -4, -4)
	card.removeBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
	card.removeBtn:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")

	card.highlight = card:CreateTexture(nil, "HIGHLIGHT")
	card.highlight:SetAllPoints()
	card.highlight:SetColorTexture(1, 0.82, 0, 0.1)

	card.dragHighlight = card:CreateTexture(nil, "OVERLAY")
	card.dragHighlight:SetAllPoints()
	card.dragHighlight:SetColorTexture(1, 0.82, 0, 0.15)
	card.dragHighlight:Hide()

	-- 3 Connection Dots: Top, Right, Bottom
	local function CreateConnectionDot(point, x, y, name)
		local dot = CreateFrame("Button", nil, card, "BackdropTemplate")
		dot:SetSize(12, 12)
		dot:SetPoint(point, card, point, x, y)
		dot:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true,
			tileSize = 8,
			edgeSize = 6,
			insets = { left = 1, right = 1, top = 1, bottom = 1 },
		})
		dot:SetBackdropColor(0.2, 0.7, 1, 0.9)
		dot:SetBackdropBorderColor(1, 1, 1, 1)

		local highlight = dot:CreateTexture(nil, "HIGHLIGHT")
		highlight:SetAllPoints()
		highlight:SetColorTexture(1, 1, 1, 0.4)

		dot.name = name
		return dot
	end

	-- Only Top and Bottom dots are interactive. Sequences are now expressed purely
	-- by splitting: a node whose BOTTOM feeds multiple children's TOPs starts a
	-- sequence (one step per branch). The old left/right "sequence" dots are gone —
	-- every connection is a top<->bottom edge now. We still create hidden left/right
	-- frames so older layout/handle code that references them stays nil-safe.
	card.dotTop = CreateConnectionDot("TOP", 0, 6, "top")
	card.dotBottom = CreateConnectionDot("BOTTOM", 0, -6, "bottom")
	card.dotRight = CreateConnectionDot("RIGHT", 6, 0, "right")
	card.dotLeft = CreateConnectionDot("LEFT", -6, 0, "left")
	card.dotRight:Hide()
	card.dotLeft:Hide()

	nodeCardPool[index] = card
	return card
end

local function GetOrCreateNodeLine(parent, index)
	if nodeLinePool[index] then
		nodeLinePool[index]:Show()
		return nodeLinePool[index]
	end
	local line = parent:CreateLine(nil, "ARTWORK")
	nodeLinePool[index] = line
	return line
end

local function GetOrCreateLineHandle(parent, index)
	if nodeLineHandlePool[index] then
		nodeLineHandlePool[index]:SetParent(parent)
		return nodeLineHandlePool[index]
	end
	local handle = CreateFrame("Button", nil, parent, "BackdropTemplate")
	handle:SetSize(20, 20)
	handle:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 12,
		edgeSize = 8,
		insets = { left = 1, right = 1, top = 1, bottom = 1 },
	})
	handle:SetBackdropColor(0.15, 0.15, 0.2, 0.85)
	handle:SetBackdropBorderColor(0.4, 0.4, 0.5, 0.8)

	handle.label = handle:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	handle.label:SetPoint("CENTER", 0, 0)
	handle.label:SetText("x")

	local highlight = handle:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetColorTexture(1, 1, 1, 0.2)

	nodeLineHandlePool[index] = handle
	return handle
end

-- Layout and Connection Drawing State
local drawState = {
	active = false,
	fromNode = nil,
	fromType = nil, -- "waterfall" | "sequence"
}

local function GetNextNodeId()
	local maxId = 0
	if configuratorState.graph and configuratorState.graph.nodes then
		for _, n in ipairs(configuratorState.graph.nodes) do
			if n.id > maxId then
				maxId = n.id
			end
		end
	end
	return maxId + 1
end

local function GetRealConnectionsFor(conn, graphConns)
	for _, oc in ipairs(graphConns) do
		if oc.from == conn.from and oc.to == conn.to and oc.type == conn.type then
			return { oc }
		end
	end
	local real = {}
	if conn.sources then
		for _, src in ipairs(conn.sources) do
			local sub = GetRealConnectionsFor(src, graphConns)
			for _, sc in ipairs(sub) do
				tinsert(real, sc)
			end
		end
	end
	return real
end

local function GetFilteredGraph(graph)
	local activeNodeIds = {}
	local filteredNodes = {}
	for _, n in ipairs(graph.nodes) do
		if not IsFilterHiding(n.action) then
			tinsert(filteredNodes, n)
			activeNodeIds[n.id] = true
		end
	end

	local conns = {}
	for _, c in ipairs(graph.connections) do
		tinsert(conns, { from = c.from, to = c.to, type = c.type })
	end

	-- Contract hidden nodes one by one
	for _, n in ipairs(graph.nodes) do
		local hid = n.id
		if not activeNodeIds[hid] then
			-- Find incoming and outgoing
			local incoming = {}
			local outgoing = {}
			for i = #conns, 1, -1 do
				local c = conns[i]
				if c.to == hid then
					tinsert(incoming, c)
					table.remove(conns, i)
				elseif c.from == hid then
					tinsert(outgoing, c)
					table.remove(conns, i)
				end
			end
			-- Bridge them
			for _, inc in ipairs(incoming) do
				for _, out in ipairs(outgoing) do
					local exists = false
					local newType = (inc.type == "sequence" or out.type == "sequence") and "sequence" or "waterfall"
					for _, ec in ipairs(conns) do
						if ec.from == inc.from and ec.to == out.to and ec.type == newType then
							exists = true
							break
						end
					end
					if not exists then
						tinsert(conns, {
							from = inc.from,
							to = out.to,
							type = newType,
							sources = { inc, out },
						})
					end
				end
			end
		end
	end

	return { nodes = filteredNodes, connections = conns }
end

-- ═══════════════════════════════════════════════════════════════
-- Nodes View Rendering (fully interactive node flow)
-- ═══════════════════════════════════════════════════════════════
RenderNodesCanvas = function()
	local sc = Wise.SlotConfigurator
	if not sc or not sc.nodesCanvas then
		return
	end

	local canvas = sc.nodesCanvas
	local state = configuratorState

	HideAllNodePooled()
	for _, line in pairs(nodeLinePool) do
		line:Hide()
	end
	for _, handle in pairs(nodeLineHandlePool) do
		handle:Hide()
	end
	for _, header in pairs(nodeSectionHeaderPool) do
		header:Hide()
	end

	if not state.graph then
		state.graph = { nodes = {}, connections = {} }
	end

	-- Drag drop support for canvas background
	canvas:SetScript("OnReceiveDrag", function()
		local cursorType, id = GetCursorInfo()
		if cursorType then
			local actionData = Wise:CursorToActionData(cursorType, id)
			if actionData then
				local newNode = {
					id = GetNextNodeId(),
					action = actionData,
					condition = "",
				}
				tinsert(state.graph.nodes, newNode)
				ClearCursor()
				RenderNodesCanvas()
			end
		end
	end)

	local displayGraph = GetFilteredGraph(state.graph)
	local cols, rows = ComputeNodeLayout(displayGraph)

	-- Spacing configurations
	local colWidth = 320
	local rowHeight = 120
	local startX = 40
	local startY = -40

	-- ── Sequence lanes ───────────────────────────────────────────────
	-- Sequences are now expressed by BRANCHING: a node whose bottom feeds several
	-- children starts a sequence, one STEP per child. We lay the graph out in
	-- vertical lanes so it reads like the compiled macro:
	--   * The SHARED HEAD (the single-child spine from the root down to the first
	--     branch) occupies one lane and gets no header.
	--   * At a branch, each child subtree gets its OWN lane to the right, headed
	--     "Step 1", "Step 2", ... in left-to-right order. Lines fan out from the
	--     branch node into each step lane.
	-- This is display-only: the saved graph/connections and the path compiler are
	-- untouched, and the class/role/spec filter still removes whole branches first.
	local adj = {}
	local indeg = {}
	for _, node in ipairs(displayGraph.nodes) do
		indeg[node.id] = indeg[node.id] or 0
	end
	for _, c in ipairs(displayGraph.connections) do
		adj[c.from] = adj[c.from] or {}
		tinsert(adj[c.from], c.to)
		indeg[c.to] = (indeg[c.to] or 0) + 1
	end

	-- Assign a lane index and a depth (row) to each node by walking from the roots.
	-- A node continues its parent's lane when it is that parent's ONLY child;
	-- otherwise each child opens a fresh lane. EVERY root gets its OWN lane (two
	-- independent chains must never share a column, or their cards stack). A lane
	-- is a "step" (gets a "Step N" header) only when it was spawned by a BRANCH
	-- (a node with more than one child). Independent root chains are not steps.
	local laneOf = {}
	local depthOf = {}
	local laneIsStep = {} -- lane index -> true if it is a branched step (gets header)
	local nextLane = 0
	local laneSeq = {} -- lane creation order (left-to-right column order)

	local function newLane(isStep)
		local lane = nextLane
		nextLane = nextLane + 1
		tinsert(laneSeq, lane)
		laneIsStep[lane] = isStep or nil
		return lane
	end

	local function assign(nodeId, lane, depth, visited)
		if visited[nodeId] then
			return
		end
		visited[nodeId] = true
		laneOf[nodeId] = lane
		depthOf[nodeId] = depth
		local kids = adj[nodeId]
		if not kids or #kids == 0 then
			return
		end
		if #kids == 1 then
			-- Continuation: same lane, one row deeper.
			assign(kids[1], lane, depth + 1, visited)
		else
			-- Branch: each child opens its own step lane.
			for _, kid in ipairs(kids) do
				assign(kid, newLane(true), depth + 1, visited)
			end
		end
	end

	do
		local visited = {}
		-- Each root (no incoming edge) starts its own lane, then any orphan/cycle.
		for _, node in ipairs(displayGraph.nodes) do
			if (indeg[node.id] or 0) == 0 then
				assign(node.id, newLane(false), 1, visited)
			end
		end
		for _, node in ipairs(displayGraph.nodes) do
			if not visited[node.id] then
				assign(node.id, newLane(false), 1, visited)
			end
		end
	end

	-- Columns follow lane creation order left-to-right. Number the step lanes
	-- (those spawned by a branch) "Step 1..N"; non-step lanes get no header.
	local laneColumn = {} -- lane -> 0-based column slot
	local laneLabel = {} -- lane -> header text (nil = no header)

	-- Collect the nodes in each lane (top-to-bottom by depth) so we can describe
	-- what conditions/availability that column belongs to in its header.
	local laneNodes = {}
	for _, node in ipairs(displayGraph.nodes) do
		local lane = laneOf[node.id]
		if lane ~= nil then
			laneNodes[lane] = laneNodes[lane] or {}
			tinsert(laneNodes[lane], node)
		end
	end
	for _, list in pairs(laneNodes) do
		table.sort(list, function(a, b)
			return (depthOf[a.id] or 0) < (depthOf[b.id] or 0)
		end)
	end

	-- Derive a short condition/availability description for a lane: the distinct
	-- availability tags (+(Spec)/-(Role) etc.) of its nodes, plus any explicit node
	-- conditions ([@mouseover] and the like). Returns "" when nothing distinctive.
	local function LaneConditionLabel(lane)
		local parts = {}
		local seen = {}
		for _, node in ipairs(laneNodes[lane] or {}) do
			local vis = Wise.GetActionVisibilitySummary and Wise:GetActionVisibilitySummary(node.action) or ""
			if vis ~= "" and not seen[vis] then
				seen[vis] = true
				tinsert(parts, vis)
			end
			local cond = node.condition
			if cond and cond ~= "" and not seen[cond] then
				seen[cond] = true
				tinsert(parts, cond)
			end
		end
		return table.concat(parts, "  ")
	end

	local stepNum = 0
	for col, lane in ipairs(laneSeq) do
		laneColumn[lane] = col - 1
		local cond = LaneConditionLabel(lane)
		if laneIsStep[lane] then
			stepNum = stepNum + 1
			if cond ~= "" then
				laneLabel[lane] = "Step " .. stepNum .. "  |cffaaaaaa" .. cond .. "|r"
			else
				laneLabel[lane] = "Step " .. stepNum
			end
		elseif cond ~= "" then
			-- Non-step columns (shared head / independent chains) still get a header
			-- describing their condition so the user can tell what they belong to.
			laneLabel[lane] = cond
		end
	end

	-- Headers appear whenever any column has a label (a step or a condition).
	local anyLabel = false
	for _, lane in ipairs(laneSeq) do
		if laneLabel[lane] then
			anyLabel = true
			break
		end
	end
	local multiSection = anyLabel
	local HEADER_GAP = multiSection and 34 or 0
	local SECTION_GAP = 0 -- lanes are colWidth apart; headers span their own column

	local nodeX = {}
	local nodeY = {}
	-- Section header bookkeeping keyed by lane (only step lanes get headers).
	local sectionOrder = {} -- list of lanes that have headers
	local sectionHeaderX = {}
	local sectionHeaderY = {}
	local sectionWidth = {}
	local SectionLabel = function(lane)
		return laneLabel[lane] or ""
	end
	local sectionTopY = startY
	local layoutBottomY = startY
	local layoutRightX = startX

	local bandTopY = sectionTopY - HEADER_GAP
	for _, node in ipairs(displayGraph.nodes) do
		local lane = laneOf[node.id] or 0
		local col = laneColumn[lane] or 0
		local depth = depthOf[node.id] or 1
		nodeX[node.id] = startX + col * (colWidth + SECTION_GAP)
		nodeY[node.id] = bandTopY - (depth - 1) * rowHeight
		local rightEdge = nodeX[node.id] + colWidth
		if rightEdge > layoutRightX then
			layoutRightX = rightEdge
		end
		local thisBottom = nodeY[node.id] - rowHeight
		if thisBottom < layoutBottomY then
			layoutBottomY = thisBottom
		end
	end

	-- Header positions: one per labelled lane (a step, or a column with a condition).
	if multiSection then
		for _, lane in ipairs(laneSeq) do
			if laneLabel[lane] then
				tinsert(sectionOrder, lane)
				local col = laneColumn[lane] or 0
				sectionHeaderX[lane] = startX + col * (colWidth + SECTION_GAP)
				sectionHeaderY[lane] = sectionTopY
				sectionWidth[lane] = colWidth
			end
		end
	end

	-- Helpers: resolve a node's absolute X/Y, used by cards & lines.
	local function NodeX(id)
		return nodeX[id] or (startX + ((cols[id] or 1) - 1) * colWidth)
	end
	local function NodeY(id)
		return nodeY[id] or (startY - ((rows[id] or 1) - 1) * rowHeight)
	end

	-- Card index tracker
	local cardIdx = 1
	local cardFrames = {} -- map of nodeId -> card frame

	-- Draw Cards
	for _, node in ipairs(displayGraph.nodes) do
		local card = GetOrCreateNodeCard(canvas, cardIdx)
		cardIdx = cardIdx + 1
		cardFrames[node.id] = card

		local x = NodeX(node.id)
		local y = NodeY(node.id)

		card:ClearAllPoints()
		card:SetPoint("TOPLEFT", canvas, "TOPLEFT", x, y)

		-- Action Info
		local a = node.action
		local iconTex = Wise:GetActionIcon(a.type, a.value, a)
		card.icon:SetTexture(iconTex or "Interface\\Icons\\INV_Misc_QuestionMark")

		local name = Wise:GetActionName(a.type, a.value, a) or "Unknown"
		card.nameLabel:SetText(name)

		-- Condition
		if node.condition and node.condition ~= "" then
			card.condBtn.label:SetText(node.condition)
			card.condBtn.label:SetTextColor(0, 0.8, 1)
		else
			card.condBtn.label:SetText("|cff888888Always|r")
		end

		-- Visibility/availability tag (matches the Slots and Actions list).
		local visText = Wise.GetActionVisibilitySummary and Wise:GetActionVisibilitySummary(a) or ""
		if visText ~= "" then
			card.visLabel:SetText(visText)
			card.visLabel:Show()
		else
			card.visLabel:SetText("")
			card.visLabel:Hide()
		end

		card.condBtn:SetScript("OnClick", function()
			if Wise.pickingCondition and Wise._conditionPickerState then
				local prevNode = Wise._configuratorConditionNode
				if prevNode then
					prevNode.condition = BuildConditionString(Wise._conditionPickerState.groups)
				end
			end
			Wise._conditionPickerState = {
				groups = ParseConditionString(node.condition or ""),
				activeGroup = 1,
			}
			Wise._configuratorConditionNode = node
			Wise.pickingCondition = true
			Wise:RefreshPropertiesPanel()
		end)

		-- Clicking the card body opens this action's Availability Filtering panel
		-- (Class/Spec/Talent/Role/Character) on the right, the same restrictions
		-- editor that drives the +(Spec)/+(Class) tags in the Slots and Actions list.
		card:SetScript("OnClick", function()
			Wise.pickingRestrictions = true
			Wise.pickingRestrictionsAction = node.action
			Wise:RefreshPropertiesPanel()
		end)

		local br, bg, bb, ba
		if hidden then
			card:SetAlpha(0.4)
			br, bg, bb, ba = 0.5, 0.2, 0.2, 0.8
			card.nameLabel:SetText(name .. " |cffFF3333[Filtered]|r")
		elseif not live then
			card:SetAlpha(0.65)
			br, bg, bb, ba = 0.3, 0.3, 0.35, 0.6
		else
			card:SetAlpha(1)
			br, bg, bb, ba = 0.45, 0.45, 0.55, 1
		end
		card:SetBackdropBorderColor(br, bg, bb, ba)
		card._origBorder = { br, bg, bb, ba }

		-- Remove card
		card.removeBtn:SetScript("OnClick", function()
			-- Remove node and all its connections
			local newNodes = {}
			for _, n in ipairs(state.graph.nodes) do
				if n.id ~= node.id then
					tinsert(newNodes, n)
				end
			end
			state.graph.nodes = newNodes

			local newConns = {}
			for _, c in ipairs(state.graph.connections) do
				if c.from ~= node.id and c.to ~= node.id then
					tinsert(newConns, c)
				end
			end
			state.graph.connections = newConns

			state.isDirty = true
			RenderNodesCanvas()
		end)

		-- Connection Dots Drag Handlers
		local function SetupDot(dot, typeName)
			dot:SetScript("OnMouseDown", function()
				if InCombatLockdown() then
					return
				end
				-- Start drawing
				drawState.active = true
				drawState.fromNode = node.id
				drawState.fromType = typeName
				drawState.fromDot = dot
				drawState.hoveredNode = nil

				canvas:SetScript("OnUpdate", function()
					if not drawState.active then
						canvas:SetScript("OnUpdate", nil)
						return
					end
					local cursorX, cursorY = GetCursorPosition()
					local scale = canvas:GetEffectiveScale()
					if cursorX then
						local tempLine = GetOrCreateNodeLine(canvas, 9999)
						tempLine:SetThickness(2)
						tempLine:SetColorTexture(0.2, 1, 0.5, 0.7)

						-- Calculate algebraic start point of dot relative to canvas BOTTOMLEFT
						local col = cols[node.id] or 1
						local row = rows[node.id] or 1
						local cardX = startX + (col - 1) * colWidth
						local cardY = startY - (row - 1) * rowHeight
						local canvasH = canvas:GetHeight() or 400

						local dotX = cardX
						local dotY = canvasH + cardY

						local dotName = dot.name
						if dotName == "top" then
							dotX = dotX + NODE_CARD_WIDTH / 2
							dotY = dotY + 6
						elseif dotName == "bottom" then
							dotX = dotX + NODE_CARD_WIDTH / 2
							dotY = dotY - NODE_CARD_HEIGHT - 6
						elseif dotName == "left" then
							dotX = dotX - 6
							dotY = dotY - NODE_CARD_HEIGHT / 2
						elseif dotName == "right" then
							dotX = dotX + NODE_CARD_WIDTH + 6
							dotY = dotY - NODE_CARD_HEIGHT / 2
						end

						tempLine:SetStartPoint("BOTTOMLEFT", canvas, dotX, dotY)

						local cl, cb = canvas:GetRect()
						if cl and cb then
							local relX = (cursorX / scale) - cl
							local relY = (cursorY / scale) - cb
							tempLine:SetEndPoint("BOTTOMLEFT", canvas, relX, relY)
						end
					end

					-- Detect hovered node card (expanded by 20px padding)
					local bestHoverId = nil
					for id, cardFrame in pairs(cardFrames) do
						if id ~= drawState.fromNode then
							local l, b, w, h = cardFrame:GetRect()
							local scale = cardFrame:GetEffectiveScale()
							if l and scale then
								local cx = cursorX / scale
								local cy = cursorY / scale
								if cx >= l - 20 and cx <= l + w + 20 and cy >= b - 20 and cy <= b + h + 20 then
									bestHoverId = id
									break
								end
							end
						end
					end

					-- Update highlights (Gold border & overlay for drop target)
					for id, cardFrame in pairs(cardFrames) do
						if id == bestHoverId then
							if cardFrame.dragHighlight then
								cardFrame.dragHighlight:Show()
							end
							cardFrame:SetBackdropBorderColor(1, 0.82, 0, 1)
						else
							if cardFrame.dragHighlight then
								cardFrame.dragHighlight:Hide()
							end
							if cardFrame._origBorder then
								cardFrame:SetBackdropBorderColor(
									cardFrame._origBorder[1],
									cardFrame._origBorder[2],
									cardFrame._origBorder[3],
									cardFrame._origBorder[4]
								)
							end
						end
					end
					drawState.hoveredNode = bestHoverId
				end)
			end)

			dot:SetScript("OnMouseUp", function()
				if not drawState.active then
					return
				end
				drawState.active = false
				canvas:SetScript("OnUpdate", nil)
				local tempLine = nodeLinePool[9999]
				if tempLine then
					tempLine:Hide()
				end

				-- Hide all highlights
				for _, cardFrame in pairs(cardFrames) do
					if cardFrame.dragHighlight then
						cardFrame.dragHighlight:Hide()
					end
				end

				-- Complete connection
				local target = drawState.hoveredNode
				if target and target ~= drawState.fromNode then
					local finalFrom, finalTo
					local dotName = drawState.fromDot and drawState.fromDot.name
					if dotName == "left" or dotName == "top" then
						finalFrom = target
						finalTo = drawState.fromNode
					else
						finalFrom = drawState.fromNode
						finalTo = target
					end

					-- Prevent duplicate connection
					local exists = false
					for _, c in ipairs(state.graph.connections) do
						if c.from == finalFrom and c.to == finalTo and c.type == drawState.fromType then
							exists = true
							break
						end
					end
					if not exists then
						tinsert(state.graph.connections, {
							from = finalFrom,
							to = finalTo,
							type = drawState.fromType,
						})
						state.isDirty = true
					end
				end

				drawState.hoveredNode = nil
				RenderNodesCanvas()
			end)
		end

		-- Only top/bottom dots are wired for dragging now. All edges are "waterfall".
		SetupDot(card.dotBottom, "waterfall")
		SetupDot(card.dotTop, "waterfall")

		card:Show()
	end

	-- Draw Connection Lines & Handles
	local lineIdx = 1
	local handleIdx = 1
	for _, conn in ipairs(displayGraph.connections) do
		local fromCard = cardFrames[conn.from]
		local toCard = cardFrames[conn.to]
		if fromCard and toCard then
			local line = GetOrCreateNodeLine(canvas, lineIdx)
			lineIdx = lineIdx + 1

			-- Check if it is a real connection (exists in unfiltered graph)
			local isReal = false
			for _, oc in ipairs(state.graph.connections) do
				if oc.from == conn.from and oc.to == conn.to and oc.type == conn.type then
					isReal = true
					break
				end
			end

			-- All edges anchor bottom->top now (left/right "sequence" dots are gone;
			-- sequences are shown by the branch fanning out into Step lanes). Legacy
			-- saved graphs may still carry type="sequence" connections — we draw them
			-- the same way so they remain visible and deletable.
			if isReal then
				line:SetThickness(2)
				line:SetColorTexture(0.2, 1, 0.5, 0.8) -- Green
			else
				line:SetThickness(1.5)
				line:SetColorTexture(0.2, 1, 0.5, 0.35) -- Faded green bridged
			end
			line:SetStartPoint("CENTER", fromCard.dotBottom)
			line:SetEndPoint("CENTER", toCard.dotTop)

			-- Always render delete handle (both real and bridged connections)
			local handle = GetOrCreateLineHandle(canvas, handleIdx)
			handleIdx = handleIdx + 1

			-- Compute midpoint algebraically from card layouts (avoids WoW delayed layout/GetCenter nil issues)
			local fx = NodeX(conn.from)
			local fy = NodeY(conn.from)
			local fromCenterX = fx + NODE_CARD_WIDTH / 2
			local fromCenterY = fy - NODE_CARD_HEIGHT / 2

			local tx = NodeX(conn.to)
			local ty = NodeY(conn.to)
			local toCenterX = tx + NODE_CARD_WIDTH / 2
			local toCenterY = ty - NODE_CARD_HEIGHT / 2

			local midX = (fromCenterX + toCenterX) / 2
			local midY = (fromCenterY + toCenterY) / 2

			handle:ClearAllPoints()
			handle:SetPoint("CENTER", canvas, "TOPLEFT", midX, midY)
			handle:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			handle.line = line
			handle.connType = conn.type

			handle:SetScript("OnEnter", function(self)
				self:SetBackdropColor(0.6, 0.1, 0.1, 0.95)
				self:SetBackdropBorderColor(1, 0.82, 0, 1)
				if self.line then
					self.line:SetThickness(4)
					self.line:SetColorTexture(1, 0.82, 0, 1) -- Gold highlight
				end
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetText("Connection Line", 1, 1, 1)
				GameTooltip:AddLine("Right-click to delete this connection.", 1, 0.3, 0.3, true)
				GameTooltip:Show()
			end)

			handle:SetScript("OnLeave", function(self)
				self:SetBackdropColor(0.15, 0.15, 0.2, 0.85)
				self:SetBackdropBorderColor(0.4, 0.4, 0.5, 0.8)
				if self.line then
					self.line:SetThickness(2)
					if self.connType == "sequence" then
						self.line:SetColorTexture(0.2, 0.8, 1, 0.8)
					else
						self.line:SetColorTexture(0.2, 1, 0.5, 0.8)
					end
				end
				GameTooltip:Hide()
			end)

			handle:SetScript("OnClick", function(self, button)
				if button == "RightButton" then
					if not StaticPopupDialogs["WISE_DELETE_CONN"] then
						StaticPopupDialogs["WISE_DELETE_CONN"] = {
							text = "Delete this connection?",
							button1 = "Yes",
							button2 = "No",
							OnAccept = function(self, data)
								local cToDelete = data.conn
								local gState = data.state
								-- Get all underlying real connections to delete
								local toDeleteList = GetRealConnectionsFor(cToDelete, gState.graph.connections)
								local newConns = {}
								for _, c in ipairs(gState.graph.connections) do
									local match = false
									for _, td in ipairs(toDeleteList) do
										if c.from == td.from and c.to == td.to and c.type == td.type then
											match = true
											break
										end
									end
									if not match then
										tinsert(newConns, c)
									end
								end
								gState.graph.connections = newConns
								gState.isDirty = true
								RenderNodesCanvas()
							end,
							timeout = 0,
							whileDead = true,
							hideOnEscape = true,
						}
					end
					StaticPopup_Show("WISE_DELETE_CONN", nil, nil, { conn = conn, state = state })
				end
			end)
			handle:Show()
		end
	end

	-- Draw branch section headers (only when there is more than one branch). Each
	-- header sits atop its own column band, spanning that band's width.
	if multiSection then
		local hdrIdx = 1
		for _, sig in ipairs(sectionOrder) do
			local header = GetOrCreateSectionHeader(canvas, hdrIdx)
			hdrIdx = hdrIdx + 1
			header.label:SetText(SectionLabel(sig))
			header:SetWidth((sectionWidth[sig] or colWidth) - 20)
			header:ClearAllPoints()
			header:SetPoint(
				"TOPLEFT",
				canvas,
				"TOPLEFT",
				sectionHeaderX[sig] or startX,
				(sectionHeaderY[sig] or startY) - 2
			)
			header:Show()
		end
	end

	-- The "+ Add Node" button now lives in the top toolbar (created in
	-- CreateSlotConfiguratorUI, centered between View Macro and Apply Changes), so
	-- there is nothing to place inside the canvas anymore — just make sure it shows.
	if sc.nodesAddBtn then
		sc.nodesAddBtn:Show()
	end

	-- Determine layout size and resize canvas. With branches laid out side by side,
	-- width comes from the rightmost band edge and height from the tallest band.
	local bottomY = layoutBottomY + rowHeight - NODE_CARD_HEIGHT

	local totalWidth = layoutRightX + 100
	local totalHeight = math.abs(bottomY) + 80
	local canvasW = math.max(totalWidth, 600)
	canvas:SetSize(canvasW, math.max(totalHeight, 400))

	-- Refresh the horizontal scrollbar range now that the canvas width is known.
	if sc.nodesHScroll and sc.nodesCanvasScroll then
		local viewW = sc.nodesCanvasScroll:GetWidth() or 0
		local maxScroll = math.max(0, canvasW - viewW)
		sc.nodesHScroll:SetMinMaxValues(0, maxScroll)
		if sc.nodesHScroll:GetValue() > maxScroll then
			sc.nodesHScroll:SetValue(maxScroll)
		end
		-- Hide the bar (and its arrow buttons) when nothing overflows horizontally.
		if maxScroll <= 0 then
			sc.nodesHScroll:Hide()
			if sc.nodesHScrollLeft then
				sc.nodesHScrollLeft:Hide()
			end
			if sc.nodesHScrollRight then
				sc.nodesHScrollRight:Hide()
			end
			sc.nodesCanvasScroll:SetHorizontalScroll(0)
		else
			sc.nodesHScroll:Show()
			if sc.nodesHScrollLeft then
				sc.nodesHScrollLeft:Show()
			end
			if sc.nodesHScrollRight then
				sc.nodesHScrollRight:Show()
			end
		end
	end
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
			local newCond = BuildConditionString(Wise._conditionPickerState.groups)
			if configuratorState.rowConditions[prevRow] ~= newCond then
				configuratorState.rowConditions[prevRow] = newCond
				configuratorState.isDirty = true
			end
		end
		local prevNode = Wise._configuratorConditionNode
		if prevNode then
			local newCond = BuildConditionString(Wise._conditionPickerState.groups)
			if prevNode.condition ~= newCond then
				prevNode.condition = newCond
				configuratorState.isDirty = true
			end
		end
		Wise.pickingCondition = false
		Wise._conditionPickerState = nil
		Wise._configuratorConditionRow = nil
		Wise._configuratorConditionNode = nil
	end

	-- mode: "stack" → push onto existing cell stack; "node" → add new node; default → replace cell.
	Wise._configuratorPickTarget = { row = targetRow, col = targetCol, mode = mode or "replace" }

	-- Use the existing picker system with a custom callback
	Wise.pickingAction = true
	Wise.PickerCallback = function(actionType, value, extra)
		local target = Wise._configuratorPickTarget
		if target then
			local record = Wise:BuildActionRecord(actionType, value, extra and extra.category, extra)
			if target.mode == "node" then
				if not configuratorState.graph then
					configuratorState.graph = { nodes = {}, connections = {} }
				end
				local newNode = {
					id = GetNextNodeId(),
					action = record,
					condition = "",
				}
				tinsert(configuratorState.graph.nodes, newNode)
				configuratorState.isDirty = true
				RenderNodesCanvas()
			else
				if configuratorState.grid then
					if not configuratorState.grid[target.row] then
						configuratorState.grid[target.row] = {}
					end
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
					configuratorState.isDirty = true
				end
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
			local newCond = BuildConditionString(Wise._conditionPickerState.groups)
			if configuratorState.rowConditions[row] ~= newCond then
				configuratorState.rowConditions[row] = newCond
				configuratorState.isDirty = true
			end
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

	-- Picker is anchored to host's TOPLEFT and constrained to a fixed width so the
	-- list/headers only span what the content needs (name + description columns +
	-- scrollbar) instead of stretching across the whole options frame.
	local PICKER_WIDTH = 600

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
	cp.inheritedLabel:SetWidth(PICKER_WIDTH - 40)
	cp.inheritedLabel:SetJustifyH("LEFT")
	cp.inheritedLabel:SetMaxLines(3)

	Wise:UpdateConditionPickerExclusionDisplay(cp, row)

	-- Divider
	cp.divider = host:CreateTexture(nil, "ARTWORK")
	cp.divider:SetColorTexture(0.3, 0.3, 0.3, 0.8)
	cp.divider:SetHeight(1)
	cp.divider:SetPoint("TOPLEFT", host, "TOPLEFT", 8, -72)
	cp.divider:SetWidth(PICKER_WIDTH - 16)

	-- Builder scroll area (condition chips)
	cp.builderScroll = CreateFrame("ScrollFrame", nil, host, "UIPanelScrollFrameTemplate")
	cp.builderScroll:SetPoint("TOPLEFT", host, "TOPLEFT", 8, -76)
	cp.builderScroll:SetWidth(PICKER_WIDTH - 36)
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
	cp.listDivider:SetWidth(PICKER_WIDTH - 16)

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
	cp.listScroll:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 8, 8)
	cp.listScroll:SetWidth(PICKER_WIDTH - 36)

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
	if sc.holdCheck then
		sc.holdCheck:SetChecked(slot and slot.pressAndHold == true or false)
	end
	-- Reset-on-combat only applies when the grid is multi-column (sequence on export).
	local resetShown = (configuratorState.numCols or 1) > 1
	if resetShown then
		sc.resetCheck:Show()
		sc.resetCheck.Text:Show()
	else
		sc.resetCheck:Hide()
		sc.resetCheck.Text:Hide()
	end
	-- Hold-to-repeat follows whichever toggle is the last visible one so the row
	-- has no gap when "Reset sequence on combat end" is hidden.
	if sc.holdCheck then
		sc.holdCheck:ClearAllPoints()
		if resetShown then
			sc.holdCheck:SetPoint("LEFT", sc.resetCheck.Text, "RIGHT", 12, 0)
		else
			sc.holdCheck:SetPoint("LEFT", sc.suppressCheck.Text, "RIGHT", 12, 0)
		end
	end
end

-- Show/hide the correct tab content and toolbar items, then render.
local function ApplyTabVisibility()
	local sc = Wise.SlotConfigurator
	if not sc then
		return
	end

	-- The Grid view has been retired from the UI. The grid code remains for
	-- import/migration, but the configurator is now always the Nodes view.
	configuratorState.activeTab = "nodes"
	local isNodes = true

	-- Hide the obsolete chrome: Grid/Nodes tab buttons, the modifier palette
	-- (a grid concept), and the "< Back" button (the configurator is always-on
	-- and embedded in the Right panel, so there is nothing to go back to).
	if sc.tabGrid then
		sc.tabGrid:Hide()
	end
	if sc.tabNodes then
		sc.tabNodes:Hide()
	end
	if sc.cancelBtn then
		sc.cancelBtn:Hide()
	end
	if sc.modPalette then
		sc.modPalette:Hide()
	end

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

	SyncSlotToggleControls()
	RenderActiveTab()
end

function Wise:CreateSlotConfiguratorUI(host)
	local sc = Wise.SlotConfigurator
	if sc and sc.host == host then
		-- Reuse existing UI. The Grid/Nodes tabs and "< Back" button are retired
		-- (ApplyTabVisibility keeps them hidden); only refresh the live chrome.
		sc.titleLabel:Show()
		sc.divider:Show()
		if sc.suppressCheck then
			sc.suppressCheck:Show()
		end
		-- Hide toolbar items when condition picker is open (they'd overlap)
		if Wise.pickingCondition then
			sc.applyBtn:Hide()
			sc.infoLabel:Hide()
			if sc.macroViewBtn then
				sc.macroViewBtn:Hide()
			end
			if sc.nodesAddBtn then
				sc.nodesAddBtn:Hide()
			end
		else
			sc.applyBtn:Show()
			sc.infoLabel:Show()
			if sc.macroViewBtn then
				sc.macroViewBtn:Show()
			end
			if sc.nodesAddBtn then
				sc.nodesAddBtn:Show()
			end
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
		if configuratorState.isDirty then
			if not StaticPopupDialogs["WISE_CONFIRM_EXIT"] then
				StaticPopupDialogs["WISE_CONFIRM_EXIT"] = {
					text = "Save changes to slot configuration before exiting?",
					button1 = "Save",
					button2 = "Discard",
					button3 = "Cancel",
					OnAccept = function()
						Wise:CloseSlotConfigurator(false)
					end,
					OnCancel = function(self, data, reason)
						if reason == "clicked" then
							Wise:CloseSlotConfigurator(true)
						end
					end,
					OnAlt = function()
						-- Cancel: do nothing, keep editor open
					end,
					timeout = 0,
					whileDead = true,
					hideOnEscape = true,
				}
			end
			StaticPopup_Show("WISE_CONFIRM_EXIT")
		else
			Wise:CloseSlotConfigurator(true)
		end
	end)

	-- Title (anchored to the host's top-left; the "< Back" button is retired)
	sc.titleLabel = host:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	sc.titleLabel:SetPoint("TOPLEFT", host, "TOPLEFT", 10, -14)
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

	-- Macro viewer: mouse over to see exactly what the current (unsaved) graph
	-- compiles to, so you can verify which lines/conditionals will actually fire.
	-- A dedicated popup (not GameTooltip) is used so long macro lines are shown
	-- in full without truncation.
	sc.macroViewBtn = CreateFrame("Button", nil, host, "GameMenuButtonTemplate")
	sc.macroViewBtn:SetSize(110, 22)
	sc.macroViewBtn:SetPoint("RIGHT", sc.applyBtn, "LEFT", -6, 0)
	sc.macroViewBtn:SetText("View Macro")
	-- Click pins the popup open (stays until clicked again); mouseover shows it
	-- transiently and it hides on mouse-out unless it has been pinned.
	sc.macroViewBtn:SetScript("OnClick", function(self)
		Wise:ToggleMacroPreviewPopup(self)
	end)
	sc.macroViewBtn:SetScript("OnEnter", function(self)
		Wise:ShowMacroPreviewPopup(self)
	end)
	sc.macroViewBtn:SetScript("OnLeave", function()
		Wise:HideMacroPreviewPopup()
	end)

	-- "+ Add Node" button — top toolbar, centered in the configurator header in line
	-- with View Macro / Apply Changes (moved up from the bottom of the canvas).
	sc.nodesAddBtn = CreateFrame("Button", nil, host, "GameMenuButtonTemplate")
	sc.nodesAddBtn:SetSize(140, 22)
	sc.nodesAddBtn:SetPoint("TOP", host, "TOP", 0, -8)
	sc.nodesAddBtn:SetText("+ Add Node")
	sc.nodesAddBtn:SetNormalFontObject("GameFontHighlightSmall")
	sc.nodesAddBtn:SetScript("OnClick", function()
		Wise:OpenConfiguratorPicker(nil, nil, "node")
	end)
	Wise:AddTooltip(sc.nodesAddBtn, "Add another action node to the flow.")

	-- Info label (right of modifiers, before apply)
	sc.infoLabel = host:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	sc.infoLabel:SetPoint("RIGHT", sc.macroViewBtn, "LEFT", -10, 0)
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
		RebuildGridFromGraph()
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
	sc.suppressCheck:SetPoint("TOPLEFT", sc.divider, "BOTTOMLEFT", 0, -4)
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

	-- Hold to repeat: same per-slot toggle row. Repeat-fires the slot while the
	-- keybind is held. Stored as slot.pressAndHold (nil = disabled default).
	sc.holdCheck = CreateFrame("CheckButton", nil, host, "InterfaceOptionsCheckButtonTemplate")
	sc.holdCheck:SetPoint("LEFT", sc.resetCheck.Text, "RIGHT", 12, 0)
	sc.holdCheck.Text:SetText("Hold to repeat")
	sc.holdCheck.Text:SetFontObject("GameFontHighlightSmall")
	sc.holdCheck:SetScript("OnClick", function(self)
		local slot = GetCurrentSlotActions()
		if slot then
			slot.pressAndHold = self:GetChecked() and true or nil
			C_Timer.After(0, function()
				if not InCombatLockdown() and Wise.configuringSlotGroup then
					Wise:UpdateGroupDisplay(Wise.configuringSlotGroup)
				end
			end)
		end
	end)
	Wise:AddTooltip(
		sc.holdCheck,
		"When enabled, holding the keybind repeat-fires the action. Disable for one-shot actions like mounts or interface toggles."
	)

	SyncSlotToggleControls()

	-- Grid canvas scroll. Anchored just below the divider — the Grid/Nodes tab
	-- bar is retired, so the canvas reclaims that space.
	sc.canvasScroll = CreateFrame("ScrollFrame", nil, host, "UIPanelScrollFrameTemplate")
	sc.canvasScroll:SetPoint("TOPLEFT", sc.suppressCheck, "BOTTOMLEFT", 0, -6)
	sc.canvasScroll:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -28, 8)

	sc.canvas = CreateFrame("Frame", nil, sc.canvasScroll)
	sc.canvas:SetSize(800, 400)
	sc.canvasScroll:SetScrollChild(sc.canvas)

	-- Nodes canvas scroll (same geometry, hidden by default). The Nodes view can
	-- grow WIDE when "All" is selected (one column per availability branch), so it
	-- needs a horizontal scrollbar in addition to the vertical one provided by the
	-- template. We add a manual horizontal slider along the bottom and wire
	-- shift+mousewheel to it. The bottom anchor leaves room for that slider.
	sc.nodesCanvasScroll = CreateFrame("ScrollFrame", nil, host, "UIPanelScrollFrameTemplate")
	sc.nodesCanvasScroll:SetPoint("TOPLEFT", sc.suppressCheck, "BOTTOMLEFT", 0, -6)
	sc.nodesCanvasScroll:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -28, 8 + 18)

	sc.nodesCanvas = CreateFrame("Frame", nil, sc.nodesCanvasScroll)
	sc.nodesCanvas:SetSize(600, 400)
	sc.nodesCanvasScroll:SetScrollChild(sc.nodesCanvas)

	-- Horizontal scrollbar for the nodes canvas, built to match the vertical
	-- UIPanelScrollFrameTemplate bar: same classic scrollbar track/knob artwork and
	-- left/right arrow buttons mirroring its up/down buttons (rotated 90°). It sits
	-- in the gutter below the canvas, inset between where the arrow buttons go.
	sc.nodesHScroll = CreateFrame("Slider", nil, host)
	sc.nodesHScroll:SetOrientation("HORIZONTAL")
	sc.nodesHScroll:SetHeight(16)
	sc.nodesHScroll:SetPoint("TOPLEFT", sc.nodesCanvasScroll, "BOTTOMLEFT", 18, -2)
	sc.nodesHScroll:SetPoint("TOPRIGHT", sc.nodesCanvasScroll, "BOTTOMRIGHT", -18, -2)

	-- Track background (matches the vertical bar's recessed track).
	local hTrackTop = sc.nodesHScroll:CreateTexture(nil, "BACKGROUND")
	hTrackTop:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-ScrollBar")
	hTrackTop:SetTexCoord(0.8125, 0.875, 0.1875, 1) -- the thin track slice, rotated
	hTrackTop:SetRotation(math.rad(-90))
	hTrackTop:SetAllPoints(sc.nodesHScroll)
	hTrackTop:SetVertexColor(0.7, 0.7, 0.7, 0.9)

	-- Knob (thumb): reuse the classic scrollbar knob, rotated to lie horizontally.
	sc.nodesHScroll:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
	local hThumb = sc.nodesHScroll:GetThumbTexture()
	hThumb:SetSize(26, 16)
	hThumb:SetTexCoord(0.20703125, 0.78125, 0.5, 0.75)

	-- Left/right arrow buttons, mirroring the vertical bar's up/down scroll buttons.
	local function MakeArrow(point, anchorPoint, dx, isLeft)
		local btn = CreateFrame("Button", nil, host)
		btn:SetSize(18, 16)
		btn:SetPoint(point, sc.nodesHScroll, anchorPoint, dx, 0)
		-- The scroll arrow art is vertical (up/down); rotate to point left/right.
		local up = "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up"
		local down = "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Down"
		local dis = "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Disabled"
		local rot = isLeft and math.rad(-90) or math.rad(90)
		btn:SetNormalTexture(up)
		btn:SetPushedTexture(down)
		btn:SetDisabledTexture(dis)
		btn:GetNormalTexture():SetRotation(rot)
		btn:GetPushedTexture():SetRotation(rot)
		btn:GetDisabledTexture():SetRotation(rot)
		btn:SetHighlightTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Highlight", "ADD")
		btn:GetHighlightTexture():SetRotation(rot)
		return btn
	end
	sc.nodesHScrollLeft = MakeArrow("RIGHT", "LEFT", -1, true)
	sc.nodesHScrollRight = MakeArrow("LEFT", "RIGHT", 1, false)

	sc.nodesHScroll:SetMinMaxValues(0, 0)
	sc.nodesHScroll:SetValue(0)
	sc.nodesHScroll:SetValueStep(1)
	sc.nodesHScroll:SetObeyStepOnDrag(true)
	sc.nodesHScroll:SetScript("OnValueChanged", function(self, value)
		sc.nodesCanvasScroll:SetHorizontalScroll(value)
		local minV, maxV = self:GetMinMaxValues()
		sc.nodesHScrollLeft:SetEnabled(value > minV)
		sc.nodesHScrollRight:SetEnabled(value < maxV)
	end)
	sc.nodesHScrollLeft:SetScript("OnClick", function()
		sc.nodesHScroll:SetValue(sc.nodesHScroll:GetValue() - 60)
	end)
	sc.nodesHScrollRight:SetScript("OnClick", function()
		sc.nodesHScroll:SetValue(sc.nodesHScroll:GetValue() + 60)
	end)

	-- Shift+wheel scrolls horizontally; plain wheel keeps the template's vertical
	-- behaviour. We override the scroll frame's wheel handler to branch on shift.
	sc.nodesCanvasScroll:EnableMouseWheel(true)
	sc.nodesCanvasScroll:SetScript("OnMouseWheel", function(self, delta)
		if IsShiftKeyDown() then
			local minV, maxV = sc.nodesHScroll:GetMinMaxValues()
			local cur = sc.nodesHScroll:GetValue()
			local newV = math.max(minV, math.min(maxV, cur - delta * 40))
			sc.nodesHScroll:SetValue(newV)
		else
			local cur = self:GetVerticalScroll()
			local maxV = self:GetVerticalScrollRange()
			local newV = math.max(0, math.min(maxV, cur - delta * 40))
			self:SetVerticalScroll(newV)
		end
	end)

	ApplyTabVisibility()
end

-- Show or hide a warning banner across the top of the configurator when the
-- current slot's grid/sequence data failed to convert into node form. The
-- banner offers a one-click retry that re-imports straight from the slot data.
function Wise:RenderConfiguratorMigrationWarning(host)
	if not host then
		return
	end

	-- Lazily build the banner on first use.
	if not host.migrationWarn then
		local warn = CreateFrame("Frame", nil, host, "BackdropTemplate")
		warn:SetPoint("TOPLEFT", host, "TOPLEFT", 8, -64)
		warn:SetPoint("TOPRIGHT", host, "TOPRIGHT", -8, -64)
		warn:SetHeight(46)
		warn:SetFrameLevel(host:GetFrameLevel() + 8)
		warn:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true,
			tileSize = 16,
			edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		warn:SetBackdropColor(0.35, 0.1, 0.1, 0.95)
		warn:SetBackdropBorderColor(0.9, 0.3, 0.3, 1)

		warn.icon = warn:CreateTexture(nil, "ARTWORK")
		warn.icon:SetSize(20, 20)
		warn.icon:SetPoint("LEFT", 8, 0)
		warn.icon:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")

		warn.label = warn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		warn.label:SetPoint("LEFT", warn.icon, "RIGHT", 8, 0)
		warn.label:SetPoint("RIGHT", warn, "RIGHT", -90, 0)
		warn.label:SetJustifyH("LEFT")
		warn.label:SetText(
			"This slot's actions couldn't be converted to nodes. The existing data is preserved — try reconverting, or review the actions manually."
		)

		warn.retryBtn = CreateFrame("Button", nil, warn, "GameMenuButtonTemplate")
		warn.retryBtn:SetSize(78, 22)
		warn.retryBtn:SetPoint("RIGHT", warn, "RIGHT", -6, 0)
		warn.retryBtn:SetText("Reconvert")
		warn.retryBtn:SetScript("OnClick", function()
			-- Re-import from the slot data, then re-render.
			if Wise.configuringSlotGroup and Wise.configuringSlotIdx then
				Wise:OpenSlotConfigurator(Wise.configuringSlotGroup, Wise.configuringSlotIdx)
			end
		end)

		host.migrationWarn = warn
	end

	local status = Wise:GetConfiguratorMigrationStatus()
	if status == "failed" then
		host.migrationWarn:Show()
	else
		host.migrationWarn:Hide()
	end
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
	configuratorState.activeTab = "nodes"

	-- Set flags
	Wise.configuringSlot = true
	Wise.configuringSlotGroup = groupName
	Wise.configuringSlotIdx = slotIdx

	-- Trigger overlay
	Wise:RefreshPropertiesPanel()
end

-- Decide whether a slot selection should auto-enter the embedded node
-- configurator in the Right panel, and (re)import its data when the selection
-- changes. Called from RefreshPropertiesPanel before the configurator block.
--
-- The configurator is the always-on editor for ordinary slots. It is suppressed
-- for: group-level selection, action/state selection, locked groups, special
-- tool templates (Smart Item / Bar Copy), the Addons wiser slash-command flow,
-- and invalid groups (handled by their own property views).
function Wise:MaybeEnterEmbeddedConfigurator()
	-- A picker overlay is mid-flow on top of the configurator — keep state as-is.
	if Wise.pickingAction or Wise.pickingCondition then
		return
	end
	-- These selection modes hijack the panels themselves; never embed.
	if Wise.pickingRestrictions or Wise.pickingTalents or Wise.pickingSpecs or Wise.pickingIcon then
		return
	end

	local groupName = Wise.selectedGroup
	local group = groupName and WiseDB.groups and WiseDB.groups[groupName]
	local slotIdx = Wise.selectedSlot

	local eligible = group ~= nil
		and slotIdx ~= nil
		and not Wise.selectedState
		and not group.isLocked
		and groupName ~= Wise.SMART_ITEM_TEMPLATE
		and groupName ~= Wise.BAR_COPY_TEMPLATE
		and group ~= Wise.SMART_ITEM_TEMPLATE
		and not (groupName == "Addons") -- Addons uses the slash-command action editor

	if eligible then
		-- Validate the group; corrupt groups get the repair view, not the editor.
		if Wise.ValidateGroup then
			local isValid = Wise:ValidateGroup(groupName)
			if not isValid then
				eligible = false
			end
		end
	end

	if eligible then
		Wise:MigrateGroupToActions(group)
		if not (group.actions and group.actions[slotIdx]) then
			eligible = false
		end
	end

	if not eligible then
		-- Selection no longer points at an editable slot: leave configurator mode
		-- (without re-exporting; the data is already committed live).
		if Wise.configuringSlot then
			Wise.configuringSlot = false
			Wise.configuringSlotGroup = nil
			Wise.configuringSlotIdx = nil
		end
		return
	end

	-- Enter / switch the embedded configurator when the target slot changes.
	if not Wise.configuringSlot or Wise.configuringSlotGroup ~= groupName or Wise.configuringSlotIdx ~= slotIdx then
		ImportSlotData(groupName, slotIdx)
		configuratorState.activeTab = "nodes"
		Wise.configuringSlot = true
		Wise.configuringSlotGroup = groupName
		Wise.configuringSlotIdx = slotIdx
	end
end

-- Returns a migration status for the slot currently loaded in the configurator:
--   ok       -> graph has nodes (or slot is genuinely empty)
--   failed   -> the slot has action data but conversion produced no nodes
-- Used to drive the user-facing warning banner.
function Wise:GetConfiguratorMigrationStatus()
	local state = configuratorState
	local graphNodeCount = (state.graph and state.graph.nodes and #state.graph.nodes) or 0
	if graphNodeCount > 0 then
		return "ok"
	end

	-- No nodes — check whether the underlying slot actually has actions that
	-- should have produced nodes. If so, the grid→node conversion failed.
	local group = state.groupName and WiseDB and WiseDB.groups and WiseDB.groups[state.groupName]
	local slot = group and group.actions and group.actions[state.slotIdx]
	if type(slot) ~= "table" then
		return "ok"
	end
	local actionCount = 0
	for i = 1, #slot do
		if type(slot[i]) == "table" then
			actionCount = actionCount + 1
		end
	end
	if actionCount > 0 then
		return "failed"
	end
	return "ok"
end

-- ═══════════════════════════════════════════════════════════════
-- Close helper (for use by other modules)
-- ═══════════════════════════════════════════════════════════════
function Wise:CloseSlotConfigurator(discard)
	if not Wise.configuringSlot then
		return
	end
	if not discard then
		ExportToSlotData()
	end
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
