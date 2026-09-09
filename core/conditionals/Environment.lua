-- core/conditionals/Environment.lua
--
-- Surroundings and unit auras, split out of Predicates.lua to keep both files
-- inside the 100-300 line target in AGENTS.md. Same contract as its sibling:
-- each function answers one question about the world and returns a plain value;
-- token parsing belongs to EvalToken.lua.
--
-- Flight is deliberately three functions rather than one, because "can I fly
-- here" is three separate questions -- the zone may permit flight, the
-- character may have skyriding, and a buff or zone effect may suppress flight
-- despite both being true. [superflyable] / [anyflyable] / [blockedflyable]
-- each need a different pair of those answers.
--
-- HasAura backs [buff]/[debuff]/[selfbuff]/[selfdebuff], all of which are on
-- the combat-sampled list in Vocabulary.lua -- in lockdown their frozen value
-- is used and this never runs.
--
-- Loaded after Predicates.lua and before EvalToken.lua.

local addonName, Wise = ...

local ipairs = ipairs
local pcall = pcall
local C_UnitAuras = C_UnitAuras
local UnitExists = UnitExists
local UIParent = UIParent
local WorldFrame = WorldFrame

local E = Wise.CondEngine or {}
Wise.CondEngine = E

local ArgMatches = E.ArgMatches

-- Secret-value probe, hoisted and passed to pcall by reference so no closure is
-- allocated per call -- HasAura runs on the per-button state pass. Mirrors the
-- identical helper in Predicates.lua and core/GUI.lua.
local function checkSecret(val)
	return issecretvalue and issecretvalue(val)
end

local function IsSuperFlyable()
    -- Advanced (skyriding) flight available in this area.
	local ok, v = pcall(function()
		return IsAdvancedFlyableArea and IsAdvancedFlyableArea()
	end)
	return ok and v and true or false
end
local function IsPlainFlyable()
	local ok, v = pcall(function()
		return IsFlyableArea and IsFlyableArea()
	end)
	return ok and v and true or false
end
-- [worldhover] — the cursor is over the 3D world rather than any UI frame.
--
-- A full-screen secure frame at strata BACKGROUND with IsMouseMotionFocus would
-- work in combat too, but Wise has no such frame, so we ask GetMouseFoci()
-- whether anything other than WorldFrame/UIParent is under the cursor. That is
-- accurate out of combat, which is where Wise can act on it.
local function IsMouseOverWorld()
	local foci
	if GetMouseFoci then
		local ok, result = pcall(GetMouseFoci)
		foci = ok and result or nil
	elseif GetMouseFocus then
		local ok, result = pcall(GetMouseFocus)
		foci = ok and result and { result } or nil
	end
	if not foci then
		return false
	end
	for _, frame in ipairs(foci) do
		if frame and frame ~= WorldFrame and frame ~= UIParent then
			-- A real UI frame has the cursor: not hovering the world.
			return false
		end
	end
	return true
end

local function IsFlightBlocked()
	-- Flyable zone, but the character cannot actually take off: the usual cause is
	-- a zone/phase restriction. Approximated as "zone says flyable, neither flight
	-- mode is usable" — Wise has no secure driver to ask directly.
	if not IsPlainFlyable() then
		return false
	end
	local mounted = IsMounted and IsMounted()
	local gliding = false
	if C_PlayerInfo and C_PlayerInfo.GetGlidingInfo then
		local ok, info = pcall(C_PlayerInfo.GetGlidingInfo)
		gliding = ok and info and true or false
	end
	return not (mounted or gliding) and not IsSuperFlyable()
end

-- [buff:]/[debuff:]/[selfbuff:]/[selfdebuff:] — aura present on a unit.
-- Matches by aura name, case-insensitively, across the /-separated alternatives.
--
-- Aura secrecy: while the client withholds aura data (12.0+ combat in M+/raid/
-- PvP content) names read back as secret values, and comparing them yields
-- nonsense. Wise has no tri-state for "unknown, ask again later", so we report
-- false — the token simply stops matching for the duration.
-- Combined with the combat-sampling freeze above, an aura token evaluated BEFORE
-- combat keeps its entry value anyway, so the practical effect is limited to
-- tokens first seen mid-fight.
local function HasAura(unit, arg, filter)
	if not arg or arg == "" then
		return false
	end
	if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
		return false
	end
	if not UnitExists(unit) then
		return false
	end
	-- Never compare secret aura names; the result would be meaningless.
	if Wise.Compat and Wise.Compat.AreAurasSecret and Wise.Compat.AreAurasSecret() then
		return false
	end
	for i = 1, 40 do
		local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
		if not ok or not data then
			break
		end
		local name = data.name
		-- A secret name must not reach the comparison even if the query above
		-- reported clear (state can flip between the two calls). checkSecret is
		-- the hoisted probe used everywhere else in this file; it must be pcall'd
		-- because touching a secret value can itself throw.
		local secretOk, isSecret = pcall(checkSecret, name)
		if name and secretOk and not isSecret and ArgMatches(arg, name) then
			return true
		end
	end
	return false
end

-- Published to the engine's internals for EvalToken.lua.
E.IsSuperFlyable = IsSuperFlyable
E.IsPlainFlyable = IsPlainFlyable
E.IsMouseOverWorld = IsMouseOverWorld
E.IsFlightBlocked = IsFlightBlocked
E.HasAura = HasAura
