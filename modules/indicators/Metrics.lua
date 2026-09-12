-- modules/indicators/Metrics.lua
--
-- The metric vocabulary indicator rules are written against. Split out of
-- modules/IndicatorRules.lua on the banner boundaries it already carried:
--
--   Metrics  this file -- the metric list, labels, and colour names
--   State    resolving an action's live state without tripping secret values
--   Render   the editor in the node properties panel
--   Index    spellID -> rules lookup plus edge-detection state
--   Paint    the runtime pass: border, glow, count, edge-triggered sound
--
-- Load in that order: Metrics first (everything reads METRICS), Paint last.
--
-- Per-action indicator rules -------------------------------------------------
-- Generalises the old global, Resto-only "Abundance Colors, Glows & Sounds" into
-- a PER-ACTION feature: any action can carry `action.indicatorRules` — a list of
-- { operator, value, color, glow, sound } rows matched against that action's own
-- live aura-stack count. The matched rule colors the button border, optionally
-- glows it, shows the count, and fires an Oxed sound on the rising edge. Rules are
-- authored in the slot configurator's node properties window (alongside Conditions,
-- Availability, Audio Cue). Shared sound/dropdown helpers come from modules/Audio.lua.

local addonName, Wise = ...

local tinsert = table.insert
local OXED_SOUND_NONE = Wise.OXED_SOUND_NONE

-- Bumped on behavior changes so live diagnostics can confirm which revision the
-- client actually loaded (see the abundance-combat-probe in MechanicQueue).
Wise.INDICATOR_RULES_REV = 4

local BOLD_COLORS = {
	{ name = "Red", r = 1, g = 0, b = 0 },
	{ name = "Green", r = 0, g = 1, b = 0 },
	{ name = "Blue", r = 0, g = 0, b = 1 },
	{ name = "Yellow", r = 1, g = 1, b = 0 },
	{ name = "Orange", r = 1, g = 0.5, b = 0 },
	{ name = "Purple", r = 0.6, g = 0.1, b = 0.9 },
	{ name = "Cyan", r = 0, g = 1, b = 1 },
	{ name = "Magenta", r = 1, g = 0, b = 1 },
	{ name = "White", r = 1, g = 1, b = 1 },
	{ name = "Pink", r = 1, g = 0.5, b = 0.7 },
}

local function GetColorRGB(colorName)
	for _, c in ipairs(BOLD_COLORS) do
		if c.name == colorName then
			return c.r, c.g, c.b
		end
	end
	return 1, 1, 1
end

-- What a rule WATCHES. Numeric metrics use operator+value; boolean metrics match
-- when their state is true (no operator/value). Order here is the dropdown order.
-- `numeric` decides whether the operator+value controls show in the UI.
--
-- "Aura stacks" is DELIBERATELY ABSENT. Under 12.0.7 combat secrecy a stack count
-- is displayable but not inspectable (see the Combat Aura Secrecy section in
-- AGENTS.md), so a stacks-driven colour/glow/sound can never fire in combat —
-- which is the only time it would matter. Offering it produces an indicator that
-- silently does nothing in a raid, so the option is withdrawn rather than shipped
-- broken. The stack COUNT still displays on the button corner; only branching on
-- it is gone. Everything cooldown- or usability-derived is unaffected: those read
-- fine in combat.
local METRICS = {
	{ key = "charges", label = "Charges", numeric = true },
	{ key = "available", label = "Available (off CD)", numeric = false },
	{ key = "cooldown", label = "On cooldown", numeric = false },
	{ key = "buff_active", label = "Buff active", numeric = false },
	{ key = "buff_missing", label = "Buff missing", numeric = false },
}
local METRIC_LABELS = {}
local METRIC_IS_NUMERIC = {}
for _, m in ipairs(METRICS) do
	METRIC_LABELS[m.key] = m.label
	METRIC_IS_NUMERIC[m.key] = m.numeric
end
local DEFAULT_METRIC = "available"

-- Rules authored against the withdrawn "stacks" metric — either explicitly, or
-- as the legacy shape that carried NO metric field and meant stacks by default.
-- These must go INERT, not fall through to DEFAULT_METRIC: silently re-reading
-- an "Abundance <= 2" rule as "available <= 2" would colour the button off an
-- unrelated condition, which is worse than the rule simply not firing.
local function IsRetiredRule(rule)
	local m = rule.metric
	if m == nil or m == "stacks" then
		return true
	end
	return METRIC_LABELS[m] == nil
end

local function RuleMetric(rule)
	local m = rule.metric
	if m and METRIC_LABELS[m] then
		return m
	end
	return DEFAULT_METRIC
end

local function IsNumericMetric(metricKey)
	return METRIC_IS_NUMERIC[metricKey] == true
end

-- Published for the sibling files under modules/indicators/. Lua locals do not
-- cross files, so anything the other modules need is re-exported here.
local IR = Wise.IndicatorRules or {}
Wise.IndicatorRules = IR
IR.BOLD_COLORS = BOLD_COLORS
IR.GetColorRGB = GetColorRGB
IR.METRICS = METRICS
IR.METRIC_LABELS = METRIC_LABELS
IR.METRIC_IS_NUMERIC = METRIC_IS_NUMERIC
IR.DEFAULT_METRIC = DEFAULT_METRIC
IR.RuleMetric = RuleMetric
IR.IsNumericMetric = IsNumericMetric
IR.IsRetiredRule = IsRetiredRule
IR.OXED_SOUND_NONE = OXED_SOUND_NONE
-- NOTE: the Safe* pcall probes are deliberately NOT here. Each reads scratch
-- upvalues its caller sets immediately beforehand, so probe and caller must live
-- in the SAME file -- split apart, the caller's assignment writes a global while
-- the probe keeps reading its own nil local, and the check silently misreports.
