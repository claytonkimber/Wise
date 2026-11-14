-- Regression tests for 12.x cooldown and charge secrecy (2026-11-13).
--
-- Blizzard's API docs (12.1.5) let a cooldown's startTime/duration and a spell's
-- currentCharges be secret, while isActive/isOnGCD (cooldowns) and
-- maxCharges/isActive (charges) are never secret. Before the fix:
--   * Wise:IsActionOnCooldown compared the times inside a pcall; a secret made
--     the comparison throw and the spell read "off cooldown".
--   * the indicator engine turned a hidden charge count into 0, so a
--     "charges <= N" rule lit for the whole fight.
--   * "available" ignored the cooldown whenever IsSpellUsable answered.
--
-- The sim has no real secret values, so a TABLE stands in for one. Like a
-- secret it throws on comparison and arithmetic (which is how the old pcall'd
-- code failed), and the secret-safe readers turn it into nil ("unknown").

local HIDDEN = {}
local GCD_SPELL_ID = 61304

local IDLE_GCD = { startTime = 0, duration = 0, isEnabled = true, isActive = false, isOnGCD = false }
local BUSY_GCD = { startTime = HIDDEN, duration = HIDDEN, isEnabled = true, isActive = true, isOnGCD = true }
local IDLE_CD = { startTime = 0, duration = 0, isEnabled = true, isActive = false, isOnGCD = false }

-- Hidden times; the flags say "its own cooldown is running".
local function OwnCooldown(onGCD)
	return { startTime = HIDDEN, duration = HIDDEN, isEnabled = true, isActive = true, isOnGCD = onGCD }
end

-- Run fn with C_Spell.GetSpellCooldown answering `gcd` for the GCD spell and
-- `spell` for everything else. Patches the field on the existing table (the sim
-- ignores a replaced C_* namespace) and restores it even if fn throws.
local function WithCooldowns(spell, gcd, fn)
	local CS = C_Spell
	local saved = CS.GetSpellCooldown
	CS.GetSpellCooldown = function(id)
		if id == GCD_SPELL_ID then
			return gcd
		end
		return spell
	end
	local ok, a, b = pcall(fn)
	CS.GetSpellCooldown = saved
	if not ok then
		error(a, 0)
	end
	return a, b
end

local function SpellCD(spell, gcd)
	return WithCooldowns(spell, gcd, function()
		return Wise:IsActionOnCooldown("spell", 999101)
	end)
end

test("IsActionOnCooldown: hidden times fall back to the never-secret flags", function()
	-- Own cooldown, no GCD running. The old code answered "off cooldown" here.
	local onCD, known = SpellCD(OwnCooldown(false), IDLE_GCD)
	assertTrue(onCD)
	assertTrue(known)

	-- Own cooldown while a GCD also runs: the spell's isOnGCD=false decides.
	onCD, known = SpellCD(OwnCooldown(false), BUSY_GCD)
	assertTrue(onCD)
	assertTrue(known)

	-- Only the GCD is running: not "on cooldown", same as the timed path.
	onCD, known = SpellCD(OwnCooldown(true), BUSY_GCD)
	assertFalse(onCD)
	assertTrue(known)

	-- A stale isOnGCD=true after the GCD ended: the GCD's own flag wins.
	onCD, known = SpellCD(OwnCooldown(true), IDLE_GCD)
	assertTrue(onCD)
	assertTrue(known)

	-- Nothing running at all.
	onCD, known = SpellCD({ startTime = HIDDEN, duration = HIDDEN, isEnabled = true, isActive = false }, BUSY_GCD)
	assertFalse(onCD)
	assertTrue(known)

	-- Times AND flags hidden: unknown, keeping the old false default.
	onCD, known = SpellCD({ startTime = HIDDEN, duration = HIDDEN, isActive = HIDDEN, isOnGCD = HIDDEN }, BUSY_GCD)
	assertFalse(onCD)
	assertFalse(known)
end)

test("IsActionOnCooldown: readable times behave exactly as before", function()
	local now = GetTime()
	-- 29s left on a 30s cooldown.
	local onCD, known = SpellCD({ startTime = now - 1, duration = 30, isActive = true, isOnGCD = false }, IDLE_GCD)
	assertTrue(onCD)
	assertTrue(known)
	-- A GCD-length cooldown is ignored.
	onCD = SpellCD({ startTime = now, duration = 1.5, isActive = true, isOnGCD = true }, IDLE_GCD)
	assertFalse(onCD)
	-- The last second of a long cooldown is ignored too (<= 1.5s remaining).
	onCD = SpellCD({ startTime = now - 29, duration = 30, isActive = true, isOnGCD = false }, IDLE_GCD)
	assertFalse(onCD)
end)

test("IsActionOnCooldown: hidden item cooldown is unknown, readable one unchanged", function()
	local CI = C_Item
	local saved = CI.GetItemCooldown
	local start, duration = HIDDEN, HIDDEN
	CI.GetItemCooldown = function()
		return start, duration, 1
	end
	local ok, err = pcall(function()
		local onCD, known = Wise:IsActionOnCooldown("item", 999102)
		assertFalse(onCD)
		assertFalse(known)
		start, duration = GetTime() - 1, 60
		onCD, known = Wise:IsActionOnCooldown("toy", 999102)
		assertTrue(onCD)
		assertTrue(known)
	end)
	CI.GetItemCooldown = saved
	if not ok then
		error(err, 0)
	end
end)

-- Build a one-slot indicator setup for `rule`, stub the spell's live state, run
-- one indicator pass and report whether the rule's border showed.
-- stubs: { charges = SpellChargeInfo|nil, cooldown = SpellCooldownInfo, gcd = ..., usable = bool }
local function BorderShownFor(rule, stubs)
	local CAST_ID = 999201
	local CS = C_Spell
	local savedCharges, savedCD, savedUsable = CS.GetSpellCharges, CS.GetSpellCooldown, CS.IsSpellUsable
	local savedKnown = Wise.IsActionKnown
	CS.GetSpellCharges = function()
		return stubs.charges
	end
	CS.GetSpellCooldown = function(id)
		if id == GCD_SPELL_ID then
			return stubs.gcd or IDLE_GCD
		end
		return stubs.cooldown or IDLE_CD
	end
	CS.IsSpellUsable = function()
		return stubs.usable ~= false
	end
	-- A synthetic spell id is not known to the sim; "available" needs known=true.
	Wise.IsActionKnown = function()
		return true
	end

	local savedGroups = WiseDB.groups
	local action = { type = "spell", value = CAST_ID, name = "Wise Secret CD Test", indicatorRules = { rule } }
	WiseDB.groups = {
		SecretCDTest = {
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
		states = WiseDB.groups.SecretCDTest.actions[1],
	}
	Wise.frames = Wise.frames or {}
	Wise.frames["__SecretCDTest"] = { buttons = { btn } }

	local ok, err = pcall(function()
		Wise:RebuildIndicatorRules()
		Wise:UpdateIndicatorRules()
	end)
	local shown = btn.indicatorBorder ~= nil and btn.indicatorBorder:IsShown()

	Wise.frames["__SecretCDTest"] = nil
	Wise.buttonMeta[btn] = nil
	WiseDB.groups = savedGroups
	CS.GetSpellCharges, CS.GetSpellCooldown, CS.IsSpellUsable = savedCharges, savedCD, savedUsable
	Wise.IsActionKnown = savedKnown
	Wise:RebuildIndicatorRules()
	if not ok then
		error(err, 0)
	end
	return shown
end

local function Rule(metric, operator, value)
	return { metric = metric, operator = operator, value = value, color = "Red", glow = false }
end

test("IndicatorRules: a hidden charge count is unknown, never 0", function()
	-- Recharging with a hidden count. The old code read 0 and lit "<= 0" all fight.
	assertFalse(BorderShownFor(Rule("charges", "<=", 0), {
		charges = { currentCharges = HIDDEN, maxCharges = 2, isActive = true },
	}))
	-- No recharge running means full charges, even with the count hidden.
	assertTrue(BorderShownFor(Rule("charges", ">=", 2), {
		charges = { currentCharges = HIDDEN, maxCharges = 2, isActive = false },
	}))
	-- A readable count still works as before.
	assertTrue(BorderShownFor(Rule("charges", "=", 1), {
		charges = { currentCharges = 1, maxCharges = 2, isActive = true },
	}))
end)

test("IndicatorRules: cooldown metrics read the never-secret flags", function()
	-- Own cooldown with hidden times: "On cooldown" must fire (it never did before)...
	assertTrue(BorderShownFor(Rule("cooldown"), { cooldown = OwnCooldown(false) }))
	-- ...and "Available (off CD)" must not, even though IsSpellUsable says yes.
	assertFalse(BorderShownFor(Rule("available"), { cooldown = OwnCooldown(false), usable = true }))
	-- Off cooldown and usable: "available" still fires.
	assertTrue(BorderShownFor(Rule("available"), { cooldown = IDLE_CD, usable = true }))
	-- Everything hidden: neither rule may guess.
	local blind = { startTime = HIDDEN, duration = HIDDEN, isActive = HIDDEN, isOnGCD = HIDDEN }
	assertFalse(BorderShownFor(Rule("cooldown"), { cooldown = blind, gcd = BUSY_GCD }))
	assertFalse(BorderShownFor(Rule("available"), { cooldown = blind, gcd = BUSY_GCD }))
end)
