-- Tests for the Assisted Combat suggestion glow (core/effects/AssistGlow.lua)
-- and the keyed LibCustomGlow wrapper under it (core/effects/StyledGlow.lua).
--
-- The driver's OnUpdate is never relied on here: Wise.AssistGlow.Refresh runs
-- one pass synchronously. C_AssistedCombat is stubbed field by field (the sim
-- ignores a replaced C_* namespace); if the sim lacks the namespace entirely it
-- is created for the test and removed afterwards.

local SUGGESTED, OTHER, BASE_ONLY, OVERRIDE_OF_BASE = 990501, 990502, 990503, 990601
local GROUP = "__AssistGlowTest"
local KEY = "WiseAssist"

-- Build two (or three) buttons in a test interface, run fn with a controllable
-- suggestion, then restore every global and table the test touched.
local function WithAssistSetup(fn)
	local createdNS = _G.C_AssistedCombat == nil
	local AC = _G.C_AssistedCombat or {}
	if createdNS then
		_G.C_AssistedCombat = AC
	end
	local savedNext, savedAvail = AC.GetNextCastSpell, AC.IsAvailable
	local env = { suggestion = SUGGESTED, available = true }
	AC.GetNextCastSpell = function()
		return env.suggestion
	end
	AC.IsAvailable = function()
		return env.available, ""
	end

	local settings = WiseDB.settings
	local savedShow, savedStyle = settings.showAssistGlow, settings.assistGlowStyle
	settings.showAssistGlow = true
	settings.assistGlowStyle = "pixel"
	local savedGroup = WiseDB.groups[GROUP]
	WiseDB.groups[GROUP] = {}

	local function MakeButton(spellID, baseSpellID)
		local b = CreateFrame("Button", nil, UIParent)
		b:SetSize(30, 30)
		b.groupName = GROUP
		Wise.buttonMeta = Wise.buttonMeta or {}
		Wise.buttonMeta[b] = { spellID = spellID, baseSpellID = baseSpellID or spellID, actionType = "spell" }
		return b
	end
	local a = MakeButton(SUGGESTED)
	local b = MakeButton(OTHER)
	local c = MakeButton(OVERRIDE_OF_BASE, BASE_ONLY)

	local ok, err = pcall(fn, env, a, b, c)

	Wise.AssistGlow.ClearAll()
	for _, btn in ipairs({ a, b, c }) do
		Wise:HideOverlayGlow(btn, "proc")
		Wise.buttonMeta[btn] = nil
	end
	WiseDB.groups[GROUP] = savedGroup
	settings.showAssistGlow, settings.assistGlowStyle = savedShow, savedStyle
	AC.GetNextCastSpell, AC.IsAvailable = savedNext, savedAvail
	if createdNS then
		_G.C_AssistedCombat = nil
	end
	if not ok then
		error(err, 0)
	end
end

test("AssistGlow: lights exactly the buttons holding the suggested spell", function()
	WithAssistSetup(function(env, a, b)
		Wise.AssistGlow.Refresh(false)
		assertTrue(Wise.AssistGlow.IsLit(a))
		assertFalse(Wise.AssistGlow.IsLit(b))
		-- The real LibCustomGlow pixel frame is attached under our key.
		assertTrue(a["_PixelGlow" .. KEY] ~= nil)
		assertEquals("pixel", a.__WiseStyledGlows[KEY])

		-- The suggestion moves: the glow follows it.
		env.suggestion = OTHER
		Wise.AssistGlow.Refresh(false)
		assertFalse(Wise.AssistGlow.IsLit(a))
		assertTrue(Wise.AssistGlow.IsLit(b))
		assertEquals(nil, a.__WiseStyledGlows[KEY])

		-- No suggestion: nothing glows.
		env.suggestion = nil
		Wise.AssistGlow.Refresh(false)
		assertFalse(Wise.AssistGlow.IsLit(a))
		assertFalse(Wise.AssistGlow.IsLit(b))
	end)
end)

test("AssistGlow: an unreadable suggestion lights nothing", function()
	WithAssistSetup(function(env, a, b)
		-- A table stands in for a secret: not a readable spell id.
		env.suggestion = {}
		Wise.AssistGlow.Refresh(false)
		assertFalse(Wise.AssistGlow.IsLit(a))
		assertFalse(Wise.AssistGlow.IsLit(b))
	end)
end)

test("AssistGlow: a button holding the base spell matches the suggestion", function()
	WithAssistSetup(function(env, a, b, c)
		env.suggestion = BASE_ONLY
		Wise.AssistGlow.Refresh(false)
		assertTrue(Wise.AssistGlow.IsLit(c))
		assertFalse(Wise.AssistGlow.IsLit(a))
	end)
end)

test("AssistGlow: honours the global setting and the per-interface override", function()
	WithAssistSetup(function(env, a)
		WiseDB.settings.showAssistGlow = false
		Wise.AssistGlow.Refresh(false)
		assertFalse(Wise.AssistGlow.IsLit(a))

		-- Off globally, on for this interface.
		WiseDB.groups[GROUP].showAssistGlow = true
		Wise.AssistGlow.Refresh(false)
		assertTrue(Wise.AssistGlow.IsLit(a))

		-- On globally, off for this interface.
		WiseDB.settings.showAssistGlow = true
		WiseDB.groups[GROUP].showAssistGlow = false
		Wise.AssistGlow.Refresh(false)
		assertFalse(Wise.AssistGlow.IsLit(a))
	end)
end)

test("AssistGlow: a style change restyles a button that stays lit", function()
	WithAssistSetup(function(env, a)
		Wise.AssistGlow.Refresh(false)
		assertEquals("pixel", a.__WiseStyledGlows[KEY])
		WiseDB.settings.assistGlowStyle = "autocast"
		Wise.AssistGlow.Refresh(true)
		assertEquals("autocast", a.__WiseStyledGlows[KEY])
		assertTrue(a["_AutoCastGlow" .. KEY] ~= nil)
	end)
end)

test("AssistGlow: never tears down a proc glow on the same button", function()
	WithAssistSetup(function(env, a)
		Wise:ShowOverlayGlow(a, nil, "proc")
		Wise.AssistGlow.Refresh(false)
		assertTrue(Wise.AssistGlow.IsLit(a))
		env.suggestion = OTHER
		Wise.AssistGlow.Refresh(false)
		assertFalse(Wise.AssistGlow.IsLit(a))
		-- The proc overlay belongs to another driver and must survive.
		assertTrue(a.__WiseOverlay ~= nil)
	end)
end)

test("AssistGlow: the driver idles when Assisted Combat is unavailable or the player is idle", function()
	WithAssistSetup(function(env, a)
		local savedICL, savedExists, savedCanAttack = _G.InCombatLockdown, _G.UnitExists, _G.UnitCanAttack
		local inCombat, hasTarget = true, false
		_G.InCombatLockdown = function()
			return inCombat
		end
		_G.UnitExists = function()
			return hasTarget
		end
		_G.UnitCanAttack = function()
			return hasTarget
		end
		local ok, err = pcall(function()
			Wise:RefreshAssistGlow(false)
			assertTrue(Wise.AssistGlow.IsRunning())
			assertTrue(Wise.AssistGlow.IsLit(a))

			-- Spec without Assisted Combat: stop and clear.
			env.available = false
			Wise:RefreshAssistGlow(false)
			assertFalse(Wise.AssistGlow.IsRunning())
			assertFalse(Wise.AssistGlow.IsLit(a))

			-- Available, but out of combat with no target: stay idle.
			env.available = true
			inCombat = false
			Wise:RefreshAssistGlow(false)
			assertFalse(Wise.AssistGlow.IsRunning())

			-- An attackable target wakes it out of combat.
			hasTarget = true
			Wise:RefreshAssistGlow(false)
			assertTrue(Wise.AssistGlow.IsRunning())
		end)
		_G.InCombatLockdown, _G.UnitExists, _G.UnitCanAttack = savedICL, savedExists, savedCanAttack
		Wise:RefreshAssistGlow(false) -- back to the real (idle) gate
		if not ok then
			error(err, 0)
		end
	end)
end)
