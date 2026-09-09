-- core/conditionals/ConditionString.lua
--
-- Whole-condition-string parsing, extracted from core/GUI.lua. EvalToken.lua
-- answers one token; this file walks a full string like
-- "[zoneability][combat,bank]" — bracket groups OR'd together, tokens within a
-- group AND'd — splitting each group into Wise custom tokens (evaluated via
-- EvalCustomToken) and native macro tokens (handed to SecureCmdOptionParse).
--
-- Four entry points that differ ONLY in how they treat native tokens and what
-- an empty string means. Picking the wrong one is the classic bug here, so:
--
--   HasCustomConditionals  — cheap pre-check: does this string need us at all?
--   EvalFullConditionString — ASSUMES native tokens match. For layout built in
--       combat, where secure buttons must exist regardless. Empty = true.
--   EvalConditionExact     — evaluates native tokens for REAL via
--       SecureCmdOptionParse. Reflects current state; picks which icon a
--       multi-state slot shows. Empty = true. Public as Wise:EvalConditionExact.
--   EvalConditionString    — like Exact, but SKIPS groups that contain no custom
--       token (the secure driver already handles those). Empty = FALSE.
--
-- Keeping raw custom tokens out of SecureCmdOptionParse also matters for a
-- cosmetic reason: the client prints "unknown macro option: <name>" otherwise.
--
-- Loaded last in core/conditionals/, after EvalToken.lua.

local addonName, Wise = ...

local ipairs = ipairs
local table = table
local SecureCmdOptionParse = SecureCmdOptionParse

local E = Wise.CondEngine or {}
Wise.CondEngine = E

local CUSTOM_VIS_CONDITIONALS = E.CUSTOM_VIS_CONDITIONALS
local EvalCustomToken = E.EvalCustomToken

-- Helper to determine if a condition string contains any custom conditionals or interface dependencies
local function HasCustomConditionals(str)
	if not str or str == "" then
		return false
	end
	if str:find("wise:") then
		return true
	end
	for block in str:gmatch("%[([^%]]*)%]") do
		for token in block:gmatch("[^,]+") do
			token = token:match("^%s*(.-)%s*$")
			local base = token:match("^no?(.+)") or token
			base = base:match("^([^:]+)") or base
			if CUSTOM_VIS_CONDITIONALS[base:lower()] then
				return true
			end
		end
	end
	return false
end

-- Evaluate a full condition string (e.g. "[extrabar]", "[zoneability]", "[combat,bank]")
-- Returns true if ANY bracket group matches (OR across groups). Handles both custom and secure conditionals.
-- Used by dynamic groups to determine per-slot visibility.
-- `groupName` gives group-scoped tokens (e.g. [available], [available:<slot>])
-- the context they need; omitted for callers with no group in hand.
local function EvalFullConditionString(str, groupName)
	if not str or str == "" then
		return true
	end -- No condition = always show

	for block in str:gmatch("%[([^%]]*)%]") do
		local customTokens = {}
		local secureTokens = {}

		for token in block:gmatch("[^,]+") do
			local trimmed = token:match("^%s*(.-)%s*$")
			local check = trimmed:lower()
			local lookupBase = check
			if lookupBase:sub(1, 2) == "no" then
				local stripped = lookupBase:sub(3)
				local stripBase = stripped:match("^([^:]+)") or stripped
				if CUSTOM_VIS_CONDITIONALS[stripBase] then
					lookupBase = stripped
				end
			end
			local baseToken = lookupBase:match("^([^:]+)") or lookupBase

			if CUSTOM_VIS_CONDITIONALS[baseToken] then
				table.insert(customTokens, trimmed)
			else
				table.insert(secureTokens, trimmed)
			end
		end

		local groupMatch = true

		for _, ct in ipairs(customTokens) do
			if not EvalCustomToken(ct, groupName) then
				groupMatch = false
				break
			end
		end

		if groupMatch and #secureTokens > 0 then
			-- Secure tokens represent standard WoW macro conditionals (like combat, mod, stealth, etc.)
			-- which can change at runtime. Since secure layouts cannot be restructured in combat,
			-- we must assume secure conditionals match for layout generation so the secure buttons
			-- are created and positioned. They will be evaluated securely when clicked/used.
		end

		if groupMatch then
			return true
		end
	end

	return false
end

-- Exact insecure evaluation of a full condition string, mixing native and custom tokens.
-- Within each bracket group (AND), native tokens (combat, mod, stealth, …) are evaluated
-- via SecureCmdOptionParse and Wise custom tokens (zoneability, bank, undermouse, …) via
-- EvalCustomToken; groups are OR'd together — matching WoW macro semantics. Unlike
-- EvalFullConditionString (which assumes native tokens match, for in-combat layout), this
-- reflects the CURRENT state and is used to pick which icon a multi-state slot shows.
-- It also keeps raw custom tokens out of SecureCmdOptionParse, which would otherwise make
-- the client print "unknown macro option: <name>".
-- `groupName` gives group-scoped custom tokens ([available], [available:<slot>])
-- the context they need. Omitting it makes those tokens evaluate against a nil
-- group, which reads as "not available" and greys the slot out.
local function EvalConditionExact(str, groupName)
	if not str or str == "" then
		return true -- No condition = always matches
	end

	for block in str:gmatch("%[([^%]]*)%]") do
		local secureTokens = {}
		local groupMatch = true

		for token in block:gmatch("[^,]+") do
			local trimmed = token:match("^%s*(.-)%s*$")
			local check = trimmed:lower()
			-- Determine the base name, tolerating a leading 'no' negation on custom tokens.
			local lookupBase = check
			if lookupBase:sub(1, 2) == "no" then
				local stripped = lookupBase:sub(3)
				local stripBase = stripped:match("^([^:]+)") or stripped
				if CUSTOM_VIS_CONDITIONALS[stripBase] then
					lookupBase = stripped
				end
			end
			local baseToken = lookupBase:match("^([^:]+)") or lookupBase

			if CUSTOM_VIS_CONDITIONALS[baseToken] then
				if not EvalCustomToken(trimmed, groupName) then
					groupMatch = false
					break
				end
			else
				table.insert(secureTokens, trimmed)
			end
		end

		if groupMatch and #secureTokens > 0 then
			local secureStr = "[" .. table.concat(secureTokens, ",") .. "] true; false"
			if SecureCmdOptionParse(secureStr) ~= "true" then
				groupMatch = false
			end
		end

		if groupMatch then
			return true
		end
	end

	return false
end

-- Public wrapper so other modules (e.g. IndicatorRules) can evaluate a macro
-- condition the SAME way the slot engine does — native tokens via
-- SecureCmdOptionParse + Wise custom tokens, OR'd across bracket groups, reflecting
-- the CURRENT state. Empty/nil condition = true (always).
function Wise:EvalConditionExact(str)
	return EvalConditionExact(str)
end

-- Evaluate a condition string (e.g. "[zoneability][extrabar][combat,bank]")
-- Returns true if ANY bracket group containing a custom conditional matches (OR across groups).
-- Bracket groups with ONLY built-in conditionals are skipped (secure driver handles those).
local function EvalConditionString(str, groupName)
	if not str or str == "" then
		return false
	end

	for block in str:gmatch("%[([^%]]*)%]") do
		local blockHasCustom = false
		local customTokens = {}
		local secureTokens = {}

		for token in block:gmatch("[^,]+") do
			local trimmed = token:match("^%s*(.-)%s*$")
			local check = trimmed:lower()
			-- Strip 'no' prefix for lookup
			local lookupBase = check
			if lookupBase:sub(1, 2) == "no" then
				local stripped = lookupBase:sub(3)
				local stripBase = stripped:match("^([^:]+)") or stripped
				if CUSTOM_VIS_CONDITIONALS[stripBase] then
					lookupBase = stripped
				end
			end
			local baseToken = lookupBase:match("^([^:]+)") or lookupBase

			if CUSTOM_VIS_CONDITIONALS[baseToken] then
				blockHasCustom = true
				table.insert(customTokens, trimmed)
			else
				table.insert(secureTokens, trimmed)
			end
		end

		if blockHasCustom then
			local groupMatch = true

			for _, ct in ipairs(customTokens) do
				if not EvalCustomToken(ct, groupName) then
					groupMatch = false
					break
				end
			end

			if groupMatch and #secureTokens > 0 then
				local secureStr = "[" .. table.concat(secureTokens, ",") .. "] true; false"
				local result = SecureCmdOptionParse(secureStr)
				if result ~= "true" then
					groupMatch = false
				end
			end

			if groupMatch then
				return true
			end
		end
	end

	return false
end

-- Published to the engine's internals. core/GUI.lua pulls these three back out
-- as upvalues (UpdateGroupDisplay and BuildVisibilityDriver call them on hot
-- paths, so they are not routed through Wise: method dispatch).
E.HasCustomConditionals = HasCustomConditionals
E.EvalFullConditionString = EvalFullConditionString
E.EvalConditionExact = EvalConditionExact
E.EvalConditionString = EvalConditionString
