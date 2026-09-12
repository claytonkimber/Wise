-- modules/indicators/Index.lua
--
-- The spellID -> rules lookup the runtime pass consumes, plus the per-entry
-- state it compares against.
-- See modules/indicators/Model.lua for how this directory is laid out.
--
-- TWO INDEXES, deliberately: rulesBySpell is the fast path, but a rule authored
-- against an action whose spell cannot be resolved yet (an unloaded item, a
-- macro naming a spell by text) still has to match, so rulesByName carries it.
-- Both are rebuilt wholesale by RebuildIndicatorRules rather than patched.
--
-- lastMatchByEntry / lastCdStartByEntry are EDGE-DETECTION state: a sound must
-- fire on the rising edge only, not on every pass that still matches. Paint.lua
-- writes them; clearing one silently turns a one-shot sound into a repeating
-- one.
--
-- Loaded after Render.lua.

local addonName, Wise = ...

local IR = Wise.IndicatorRules
local RuleMetric = IR.RuleMetric
local ResolveEntry = IR.ResolveEntry

-- =========================================================================
-- Runtime: spellID -> rules map + per-button border/glow/count + sound on edge.
-- =========================================================================

-- spellID -> { rules, action, spellID, name }, built from every graph node carrying
-- indicatorRules this character is allowed to use. `name` lets us (a) match a button
-- whose resolved spellID is nil (a /cast Abundance custom_macro — the name doesn't
-- resolve by C_Spell so meta.baseSpellID is nil) and (b) read the buff by NAME, since
-- the aura a spell APPLIES often has a different id than the cast spell (Abundance
-- casts 207383 but the buff aura is 203864). Rebuilt on spec/login/config change.
local rulesBySpell = {}
-- lowercase spell name -> the same entry, for name-based button matching.
local rulesByName = {}
-- entry -> last matched rule (transition gate so sound fires once per entry).
local lastMatchByEntry = {}
-- entry -> cooldown START time we last saw. A change means the spell was recast (or
-- proc-reset), so a held "available" match should re-fire on the new cycle even if
-- our sampling never observed the on-cooldown trough between casts.
local lastCdStartByEntry = {}

-- Returns spellID, spellName for an action's spell (resolving name<->id either way).
local function ActionSpell(action)
	if not action or action.type ~= "spell" then
		return nil, nil
	end
	local n = tonumber(action.value)
	if n then
		local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(n)
		return n, info and info.name or action.name
	end
	local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(action.value)
	if info then
		return info.spellID, info.name
	end
	return nil, action.value
end

function Wise:RebuildIndicatorRules()
	wipe(rulesBySpell)
	wipe(rulesByName)
	if not WiseDB or not WiseDB.groups then
		return
	end
	for _, group in pairs(WiseDB.groups) do
		if type(group.actions) == "table" then
			for _, states in pairs(group.actions) do
				if type(states) == "table" then
					local graph = states.graph
					if graph and type(graph.nodes) == "table" then
						for _, node in ipairs(graph.nodes) do
							local a = node.action
							if
								a
								and type(a.indicatorRules) == "table"
								and #a.indicatorRules > 0
								and Wise:IsActionAllowed(a)
							then
								local sid, sname = ActionSpell(a)
								if sid then
									-- Carry the node's macro condition (e.g. [combat]) so the indicator
									-- only fires while that condition is met — matching the slot's own
									-- gating, so the availability sound doesn't blare out of combat.
									local cond = node.condition
									if type(cond) ~= "string" or cond == "" then
										cond = nil
									end
									local entry = {
										rules = a.indicatorRules,
										action = a,
										spellID = sid,
										name = sname,
										condition = cond,
									}
									rulesBySpell[sid] = entry
									if sname then
										rulesByName[sname:lower()] = entry
									end
								end
							end
						end
					end
				end
			end
		end
	end

	-- Seed the transition gate to each entry's CURRENT match WITHOUT firing, so a
	-- rebuild (login / zone / spec / config edit) never blares the sound just because
	-- the spell happens to already be available/matched. Sound then fires only on a
	-- genuine match change during play. wipe the gate tables first — old entry tables
	-- are gone after the rebuild above.
	wipe(lastMatchByEntry)
	wipe(lastCdStartByEntry)
	for _, entry in pairs(rulesBySpell) do
		local matched, st = ResolveEntry(entry)
		lastMatchByEntry[entry] = matched
		lastCdStartByEntry[entry] = (st and st.cdStart) or 0
	end
end

-- Resolve the ruled entry that applies to a button. Match by the button's tracked
-- spellID first, then by spell NAME — a /cast Abundance custom_macro button has no
-- resolved spellID (the name doesn't resolve via C_Spell), so fall back to scanning
-- its live macro text / action value for a ruled spell name.
local function StateEntry(state)
	if type(state) ~= "table" then
		return nil
	end
	if state.type == "spell" and state.value then
		local sid = tonumber(state.value)
		if sid and rulesBySpell[sid] then
			return rulesBySpell[sid]
		end
		if type(state.value) == "string" then
			local e = rulesByName[state.value:lower()]
			if e then
				return e
			end
		end
	end
	if next(rulesByName) and type(state.macroText) == "string" then
		local lower = state.macroText:lower()
		for nameLower, entry in pairs(rulesByName) do
			if lower:find(nameLower, 1, true) then
				return entry
			end
		end
	end
	return nil
end

local function ButtonEntry(meta)
	if not meta then
		return nil
	end
	local sid = meta.baseSpellID or meta.spellID
	if sid and rulesBySpell[sid] then
		return rulesBySpell[sid]
	end
	-- Name-based fallback for custom_macro / unresolved-spell buttons.
	if next(rulesByName) then
		if meta.actionType == "spell" and type(meta.actionValue) == "string" then
			local e = rulesByName[meta.actionValue:lower()]
			if e then
				return e
			end
		end
		local mt = meta.actionData and meta.actionData.macroText
		if mt then
			local lower = mt:lower()
			for nameLower, entry in pairs(rulesByName) do
				if lower:find(nameLower, 1, true) then
					return entry
				end
			end
		end
	end
	-- A multi-state slot displays only ONE state at a time (meta.actionData), but
	-- the ruled action may live on a sibling state. E.g. AtMouse compiles to a
	-- "[combat] Survival Instincts" step plus an "Abundance" step: entering combat
	-- flips the shown state to the first, and matching only the active state would
	-- detach the Abundance indicator exactly when its stacks matter. Scan every
	-- state so the indicator stays bound to the slot that can cast the spell.
	if type(meta.states) == "table" then
		for _, state in ipairs(meta.states) do
			local e = StateEntry(state)
			if e then
				return e
			end
		end
	end
	return nil
end

-- Published for Paint.lua: the indexes and the edge-detection state.
IR.rulesBySpell = rulesBySpell
IR.rulesByName = rulesByName
IR.lastMatchByEntry = lastMatchByEntry
IR.lastCdStartByEntry = lastCdStartByEntry
IR.StateEntry = StateEntry
IR.ButtonEntry = ButtonEntry
