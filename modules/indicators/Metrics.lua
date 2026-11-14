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
Wise.INDICATOR_RULES_REV = 6

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
-- it is gone.
--
-- The cooldown metrics survive secrecy only partly. Blizzard's API docs (12.1.5)
-- let cooldown TIMES and currentCharges be secret, but keep the cooldown flags
-- (isActive/isOnGCD) and maxCharges never-secret. So "available"/"cooldown" are
-- answered from the flags when the times hide, and a hidden charge count is
-- UNKNOWN (no charges rule matches) unless no recharge is running, which means
-- full charges. See ResolveSpellState in State.lua.
local METRICS = {
	{ key = "charges", label = "Charges", numeric = true },
	-- Offered only to classes that HAVE a secondary resource (see CLASS_RESOURCES
	-- below); its label is resolved per class ("Holy Power", "Combo Points", ...).
	-- Blizzard's 12.0 notes call these secondary resources non-secret, unlike
	-- primary power. That is documentation, not a measurement, so State.lua still
	-- checks every read and treats a hidden value as unknown.
	{ key = "resource", label = "Class resource", numeric = true },
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

-- Class -> secondary resource. `enumName` is the Enum.PowerType member, resolved
-- at runtime (never hardcode the numbers); `token` is the powerType string
-- UNIT_POWER_UPDATE passes as its second argument.
--
-- ASSUMPTION (unverified in-client): UnitPower("player", Enum.PowerType.Runes)
-- returns the number of READY runes. Death Knight runes recharge on their own
-- and RUNE_POWER_UPDATE is their real change event.
local CLASS_RESOURCES = {
	ROGUE = { enumName = "ComboPoints", token = "COMBO_POINTS", label = "Combo Points" },
	DRUID = { enumName = "ComboPoints", token = "COMBO_POINTS", label = "Combo Points" },
	PALADIN = { enumName = "HolyPower", token = "HOLY_POWER", label = "Holy Power" },
	MONK = { enumName = "Chi", token = "CHI", label = "Chi" },
	WARLOCK = { enumName = "SoulShards", token = "SOUL_SHARDS", label = "Soul Shards" },
	MAGE = { enumName = "ArcaneCharges", token = "ARCANE_CHARGES", label = "Arcane Charges" },
	EVOKER = { enumName = "Essence", token = "ESSENCE", label = "Essence" },
	DEATHKNIGHT = { enumName = "Runes", token = "RUNES", label = "Runes" },
}

-- The player's resource, cached: { powerType, token, label } or nil when the
-- class has none (or the client lacks the enum member). Resolved at load and on
-- PLAYER_ENTERING_WORLD so the per-pass path never calls UnitClass. UnitClass is
-- read at call time on purpose, so it can be stubbed.
local classResource = nil
local function RefreshClassResource()
	classResource = nil
	local unitClass = _G.UnitClass
	if not unitClass then
		return
	end
	local ok, _, classToken = pcall(unitClass, "player")
	local spec = ok and classToken and CLASS_RESOURCES[classToken]
	local powerTypes = spec and _G.Enum and _G.Enum.PowerType
	local powerType = powerTypes and powerTypes[spec.enumName]
	if type(powerType) == "number" then
		classResource = { powerType = powerType, token = spec.token, label = spec.label }
	end
end

local function GetClassResource()
	return classResource
end

-- Display label for a metric key; "resource" takes the player's class label.
local function MetricLabel(metricKey)
	if metricKey == "resource" and classResource then
		return classResource.label
	end
	return METRIC_LABELS[metricKey]
end

-- Metrics the editor should offer THIS character: "resource" is dropped when the
-- class has no secondary resource. Returns a fresh list (editor-only path).
local function OfferedMetrics()
	local list = {}
	for _, m in ipairs(METRICS) do
		if m.key ~= "resource" or classResource then
			list[#list + 1] = { key = m.key, label = MetricLabel(m.key) }
		end
	end
	return list
end

-- Diagnostic only: Blizzard's declared secrecy for the resource's power type.
-- Never consulted to decide anything -- State.lua checks every value it reads.
local function GetResourceSecrecy()
	local cs = _G.C_Secrets
	if not (classResource and cs and cs.GetPowerTypeSecrecy) then
		return nil
	end
	local ok, level = pcall(cs.GetPowerTypeSecrecy, classResource.powerType)
	if ok then
		return level
	end
	return nil
end

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
IR.RefreshClassResource = RefreshClassResource
IR.GetClassResource = GetClassResource
IR.MetricLabel = MetricLabel
IR.OfferedMetrics = OfferedMetrics
IR.GetResourceSecrecy = GetResourceSecrecy
IR.IsNumericMetric = IsNumericMetric
IR.IsRetiredRule = IsRetiredRule
IR.OXED_SOUND_NONE = OXED_SOUND_NONE
-- NOTE: the Safe* pcall probes are deliberately NOT here. Each reads scratch
-- upvalues its caller sets immediately beforehand, so probe and caller must live
-- in the SAME file -- split apart, the caller's assignment writes a global while
-- the probe keeps reading its own nil local, and the check silently misreports.

RefreshClassResource()
