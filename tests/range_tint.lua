-- Tests for the out-of-range tint (core/effects/RangeTint.lua) and its paint
-- path in Wise:UpdateButtonUsability (core/GUI.lua).
--
-- RangeTint.Pass runs one pass synchronously; the driver's OnUpdate is not
-- relied on. C_Spell.IsSpellInRange and Wise:IsSpellUsable are stubbed.

local GROUP = "__RangeTintTest"
local SPELL = 990701

local function Near(a, b)
	return math.abs(a - b) < 0.01
end

local function Color(btn)
	local r, g, b = btn.icon:GetVertexColor()
	return r, g, b
end

local function IsRed(btn)
	local r, g, b = Color(btn)
	return Near(r, 0.8) and Near(g, 0.1) and Near(b, 0.1)
end

local function IsWhite(btn)
	local r, g, b = Color(btn)
	return Near(r, 1) and Near(g, 1) and Near(b, 1)
end

local function WithRangeSetup(fn)
	local CS = C_Spell
	local savedInRange = CS.IsSpellInRange
	local savedUsable = Wise.IsSpellUsable
	local env = { inRange = false, usable = true, noMana = false }
	CS.IsSpellInRange = function()
		return env.inRange
	end
	Wise.IsSpellUsable = function()
		return env.usable, env.noMana
	end

	local settings = WiseDB.settings
	local savedTint = settings.rangeTint
	settings.rangeTint = true
	local savedGroup = WiseDB.groups[GROUP]
	WiseDB.groups[GROUP] = {}

	local btn = CreateFrame("Button", nil, UIParent)
	btn:SetSize(30, 30)
	btn.icon = btn:CreateTexture(nil, "ARTWORK")
	btn.icon:SetAllPoints()
	btn.groupName = GROUP
	Wise.buttonMeta = Wise.buttonMeta or {}
	Wise.buttonMeta[btn] = { spellID = SPELL, actionType = "spell", actionValue = SPELL }
	Wise.frames = Wise.frames or {}
	Wise.frames[GROUP] = { buttons = { btn } }

	local ok, err = pcall(fn, env, btn)

	Wise.RangeTint.Pass(false)
	Wise.frames[GROUP] = nil
	Wise.buttonMeta[btn] = nil
	WiseDB.groups[GROUP] = savedGroup
	settings.rangeTint = savedTint
	CS.IsSpellInRange = savedInRange
	Wise.IsSpellUsable = savedUsable
	if not ok then
		error(err, 0)
	end
end

test("RangeTint: out of range paints red, back in range paints white", function()
	WithRangeSetup(function(env, btn)
		Wise.RangeTint.Pass(true)
		assertTrue(btn._wiseOutOfRange == true)
		assertTrue(IsRed(btn))

		env.inRange = true
		Wise.RangeTint.Pass(true)
		assertTrue(btn._wiseOutOfRange == nil)
		assertTrue(IsWhite(btn))
	end)
end)

test("RangeTint: no range answer or an unreadable one never tints", function()
	WithRangeSetup(function(env, btn)
		env.inRange = nil -- spell without range / invalid target
		Wise.RangeTint.Pass(true)
		assertFalse(btn._wiseOutOfRange == true)
		env.inRange = {} -- a table stands in for a secret
		Wise.RangeTint.Pass(true)
		assertFalse(btn._wiseOutOfRange == true)
		assertTrue(IsWhite(btn))
	end)
end)

test("RangeTint: losing the target clears the tint", function()
	WithRangeSetup(function(env, btn)
		Wise.RangeTint.Pass(true)
		assertTrue(IsRed(btn))
		Wise.RangeTint.Pass(false)
		assertTrue(btn._wiseOutOfRange == nil)
		assertTrue(IsWhite(btn))
	end)
end)

test("RangeTint: range red wins over out-of-mana blue", function()
	WithRangeSetup(function(env, btn)
		env.usable, env.noMana = false, true
		Wise.RangeTint.Pass(true)
		assertTrue(IsRed(btn))
		env.inRange = true
		Wise.RangeTint.Pass(true)
		local r, g, b = Color(btn)
		assertTrue(Near(r, 0.5) and Near(g, 0.5) and Near(b, 1))
	end)
end)

test("RangeTint: a tinted icon that turns unusable does not stay red", function()
	WithRangeSetup(function(env, btn)
		Wise.RangeTint.Pass(true)
		assertTrue(IsRed(btn))
		env.usable, env.noMana = false, false
		Wise:UpdateButtonUsability(btn)
		assertTrue(IsWhite(btn))
		assertTrue(Near(btn.icon:GetAlpha(), 0.3))
	end)
end)

test("RangeTint: honours the global setting and the per-interface override", function()
	WithRangeSetup(function(env, btn)
		WiseDB.settings.rangeTint = false
		Wise.RangeTint.Pass(true)
		assertFalse(btn._wiseOutOfRange == true)

		WiseDB.groups[GROUP].rangeTint = true
		Wise.RangeTint.Pass(true)
		assertTrue(IsRed(btn))

		WiseDB.settings.rangeTint = true
		WiseDB.groups[GROUP].rangeTint = false
		Wise.RangeTint.Pass(true)
		assertFalse(btn._wiseOutOfRange == true)
		assertTrue(IsWhite(btn))
	end)
end)

test("RangeTint: the driver runs only while a target exists", function()
	WithRangeSetup(function(env, btn)
		local savedExists = _G.UnitExists
		local hasTarget = true
		_G.UnitExists = function()
			return hasTarget
		end
		local ok, err = pcall(function()
			Wise:RefreshRangeTint()
			assertTrue(Wise.RangeTint.IsRunning())
			assertTrue(IsRed(btn))
			hasTarget = false
			Wise:RefreshRangeTint()
			assertFalse(Wise.RangeTint.IsRunning())
			assertTrue(IsWhite(btn))
		end)
		_G.UnitExists = savedExists
		Wise:RefreshRangeTint()
		if not ok then
			error(err, 0)
		end
	end)
end)
