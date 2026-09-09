-- core/conditionals/Vocabulary.lua
--
-- The custom-conditional vocabulary and the mutable state that hangs off it,
-- extracted from core/GUI.lua. Three concerns, all keyed by token name:
--
--   1. CUSTOM_VIS_CONDITIONALS — which tokens Wise evaluates itself rather than
--      handing to WoW's secure state driver. This is the authoritative list;
--      see the warning on it about the two sibling tables that must agree.
--   2. COMBAT_SAMPLED — which of those tokens freeze at combat entry, plus the
--      sample store and the two Wise.* hooks the event handler calls.
--   3. AvailabilityProviders — the [available] conditional's registry.
--
-- No evaluation lives here: Predicates.lua answers "what is the game state?",
-- EvalToken.lua dispatches one token, ConditionString.lua parses whole
-- condition strings. This file just says which words exist and what is
-- currently remembered about them.
--
-- Loaded after ZoneAbility.lua and before Predicates.lua.

local addonName, Wise = ...

local pairs = pairs
local pcall = pcall
local wipe = wipe
local InCombatLockdown = InCombatLockdown

local E = Wise.CondEngine or {}
Wise.CondEngine = E

-- All custom conditionals that are NOT understood by WoW's secure state driver.
-- Used by BuildVisibilityDriver (SanitizeCustom) and UpdateGroupDisplay (CheckCustomVisibility).
--
-- A token MUST be listed here to have any effect. The options window keeps two
-- other tables — VALID_CONDITIONALS (accept/reject in the editor) and
-- extendedConditionals (the displayed reference list) — and a token present
-- there but missing here passes validation, falls through to
-- SecureCmdOptionParse, and silently evaluates false forever. All three
-- tables have to agree.
local CUSTOM_VIS_CONDITIONALS = {
	["guildbank"] = true,
	["bank"] = true,
	["mailbox"] = true,
	["auctionhouse"] = true,
	["zoneability"] = true,
	["undermouse"] = true,
	["available"] = true,

	-- Location / character identity. These only change out of combat, so the
	-- 0.5s ticker in UpdateGroupDisplay re-drives visibility for them normally.
	["zone"] = true,
	["instance"] = true,
	["in"] = true,
	["me"] = true,
	["level"] = true,
	["race"] = true,
	["game"] = true,
	["horde"] = true,
	["alliance"] = true,
	["mercenary"] = true,
	["merc"] = true, -- short alias for [mercenary]
	["prof"] = true,

	-- Extended content-state conditionals. All are out-of-combat-stable (or close
	-- enough that the 0.5s ticker is the right cadence), which is why they are
	-- here and not in COMBAT_SAMPLED.
	["warbank"] = true, -- warband bank reachable
	["prey"] = true, -- hunting Prey
	["housereturn"] = true, -- can return from a visited house
	["myth"] = true, -- active M+ keystone
	["coven"] = true, -- Shadowlands covenant
	["covenant"] = true, -- alias for [coven]
	["uslot"] = true, -- equipment slot with a usable (on-use) item
	["superflyable"] = true, -- steady/skyriding flight available here
	["blockedflyable"] = true, -- flight suppressed despite a flyable zone
	["anyflyable"] = true, -- any form of flight available
	["worldhover"] = true, -- mouse over the 3D world, not the UI

	-- Pet / weapon state.
	["havepet"] = true,
	["petcontrol"] = true,
	["imbuedmh"] = true,
	["imbuedoh"] = true,

	-- Combat-sampled: value is frozen at combat entry (see COMBAT_SAMPLED).
	["moving"] = true,
	["falling"] = true,
	["ready"] = true,
	["have"] = true,
	["buff"] = true,
	["debuff"] = true,
	["selfbuff"] = true,
	["selfdebuff"] = true,
	["combo"] = true,
}

-- Tokens whose underlying state can change mid-combat. Wise drives visibility
-- from insecure Lua, which cannot touch secure attributes during lockdown, so
-- these cannot re-drive visibility while combat is up. Instead their value is
-- sampled at PLAYER_REGEN_DISABLED and held until combat ends. Out of combat
-- they evaluate live like any other token.
--
-- (A secure proxy frame that pushes values into a protected snippet environment
-- could sample live during combat instead of freezing at entry; deliberately
-- not built — the complexity isn't justified yet.)
local COMBAT_SAMPLED = {
	["moving"] = true,
	["falling"] = true,
	["ready"] = true,
	["have"] = true,
	["buff"] = true,
	["debuff"] = true,
	["selfbuff"] = true,
	["selfdebuff"] = true,
	["combo"] = true,
}

-- Frozen values for COMBAT_SAMPLED tokens, keyed by the full token text
-- (e.g. "combo:3") so parameterised forms each get their own sample.
local combatSamples = {}
local combatSampleKeys = {}

-- Record a token we evaluated, so combat entry knows what to sample.
local function NoteCombatSampledToken(token)
	if not combatSampleKeys[token] then
		combatSampleKeys[token] = true
	end
end

-- Called at PLAYER_REGEN_DISABLED. Evaluates every combat-sampled token seen so
-- far and freezes the result for the duration of combat.
--
-- EvalCustomToken is read off the internals table at call time rather than
-- captured as an upvalue: it is defined in EvalToken.lua, which loads after
-- this file, so an upvalue taken here would be permanently nil. The nil guard
-- stays for the same reason it always existed — if combat somehow starts before
-- the engine finishes loading, sampling is skipped rather than erroring.
function Wise.SampleCombatConditionals()
	local EvalCustomToken = E.EvalCustomToken
	if not EvalCustomToken then
		return
	end
	wipe(combatSamples)
	for token in pairs(combatSampleKeys) do
		-- Evaluate without the frozen-value shortcut by sampling before lockdown
		-- semantics apply. pcall keeps a bad token from breaking combat entry.
		local ok, value = pcall(EvalCustomToken, token, nil, true)
		combatSamples[token] = ok and value or false
	end
end

-- Called at PLAYER_REGEN_ENABLED. Drops the frozen values so tokens go live again.
function Wise.ClearCombatConditionalSamples()
	wipe(combatSamples)
end

-- Availability providers for the [available] conditional, keyed by group name.
-- A module owning a dynamically-populated interface registers a function here that
-- returns true when the interface currently has something actionable. Interfaces
-- with no registered provider report available whenever they hold any action, so
-- [available] is meaningful on ordinary bars too.
Wise.AvailabilityProviders = Wise.AvailabilityProviders or {}

function Wise:RegisterAvailabilityProvider(groupName, fn)
	Wise.AvailabilityProviders[groupName] = fn
end

-- Does the named interface currently have anything worth showing?
--
-- `key` is the optional argument form, [available:<key>], which asks a narrower
-- question: does THIS part of the interface have something? A provider that
-- understands keys (e.g. one slot of a multi-slot generated interface) can
-- answer per-key, so each slot shows on its own availability instead of the
-- whole interface showing whenever any part of it is available.
local function IsGroupAvailableNow(groupName, key)
	if not groupName then
		return false
	end
	local provider = Wise.AvailabilityProviders[groupName]
	if provider then
		local ok, result = pcall(provider, groupName, key)
		if ok then
			return result and true or false
		end
		return false
	end

	-- Default: the interface is available when it holds at least one action.
	local group = WiseDB and WiseDB.groups and WiseDB.groups[groupName]
	if not group then
		return false
	end
	if group.actions then
		for _, states in pairs(group.actions) do
			if states and #states > 0 then
				return true
			end
		end
	end
	if group.buttons and #group.buttons > 0 then
		return true
	end
	return false
end


Wise.IsGroupAvailableNow = IsGroupAvailableNow

-- Published to the engine's internals. EvalToken.lua assigns E.EvalCustomToken
-- once it is defined; SampleCombatConditionals reads it through E at call time
-- (not at load time) precisely because this file loads first.
E.CUSTOM_VIS_CONDITIONALS = CUSTOM_VIS_CONDITIONALS
E.COMBAT_SAMPLED = COMBAT_SAMPLED
E.combatSamples = combatSamples
E.NoteCombatSampledToken = NoteCombatSampledToken
E.IsGroupAvailableNow = IsGroupAvailableNow
