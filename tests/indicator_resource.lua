-- Tests for the "class resource" indicator metric (Holy Power, Combo Points...).
--
-- Blizzard's 12.0 notes call a player's SECONDARY resources non-secret, but that
-- is documentation, not a measurement, so State.lua checks every read: a hidden
-- value is UNKNOWN and matches no resource rule (neither <= nor >=), never 0.
--
-- The sim has no real secret values, so a TABLE stands in for one: it throws on
-- comparison and arithmetic, and SecretSafeNumber turns it into nil.
--
-- UnitClass/UnitPower are stubbed through _G: the indicator code reads both at
-- call time (UnitClass inside RefreshClassResource, UnitPower inside the hoisted
-- probe), so no hoisted upvalue defeats the stub.

local HIDDEN = {}
local IR = Wise.IndicatorRules

-- Run fn with UnitClass answering `classToken` and UnitPower("player", pt)
-- answering power() (a function, so a test can change it between passes).
-- Restores everything even if fn throws.
local function WithResource(classToken, power, fn)
	local savedClass, savedPower = _G.UnitClass, _G.UnitPower
	_G.UnitClass = function()
		return classToken, classToken, 1
	end
	_G.UnitPower = function()
		return power()
	end
	IR.RefreshClassResource()
	local ok, a, b = pcall(fn)
	_G.UnitClass, _G.UnitPower = savedClass, savedPower
	IR.RefreshClassResource()
	if not ok then
		error(a, 0)
	end
	return a, b
end

local function Rule(metric, operator, value, color)
	return { metric = metric, operator = operator, value = value, color = color or "Red", glow = false }
end

-- One-slot indicator setup for `rules`; runs one pass and reports whether the
-- border showed, plus its colour. Must be called inside WithResource.
local function BorderFor(rules)
	local CAST_ID = 999301
	local savedGroups = WiseDB.groups
	local action = { type = "spell", value = CAST_ID, name = "Wise Resource Test", indicatorRules = rules }
	WiseDB.groups = {
		ResourceTest = {
			actions = {
				[1] = {
					{ type = "spell", value = CAST_ID },
					graph = { nodes = { { id = 1, action = action, condition = "" } }, connections = {} },
				},
			},
		},
	}
	local btn = CreateFrame("Button", nil, UIParent)
	btn:SetSize(30, 30)
	Wise.buttonMeta = Wise.buttonMeta or {}
	Wise.buttonMeta[btn] = {
		actionType = "spell",
		actionValue = CAST_ID,
		baseSpellID = CAST_ID,
		spellID = CAST_ID,
		states = WiseDB.groups.ResourceTest.actions[1],
	}
	Wise.frames = Wise.frames or {}
	Wise.frames["__ResourceTest"] = { buttons = { btn } }

	local ok, err = pcall(function()
		Wise:RebuildIndicatorRules()
		Wise:UpdateIndicatorRules()
	end)
	local shown = btn.indicatorBorder ~= nil and btn.indicatorBorder:IsShown()
	local r, g, b
	if shown then
		r, g, b = btn.indicatorBorder:GetVertexColor()
	end

	Wise.frames["__ResourceTest"] = nil
	Wise.buttonMeta[btn] = nil
	WiseDB.groups = savedGroups
	Wise:RebuildIndicatorRules()
	if not ok then
		error(err, 0)
	end
	return shown, r, g, b
end

local function ShownFor(classToken, value, rule)
	return (WithResource(classToken, function()
		return value
	end, function()
		return (BorderFor({ rule }))
	end))
end

test("IndicatorResource: readable resource matches threshold rules", function()
	assertTrue(ShownFor("PALADIN", 3, Rule("resource", ">=", 3)))
	assertFalse(ShownFor("PALADIN", 2, Rule("resource", ">=", 3)))
	assertTrue(ShownFor("PALADIN", 2, Rule("resource", "<=", 2)))
	assertTrue(ShownFor("ROGUE", 0, Rule("resource", "=", 0))) -- a real 0 is known
	assertTrue(ShownFor("EVOKER", 4, Rule("resource", ">", 3)))
end)

test("IndicatorResource: a hidden resource matches no rule, <= and >= alike", function()
	-- The bug this guards: unknown read as 0 would light "<= N" all fight.
	assertFalse(ShownFor("PALADIN", HIDDEN, Rule("resource", "<=", 5)))
	assertFalse(ShownFor("PALADIN", HIDDEN, Rule("resource", ">=", 0)))
	assertFalse(ShownFor("PALADIN", HIDDEN, Rule("resource", "=", 0)))
	-- Unreadable for other reasons: nil, and a UnitPower that throws.
	assertFalse(ShownFor("PALADIN", nil, Rule("resource", "<=", 5)))
	local threw = WithResource("PALADIN", function()
		error("refused", 0)
	end, function()
		return (BorderFor({ Rule("resource", "<=", 5) }))
	end)
	assertFalse(threw)
end)

test("IndicatorResource: a class without a resource never matches", function()
	assertFalse(ShownFor("WARRIOR", 3, Rule("resource", ">=", 0)))
	assertFalse(ShownFor("WARRIOR", 0, Rule("resource", "<=", 5)))
	local cr = WithResource("WARRIOR", function()
		return 1
	end, function()
		return IR.GetClassResource()
	end)
	assertEquals(nil, cr)
	-- The rule is not retired: the key is still valid, it just cannot match here.
	assertFalse(IR.IsRetiredRule(Rule("resource", ">=", 1)))
end)

test("IndicatorResource: closest threshold wins, like charges", function()
	-- Only the closer rule glows, so a glow means it won. Both match at 4; the
	-- >=4 rule is distance 0 and must beat the broader >=1 rule listed before it.
	local savedGlow = Wise.ShowOverlayGlow
	local glowed = 0
	Wise.ShowOverlayGlow = function()
		glowed = glowed + 1
	end
	local near = Rule("resource", ">=", 4, "Blue")
	near.glow = true
	local ok, err = pcall(function()
		WithResource("PALADIN", function()
			return 4
		end, function()
			BorderFor({ Rule("resource", ">=", 1, "Red"), near })
		end)
	end)
	Wise.ShowOverlayGlow = savedGlow
	if not ok then
		error(err, 0)
	end
	assertEquals(1, glowed)
end)

test("IndicatorResource: class labels and the dropdown list", function()
	local function labels(classToken)
		return WithResource(classToken, function()
			return 0
		end, function()
			local out = {}
			for _, m in ipairs(IR.OfferedMetrics()) do
				out[m.key] = m.label
			end
			return out
		end)
	end
	local pal = labels("PALADIN")
	assertEquals("Holy Power", pal.resource)
	assertEquals("Charges", pal.charges)
	assertEquals("Combo Points", labels("ROGUE").resource)
	assertEquals("Combo Points", labels("DRUID").resource)
	assertEquals("Chi", labels("MONK").resource)
	assertEquals("Soul Shards", labels("WARLOCK").resource)
	assertEquals("Arcane Charges", labels("MAGE").resource)
	assertEquals("Essence", labels("EVOKER").resource)
	assertEquals("Runes", labels("DEATHKNIGHT").resource)
	-- No resource: the metric is omitted, everything else is still offered.
	local war = labels("WARRIOR")
	assertEquals(nil, war.resource)
	assertEquals("Charges", war.charges)
	assertEquals("Buff active", war.buff_active)
	-- A stored rule on such a character still labels sanely.
	local generic = WithResource("WARRIOR", function()
		return 0
	end, function()
		return IR.MetricLabel("resource")
	end)
	assertEquals("Class resource", generic)
end)

-- UNIT_POWER_UPDATE fires constantly for energy/mana, so the handler must only
-- schedule a repaint for the class resource's own token, and only while a built
-- rule actually uses the metric.
test("IndicatorResource: power events only schedule for the matching resource", function()
	local savedSchedule = Wise.ScheduleIndicatorUpdate
	local calls = 0
	Wise.ScheduleIndicatorUpdate = function()
		calls = calls + 1
	end
	local function fire(event, unit, powerType)
		local before = calls
		IR.OnIndicatorEvent(nil, event, unit, powerType)
		return calls - before
	end

	local ok, err = pcall(function()
		WithResource("PALADIN", function()
			return 3
		end, function()
			-- No resource rule built: even the matching token is ignored.
			IR.anyResourceRule = false
			assertEquals(0, fire("UNIT_POWER_UPDATE", "player", "HOLY_POWER"))

			-- A rule exists: only the class resource's token schedules.
			IR.anyResourceRule = true
			assertEquals(1, fire("UNIT_POWER_UPDATE", "player", "HOLY_POWER"))
			assertEquals(0, fire("UNIT_POWER_UPDATE", "player", "ENERGY"))
			assertEquals(0, fire("UNIT_POWER_UPDATE", "player", "MANA"))
			assertEquals(0, fire("UNIT_POWER_UPDATE", "player", "COMBO_POINTS"))
			-- RUNE_POWER_UPDATE is a Death Knight event; irrelevant to a Paladin.
			assertEquals(0, fire("RUNE_POWER_UPDATE"))
			-- Other events keep scheduling as before.
			assertEquals(1, fire("SPELL_UPDATE_COOLDOWN"))
		end)
		WithResource("DEATHKNIGHT", function()
			return 6
		end, function()
			IR.anyResourceRule = true
			assertEquals(1, fire("RUNE_POWER_UPDATE", 3, true))
			assertEquals(0, fire("UNIT_POWER_UPDATE", "player", "RUNIC_POWER"))
			IR.anyResourceRule = false
			assertEquals(0, fire("RUNE_POWER_UPDATE", 3, true))
		end)
		WithResource("WARRIOR", function()
			return 0
		end, function()
			IR.anyResourceRule = true
			assertEquals(0, fire("UNIT_POWER_UPDATE", "player", "HOLY_POWER"))
			assertEquals(0, fire("RUNE_POWER_UPDATE"))
		end)
	end)

	Wise.ScheduleIndicatorUpdate = savedSchedule
	Wise:RebuildIndicatorRules() -- restores IR.anyResourceRule from real data
	if not ok then
		error(err, 0)
	end
end)

test("IndicatorResource: rebuild flags whether any rule uses the metric", function()
	local function flagFor(rules)
		local savedGroups = WiseDB.groups
		local action = { type = "spell", value = 999302, indicatorRules = rules }
		WiseDB.groups = {
			FlagTest = {
				actions = {
					[1] = {
						{ type = "spell", value = 999302 },
						graph = { nodes = { { id = 1, action = action, condition = "" } }, connections = {} },
					},
				},
			},
		}
		Wise:RebuildIndicatorRules()
		local flag = IR.anyResourceRule
		WiseDB.groups = savedGroups
		Wise:RebuildIndicatorRules()
		return flag
	end
	assertTrue(flagFor({ Rule("resource", ">=", 3) }))
	assertFalse(flagFor({ Rule("charges", ">=", 1) }))
	assertFalse(flagFor({}))
end)
