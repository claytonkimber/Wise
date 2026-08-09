-- Tests for the 12.1 compatibility layer (core/Compat121.lua).
--
-- The sim runs a 12.0.7 client, so the 12.1 intrinsics are genuinely ABSENT
-- here. That makes this suite primarily a guarantee that Wise degrades cleanly
-- on 12.0.x — the case that must never regress, since it is what everyone is
-- running until the patch lands. The 12.1-present paths are exercised by
-- stubbing the capability flags, which is honest about what is being tested:
-- the wrapper's own logic, not the client's implementation of AddAuraSlot.

test("Compat: capability flags are booleans, never nil", function()
	assertNotNil(Wise.Compat)
	-- A nil flag would sail through `if Compat.hasX then` for the wrong reason
	-- (typo'd field name reads as "unsupported"), so pin the type.
	assertType("boolean", Wise.Compat.hasAuraWidgets)
	assertType("boolean", Wise.Compat.hasOnUpdateMode)
	assertType("boolean", Wise.Compat.hasSecretPrimitives)
	assertType("boolean", Wise.Compat.hasSecretsQuery)
end)

test("Compat: aura widgets unavailable on a 12.0.x client", function()
	-- The probe must report false rather than throwing when the intrinsic
	-- template does not exist.
	assertFalse(Wise.Compat.hasAuraWidgets)
	assertFalse(Wise.Compat.CanUseAuraWidgets())
end)

test("Compat: CreateStackCounter returns nil instead of erroring pre-12.1", function()
	local parent = CreateFrame("Frame", "WiseCompatCounterParent", UIParent)
	-- Must be nil, not a half-built frame: callers branch on the return.
	assertEquals(nil, Wise.Compat.CreateStackCounter(parent, 207640))
	-- Bad input is equally non-fatal.
	assertEquals(nil, Wise.Compat.CreateStackCounter(nil, 207640))
	assertEquals(nil, Wise.Compat.CreateStackCounter(parent, nil))
end)

test("Compat: CreateStackCounter refuses to build in combat even when supported", function()
	-- AuraButtons carry Forbidden Aspects while auras are secret, so creation
	-- must be gated on combat, not merely on capability. Simulate a 12.1 client
	-- to prove the combat gate is what stops it.
	local savedFlag = Wise.Compat.hasAuraWidgets
	local savedICL = _G.InCombatLockdown
	Wise.Compat.hasAuraWidgets = true
	_G.InCombatLockdown = function()
		return true
	end

	local canUse = Wise.Compat.CanUseAuraWidgets()
	local parent = CreateFrame("Frame", "WiseCompatCombatParent", UIParent)
	local built = Wise.Compat.CreateStackCounter(parent, 207640)

	Wise.Compat.hasAuraWidgets = savedFlag
	_G.InCombatLockdown = savedICL

	assertFalse(canUse)
	assertEquals(nil, built)
end)

test("Compat: AreAurasSecret falls back to combat state without C_Secrets", function()
	local savedQuery = Wise.Compat.hasSecretsQuery
	local savedICL = _G.InCombatLockdown
	Wise.Compat.hasSecretsQuery = false

	_G.InCombatLockdown = function()
		return false
	end
	local outOfCombat = Wise.Compat.AreAurasSecret()
	_G.InCombatLockdown = function()
		return true
	end
	local inCombat = Wise.Compat.AreAurasSecret()

	Wise.Compat.hasSecretsQuery = savedQuery
	_G.InCombatLockdown = savedICL

	-- Conservative fallback: assume secrecy in combat rather than trusting reads.
	assertFalse(outOfCombat)
	assertTrue(inCombat)
end)

test("Compat: AreAurasSecret prefers the client's own answer when available", function()
	local savedQuery = Wise.Compat.hasSecretsQuery
	local savedSecrets = _G.C_Secrets
	local savedICL = _G.InCombatLockdown

	-- Out of combat, but the client says auras ARE secret. The client wins:
	-- deferring to InCombatLockdown here would wrongly trust aura reads.
	_G.C_Secrets = {
		ShouldAurasBeSecret = function()
			return true
		end,
	}
	Wise.Compat.hasSecretsQuery = true
	_G.InCombatLockdown = function()
		return false
	end

	local result = Wise.Compat.AreAurasSecret()

	Wise.Compat.hasSecretsQuery = savedQuery
	_G.C_Secrets = savedSecrets
	_G.InCombatLockdown = savedICL

	assertTrue(result)
end)

test("Compat: SetOnUpdateWhenVisible is a safe no-op pre-12.1", function()
	local f = CreateFrame("Frame", "WiseCompatOnUpdateFrame", UIParent)
	-- Returns false (not applied) rather than erroring, and never nil.
	assertEquals(false, Wise.Compat.SetOnUpdateWhenVisible(f))
	assertEquals(false, Wise.Compat.SetOnUpdateWhenVisible(nil))
end)

test("Compat: GetReport exposes live secrecy state for /wise compat", function()
	local r = Wise.Compat.GetReport()
	assertType("table", r)
	assertType("boolean", r.auraWidgets)
	assertType("boolean", r.onUpdateMode)
	assertType("boolean", r.aurasSecretNow)
end)
