-- Filters.lua
--
-- All action visibility/filtering logic for Wise, extracted from Wise.lua and
-- Actions.lua to keep those files focused. Two related concerns live here:
--
--   1. Runtime visibility — what the engine actually fires in-game:
--        MatchesRestrictionTag, IsActionAllowed, ShouldLoadAction, GetFilteredActions
--   2. Editor/UI filtering — the All/Class/Spec/Build/Character scope waterfall
--      shown in the configurator:
--        SCOPE_RANK / SCOPE_FILTER_RANK, GetActionScopeRank, ShouldShowAction
--
-- Plus shared helpers used by both: ResolveSpellCategory (spellbook source of a
-- spell) and GetActionVisibilitySummary (the "+(Spec) -(Role)" label), and the
-- filter-vocabulary constants (Categories / CategoryLabels / RoleLabels).
--
-- Loaded immediately after Wise.lua so every Wise:Filter* method exists before
-- any module or event handler calls it.

local addonName, addon = ...
Wise = addon

local ipairs = ipairs
local pairs = pairs
local type = type
local tonumber = tonumber
local table = table
local string = string

-- WoW APIs / globals used by the filter logic
local C_Spell = C_Spell
local C_SpellBook = C_SpellBook
local C_Traits = C_Traits
local C_ClassTalents = C_ClassTalents
local Enum = Enum
local strsplit = strsplit
local UnitClass = UnitClass
local UnitName = UnitName
local GetRealmName = GetRealmName
local GetSpecialization = GetSpecialization
local GetSpecializationInfo = GetSpecializationInfo
local GetSpecializationInfoByID = GetSpecializationInfoByID
local GetNumSpecializationsForClassID = GetNumSpecializationsForClassID
local GetSpecializationInfoForClassID = GetSpecializationInfoForClassID
local IsPlayerSpell = IsPlayerSpell
local IsSpellKnownOrOverridesKnown = IsSpellKnownOrOverridesKnown

-- ============================================================================
-- Filter vocabulary constants
-- ============================================================================

-- The currently selected editor filter (session state, not persisted).
Wise.ActionFilter = "global"

-- Category constants
Wise.Categories = { "global", "class", "role", "spec", "build", "character" }
Wise.CategoryLabels = {
	global = "All",
	class = "Class",
	role = "Role",
	spec = "Spec",
	build = "Build",
	talent = "Build", -- legacy alias: pre-waterfall configs called this "Talents"
	character = "Character",
}
Wise.RoleLabels = {
	TANK = "Tank",
	HEALER = "Healer",
	DAMAGER = "DPS",
}

-- The scope ladder. Each rung is strictly NARROWER than the one before it:
-- global (anyone) > class > spec > build (talent loadout) > char (one toon).
-- role: is orthogonal (it crosses classes/specs) and is NOT a rung — it is
-- handled by its own filter and ignored when computing scope rank.
-- talent: (per-talent-spell restriction) is loadout-dependent, so it ranks at
-- the build tier alongside build: (per-loadout) restrictions.
Wise.SCOPE_RANK = { global = 1, class = 2, spec = 3, talent = 4, build = 4, char = 5 }
-- Maps the UI filter id to the broadest rung it should reveal. The waterfall is
-- cumulative: selecting "spec" shows everything ranked spec-or-broader.
Wise.SCOPE_FILTER_RANK = { global = 1, class = 2, spec = 3, build = 4, character = 5 }

-- ============================================================================
-- Runtime visibility — what the engine fires in-game
-- ============================================================================

-- Helper: check if the current character matches a specific restriction tag
function Wise:MatchesRestrictionTag(tag)
	if not tag then
		return false
	end

	if tag == "global" then
		return true
	elseif tag == "role:TANK" then
		return self.characterInfo.role == "TANK"
	elseif tag == "role:HEALER" then
		return self.characterInfo.role == "HEALER"
	elseif tag == "role:DAMAGER" then
		return self.characterInfo.role == "DAMAGER"
	elseif tag:match("^class:") then
		local reqClass = tag:sub(7)
		return self.characterInfo.class == reqClass
	elseif tag:match("^spec:") then
		local reqSpec = tonumber(tag:sub(6))
		return self.characterInfo.specID == reqSpec
	elseif tag:match("^talent:") then
		local reqTalent = tonumber(tag:sub(8))
		return IsPlayerSpell(reqTalent) or IsSpellKnownOrOverridesKnown(reqTalent)
	elseif tag:match("^build:") then
		-- A build: tag binds an action to one specific talent loadout (config ID).
		-- Visible only while that exact loadout is the active one.
		local reqConfig = tonumber(tag:sub(7))
		if not reqConfig then
			return false
		end
		local active = self.characterInfo and self.characterInfo.talentConfigID
		if active == nil and C_ClassTalents and C_ClassTalents.GetActiveConfigID then
			active = C_ClassTalents.GetActiveConfigID()
		end
		return active ~= nil and active == reqConfig
	elseif tag:match("^char:") then
		local reqChar = tag:sub(6)
		local charKey = UnitName("player") .. "-" .. GetRealmName()
		return charKey == reqChar
	end
	return false
end

function Wise:IsActionAllowed(action)
	local enables = action.visibilityEnable or {}
	local disables = action.visibilityDisable or {}
	local isAllowed = false

	-- If there are ANY enables, default to false. Must match one to become true.
	-- If NO enables, default to true.
	if #enables > 0 then
		-- Group enables by prefix
		local catEnables = {}
		for _, tag in ipairs(enables) do
			local prefix = tag:match("^([^:]+):") or tag
			catEnables[prefix] = catEnables[prefix] or {}
			table.insert(catEnables[prefix], tag)
		end

		isAllowed = true
		for prefix, tags in pairs(catEnables) do
			local prefixMatched = false

			if prefix == "global" then
				prefixMatched = true
			else
				for _, tag in ipairs(tags) do
					if self:MatchesRestrictionTag(tag) then
						prefixMatched = true
						break
					end
				end
			end

			if not prefixMatched then
				isAllowed = false
				break
			end
		end
	else
		isAllowed = true
	end

	-- If allowed so far, check disables. Any match makes it false.
	if isAllowed and #disables > 0 then
		for _, tag in ipairs(disables) do
			if self:MatchesRestrictionTag(tag) then
				isAllowed = false
				break
			end
		end
	end

	return isAllowed
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
			table.insert(filtered, { index = i, action = action })
		end
	end
	return filtered
end

-- ============================================================================
-- Editor/UI filtering — the scope waterfall shown in the configurator
-- ============================================================================

-- The narrowest scope an action is restricted to ("home tier"), derived purely
-- from its visibilityEnable tags. An action with no scoping tags is global (1).
-- role: tags do not narrow scope, so they never raise the rank.
function Wise:GetActionScopeRank(action)
	local rank = 1 -- global
	local enables = (type(action) == "table" and action.visibilityEnable) or nil
	if not enables then
		return rank
	end
	for _, tag in ipairs(enables) do
		local prefix = tag:match("^([^:]+)") or tag
		local r = Wise.SCOPE_RANK[prefix]
		if r and r > rank then
			rank = r
		end
	end
	return rank
end

function Wise:ShouldShowAction(action)
	local filter = Wise.ActionFilter

	-- Legacy alias: the scope rung formerly called "talent" is now "build".
	if filter == "talent" then
		filter = "build"
	end

	-- "All" filter -> Show everything (including actions disabled for this toon —
	-- the user is asking to see the full configured set).
	if filter == "global" then
		return true
	end

	-- For toon-scoped filters (class/role/spec/build/character), an explicit
	-- visibilityDisable hit on the current toon hides the action. Mirrors the
	-- runtime IsActionAllowed semantics so the configurator UI matches what
	-- the engine will actually fire.
	local disables = action.visibilityDisable
	if disables and #disables > 0 then
		for _, tag in ipairs(disables) do
			if Wise:MatchesRestrictionTag(tag) then
				return false
			end
		end
	end

	-- Filters now check applicability to the CURRENT toon, not the saved category tag.
	-- Non-spell actions (items, toys, mounts, macros, etc.) are always shown for class/spec/talent
	-- since they aren't inherently restricted to a spell-book source.
	local aType = action.type

	-- User-set visibilityEnable tags are an explicit allowlist and take
	-- precedence over spellbook autoclassification. Each helper returns
	-- (matched, decision): matched=true means a tag in the enable-list spoke
	-- to this filter and the decision is final; matched=false means no
	-- relevant tag was found and the caller should fall through.
	local enables = action.visibilityEnable or {}
	local function isActionGlobal()
		if action.type ~= "spell" then
			return true
		end
		if action.category == "global" then
			return true
		end
		return false
	end

	local function specBelongsToPlayerClass(savedSpecID)
		if not savedSpecID then
			return false
		end
		local _, _, classID = UnitClass("player")
		local numSpecs = GetNumSpecializationsForClassID(classID)
		for si = 1, numSpecs do
			local sid = GetSpecializationInfoForClassID(classID, si)
			if sid == savedSpecID then
				return true
			end
		end
		return false
	end

	-- Within a single visibility-enable list, multiple tags of the same kind are
	-- ORed together (matches the runtime IsActionAllowed semantics). A filter
	-- decision is positive if ANY relevant tag matches the current toon, and
	-- negative only if every relevant tag rules the toon out.
	local function classTagDecision()
		local matched, decision = false, false
		for _, tag in ipairs(enables) do
			if tag:match("^class:") then
				matched = true
				if tag == "class:" .. (Wise.characterInfo.class or "") then
					decision = true
				end
			elseif tag:match("^spec:") then
				matched = true
				if specBelongsToPlayerClass(tonumber(tag:sub(6))) then
					decision = true
				end
			elseif tag:match("^role:") then
				matched = true
				if isActionGlobal() or action.addedByClass == Wise.characterInfo.class then
					decision = true
				end
			end
		end
		return matched, decision
	end

	local function roleTagDecision()
		local matched, decision = false, false
		for _, tag in ipairs(enables) do
			if tag:match("^role:") then
				matched = true
				if tag == "role:" .. (Wise.characterInfo.role or "") then
					decision = true
				end
			elseif tag:match("^spec:") then
				local savedSpecID = tonumber(tag:sub(6))
				if savedSpecID then
					matched = true
					if specBelongsToPlayerClass(savedSpecID) then
						local _, _, _, _, specRole = GetSpecializationInfoByID(savedSpecID)
						if specRole == (Wise.characterInfo.role or "") then
							decision = true
						end
					end
				end
			end
		end
		return matched, decision
	end

	local function specTagDecision()
		local matched, decision = false, false
		for _, tag in ipairs(enables) do
			if tag:match("^spec:") then
				matched = true
				if tonumber(tag:sub(6)) == (Wise.characterInfo.specID or 0) then
					decision = true
				end
			elseif tag:match("^role:") then
				matched = true
				if tag == "role:" .. (Wise.characterInfo.role or "") then
					decision = true
				end
			end
		end
		return matched, decision
	end

	if filter == "class" then
		-- Explicit allowlist tags win for every action type.
		local matched, decision = classTagDecision()
		if matched then
			return decision
		end
		-- No tags: for spells, trust the spellbook; everything else passes.
		if aType == "spell" then
			local resolved = Wise:ResolveSpellCategory(action.value)
			if resolved == "class" or resolved == "spec" then
				return true
			end
			return Wise:IsActionKnown(aType, action.value)
		end
		return true
	elseif filter == "role" then
		local matched, decision = roleTagDecision()
		if matched then
			-- Tags win, but still require the action to belong to the player's
			-- class when that metadata is set (mirrors pre-refactor behavior).
			if not isActionGlobal() and action.addedByClass and action.addedByClass ~= Wise.characterInfo.class then
				return false
			end
			return decision
		end
		if aType == "spell" then
			local resolved, resolvedSpecID = Wise:ResolveSpellCategory(action.value)
			if resolved == "class" then
				return true
			end
			if resolved == "spec" and resolvedSpecID then
				local _, _, _, _, specRole = GetSpecializationInfoByID(resolvedSpecID)
				return specRole == (Wise.characterInfo.role or "")
			end
			if not isActionGlobal() and action.addedByClass and action.addedByClass ~= Wise.characterInfo.class then
				return false
			end
			return Wise:IsActionKnown(aType, action.value)
		end
		return true
	elseif filter == "spec" then
		local matched, decision = specTagDecision()
		if matched then
			if not isActionGlobal() and action.addedByClass and action.addedByClass ~= Wise.characterInfo.class then
				return false
			end
			return decision
		end
		if aType == "spell" then
			local resolved, resolvedSpecID = Wise:ResolveSpellCategory(action.value)
			if resolved == "class" then
				return true
			end
			if resolved == "spec" then
				return resolvedSpecID == (Wise.characterInfo.specID or 0)
			end
			if not isActionGlobal() and action.addedByClass and action.addedByClass ~= Wise.characterInfo.class then
				return false
			end
			return Wise:IsActionKnown(aType, action.value)
		end
		return true
	elseif filter == "build" then
		-- Build = the active talent loadout rung. Cumulative: show everything
		-- ranked build-or-broader (global/class/spec/build) that applies to this
		-- toon. Build-tier tags are build: (pinned to a saved loadout's config ID)
		-- and talent: (pinned to a specific talent spell being active). Either, when
		-- present, is authoritative: the action shows only if it currently applies.
		local sawBuildTier = false
		for _, tag in ipairs(enables) do
			if tag:match("^build:") or tag:match("^talent:") then
				sawBuildTier = true
				if Wise:MatchesRestrictionTag(tag) then
					return true
				end
			end
		end
		if sawBuildTier then
			return false
		end
		-- No build-tier tag — fall back to spec-rung applicability (broader scopes
		-- are always active within the current build), then known-state for spells.
		local matched, decision = specTagDecision()
		if matched then
			if not isActionGlobal() and action.addedByClass and action.addedByClass ~= Wise.characterInfo.class then
				return false
			end
			return decision
		end
		return Wise:IsActionKnown(aType, action.value)
	elseif filter == "character" then
		-- Character is the NARROWEST rung. Unlike the broader rungs it is exclusive,
		-- not cumulative: it shows ONLY actions explicitly pinned to THIS character,
		-- so the button answers "what did I character-restrict here" instead of just
		-- echoing All. An action with no char: tag (and no legacy character category)
		-- is therefore hidden.
		local charKey = UnitName("player") .. "-" .. GetRealmName()
		-- Multiple char: tags OR together — visible if any one names this character.
		local charEnables = action.visibilityEnable or {}
		for _, tag in ipairs(charEnables) do
			if tag:match("^char:") then
				if tag == "char:" .. charKey then
					return true
				end
			end
		end
		-- Legacy fallback: actions saved under the old "character" category.
		if action.category == "character" then
			local checkChar = action.addedByCharacter or action.characterRestriction
			-- Pinned to a specific char -> only that char; pinned to "this char"
			-- with no key recorded -> treat as belonging to the current toon.
			if checkChar then
				return checkChar == charKey
			end
			return true
		end
		-- No character restriction of any kind -> not a char-scoped action.
		return false
	end

	return true
end

-- ============================================================================
-- Shared helpers
-- ============================================================================

-- Resolve the spellbook category for a given spell ID.
-- Returns category ("global", "class", "spec") and sourceSpecID (or nil).
-- Checks both direct spell ID match and override match (base spell in book -> override active).
function Wise:ResolveSpellCategory(spellID)
	if not spellID or not C_SpellBook or not C_SpellBook.GetNumSpellBookSkillLines then
		return "global", nil
	end
	if type(spellID) == "string" then
		local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
		if info then
			spellID = info.spellID
		else
			return "global", nil
		end
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

-- Build the short visibility/availability summary for an action — the same
-- "+(Spec, Class) -(Role)" text shown in the Slots and Actions list. Shared so
-- the Slot Configurator node cards can show the identical tag. Returns "" when
-- the action is unrestricted (no enables/disables and no legacy category).
function Wise:GetActionVisibilitySummary(action)
	if type(action) ~= "table" then
		return ""
	end
	local enables = action.visibilityEnable or {}
	local disables = action.visibilityDisable or {}

	local function formatTag(tag)
		if tag == "global" then
			return "All"
		end
		local prefix, val = strsplit(":", tag, 2)
		if not val then
			return tag
		end
		if prefix == "role" then
			return Wise.RoleLabels and Wise.RoleLabels[val] or val
		elseif prefix == "class" then
			return val
		elseif prefix == "spec" then
			local _, name = GetSpecializationInfoByID(tonumber(val))
			return name or val
		elseif prefix == "talent" then
			local spellInfo = C_Spell.GetSpellInfo(tonumber(val))
			return spellInfo and spellInfo.name or val
		elseif prefix == "build" then
			local configInfo = C_Traits and C_Traits.GetConfigInfo and C_Traits.GetConfigInfo(tonumber(val))
			return (configInfo and configInfo.name and configInfo.name ~= "" and configInfo.name) or "Build"
		elseif prefix == "char" then
			local name = strsplit("-", val)
			return name or val
		end
		return val
	end

	if #enables == 0 and #disables == 0 then
		local cat = action.category or "global"
		if cat == "class" then
			return action.addedByClass or "Class"
		elseif cat == "spec" then
			local sp = action.addedBySpec
			if sp then
				local _, sn = GetSpecializationInfoByID(sp)
				return sn or "Spec"
			end
		elseif cat == "character" then
			return "Char"
		end
		return ""
	end

	local parts = {}
	if #enables > 0 then
		local eStrs = {}
		for i = 1, math.min(2, #enables) do
			table.insert(eStrs, formatTag(enables[i]))
		end
		if #enables > 2 then
			table.insert(eStrs, "...")
		end
		table.insert(parts, "+(" .. table.concat(eStrs, ", ") .. ")")
	end
	if #disables > 0 then
		local dStrs = {}
		for i = 1, math.min(2, #disables) do
			table.insert(dStrs, formatTag(disables[i]))
		end
		if #disables > 2 then
			table.insert(dStrs, "...")
		end
		table.insert(parts, "-(" .. table.concat(dStrs, ", ") .. ")")
	end
	return table.concat(parts, " ")
end
