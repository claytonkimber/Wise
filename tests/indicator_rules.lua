-- Regression test for IndicatorRules button matching on multi-state slots.
--
-- A slot configurator graph like AtMouse compiles into SEVERAL custom_macro
-- states (e.g. "[combat] Survival Instincts" + "Abundance"). The button shows
-- one state at a time, and entering combat flips meta.actionData to the combat
-- step — whose macro text does not mention the ruled spell. The indicator must
-- still bind via the slot's OTHER states, or stack tracking vanishes in combat.

test("IndicatorRules: indicator stays bound when a sibling state is active", function()
	if not _G.C_UnitAuras then
		_G.C_UnitAuras = {}
	end
	if not _G.C_UnitAuras.GetPlayerAuraBySpellID then
		_G.C_UnitAuras.GetPlayerAuraBySpellID = function()
			return nil
		end
	end

	local savedGroups = WiseDB.groups
	local abundanceAction = {
		type = "spell",
		value = 207383,
		name = "Abundance",
		-- stacks <= 99 always matches (stacks read 0 in the sim), so a bound
		-- indicator shows its border; an unbound one is cleared.
		indicatorRules = { { operator = "<=", value = 99, color = "Red", glow = false } },
	}
	WiseDB.groups = {
		IndicatorTest = {
			actions = {
				[1] = {
					{
						type = "misc",
						value = "custom_macro",
						macroText = "#showtooltip\n/cast [combat] Survival Instincts",
						conditions = "[combat]",
					},
					{
						type = "misc",
						value = "custom_macro",
						macroText = "#showtooltip\n/cast Abundance",
					},
					graph = {
						nodes = {
							{ id = 1, action = { type = "spell", value = 61336 }, condition = "[combat]" },
							{ id = 2, action = abundanceAction, condition = "" },
						},
						connections = {},
					},
				},
			},
		},
	}
	Wise:RebuildIndicatorRules()

	-- Simulate the in-combat button: the ACTIVE state is the Survival Instincts
	-- step; the Abundance step is a sibling in meta.states.
	local btn = CreateFrame("Button", "WiseIndicatorRuleTestBtn", UIParent)
	btn:SetSize(30, 30)
	local states = WiseDB.groups.IndicatorTest.actions[1]
	Wise.buttonMeta = Wise.buttonMeta or {}
	Wise.buttonMeta[btn] = {
		actionType = "misc",
		actionValue = "custom_macro",
		actionData = states[1],
		states = states,
		activeState = 1,
	}
	Wise.frames = Wise.frames or {}
	Wise.frames["__IndicatorRuleTest"] = { buttons = { btn } }

	Wise:UpdateIndicatorRules()

	local bound = btn.indicatorBorder ~= nil and btn.indicatorBorder:IsShown()

	-- Cleanup before asserting so a failure doesn't leak test state.
	Wise.frames["__IndicatorRuleTest"] = nil
	Wise.buttonMeta[btn] = nil
	WiseDB.groups = savedGroups
	Wise:RebuildIndicatorRules()

	assertTrue(bound)
end)

-- A spell whose buff has a different id than the cast (Abundance: cast 207383,
-- buff 207640) must resolve stacks by the buff's aura id: learned from the first
-- successful lookup (persisted as action.trackedAuraID), or from the known-id
-- seed table — the name path is only a last resort. NOTE (2026-07-05 live probe):
-- in COMBAT 12.0.7 blocks ALL of these reads for rotational auras, id included;
-- that path is covered by the hidden-aura tests below. This test covers the
-- learned-id mechanism itself (restores the counter out of combat).
test("IndicatorRules: stacks resolve by learned aura id when name lookup fails", function()
	local CAST_ID, AURA_ID = 999001, 999002
	local auraData = { applications = 5, spellId = AURA_ID, name = "Wise Test Buff" }

	-- Patch FIELDS on the existing C_UnitAuras table: the sim resolves the C_*
	-- namespaces through its API registry, so replacing the table via _G does
	-- not change what addon code sees (same gotcha as frame globals).
	local CU = _G.C_UnitAuras or {}
	_G.C_UnitAuras = CU
	local savedByID = CU.GetPlayerAuraBySpellID
	local savedByName = CU.GetAuraDataBySpellName
	local namePathAlive = true
	CU.GetPlayerAuraBySpellID = function(id)
		if id == AURA_ID then
			return auraData
		end
		return nil
	end
	CU.GetAuraDataBySpellName = function(unit, name)
		if namePathAlive and unit == "player" and name == "Wise Test Buff" then
			return auraData
		end
		return nil
	end

	local savedGroups = WiseDB.groups
	local action = {
		type = "spell",
		value = CAST_ID,
		name = "Wise Test Buff",
		indicatorRules = { { operator = ">=", value = 1, color = "Green", glow = false } },
	}
	WiseDB.groups = {
		AuraIdTest = {
			actions = {
				[1] = {
					{ type = "spell", value = CAST_ID },
					graph = {
						nodes = { { id = 1, action = action, condition = "" } },
						connections = {},
					},
				},
			},
		},
	}

	-- Out of combat: the name path works once, and the aura id gets learned.
	Wise:RebuildIndicatorRules()
	Wise:UpdateIndicatorRules()
	local learnedID = action.trackedAuraID

	-- "Enter combat": the name path goes dark. Stacks must still resolve via the
	-- learned id and reach the button's counter.
	namePathAlive = false
	local btn = CreateFrame("Button", "WiseAuraIdTestBtn", UIParent)
	btn:SetSize(30, 30)
	Wise.buttonMeta = Wise.buttonMeta or {}
	Wise.buttonMeta[btn] = {
		actionType = "spell",
		actionValue = CAST_ID,
		baseSpellID = CAST_ID,
		spellID = CAST_ID,
		states = WiseDB.groups.AuraIdTest.actions[1],
	}
	Wise.frames = Wise.frames or {}
	Wise.frames["__AuraIdTest"] = { buttons = { btn } }

	Wise:UpdateIndicatorRules()

	local countShown = btn.indicatorCount ~= nil and btn.indicatorCount:IsShown()
	local countText = btn.indicatorCount and btn.indicatorCount:GetText()

	Wise.frames["__AuraIdTest"] = nil
	Wise.buttonMeta[btn] = nil
	WiseDB.groups = savedGroups
	CU.GetPlayerAuraBySpellID = savedByID
	CU.GetAuraDataBySpellName = savedByName
	Wise:RebuildIndicatorRules()

	assertEquals(AURA_ID, learnedID)
	assertTrue(countShown)
	assertEquals("5", countText)
end)

-- 12.0.7 hides rotationally-relevant player auras from EVERY C_UnitAuras read in
-- combat (live probe 2026-07-05: byAura/byCast/byName all nil, aura absent from
-- enumeration, with 12 Abundance stacks up). "Hidden" is indistinguishable from
-- "not applied", so a failed in-combat read must be treated as UNKNOWN — the old
-- behavior read stacks as 0 and lit the "<=2 Red" rule for the entire fight.
test("IndicatorRules: hidden in-combat aura matches no stack rule (no false red)", function()
	local CAST_ID = 999011
	local CU = _G.C_UnitAuras or {}
	_G.C_UnitAuras = CU
	local savedByID = CU.GetPlayerAuraBySpellID
	local savedByName = CU.GetAuraDataBySpellName
	local savedICL = _G.InCombatLockdown
	CU.GetPlayerAuraBySpellID = function()
		return nil
	end
	CU.GetAuraDataBySpellName = function()
		return nil
	end
	_G.InCombatLockdown = function()
		return true
	end

	local savedGroups = WiseDB.groups
	local action = {
		type = "spell",
		value = CAST_ID,
		name = "Wise Hidden Buff",
		indicatorRules = { { operator = "<=", value = 2, color = "Red", glow = false } },
	}
	WiseDB.groups = {
		HiddenAuraTest = {
			actions = {
				[1] = {
					{ type = "spell", value = CAST_ID },
					graph = {
						nodes = { { id = 1, action = action, condition = "" } },
						connections = {},
					},
				},
			},
		},
	}
	Wise:RebuildIndicatorRules()

	local btn = CreateFrame("Button", "WiseHiddenAuraTestBtn", UIParent)
	btn:SetSize(30, 30)
	Wise.buttonMeta = Wise.buttonMeta or {}
	Wise.buttonMeta[btn] = {
		actionType = "spell",
		actionValue = CAST_ID,
		baseSpellID = CAST_ID,
		spellID = CAST_ID,
		states = WiseDB.groups.HiddenAuraTest.actions[1],
	}
	Wise.frames = Wise.frames or {}
	Wise.frames["__HiddenAuraTest"] = { buttons = { btn } }

	Wise:UpdateIndicatorRules()

	local borderShown = btn.indicatorBorder ~= nil and btn.indicatorBorder:IsShown()

	Wise.frames["__HiddenAuraTest"] = nil
	Wise.buttonMeta[btn] = nil
	WiseDB.groups = savedGroups
	CU.GetPlayerAuraBySpellID = savedByID
	CU.GetAuraDataBySpellName = savedByName
	_G.InCombatLockdown = savedICL
	Wise:RebuildIndicatorRules()

	-- Out of combat a 0-stack read WOULD legitimately match <=2; hidden-in-combat
	-- must not.
	assertTrue(not borderShown)
end)

-- Sanctioned in-combat path: with the auraInstanceID learned while the buff was
-- visible (prehot before the pull), the counter and >=N thresholds are driven by
-- GetAuraApplicationDisplayCount — its string goes straight into SetText, and its
-- minDisplayCount nil/non-nil return answers threshold questions (validated by an
-- impossible min=999 probe first).
test("IndicatorRules: hidden in-combat aura counts + matches via display-count API", function()
	local CAST_ID, AURA_ID, INST_ID, LIVE_STACKS = 999021, 999022, 4242, 12
	local CU = _G.C_UnitAuras or {}
	_G.C_UnitAuras = CU
	local savedByID = CU.GetPlayerAuraBySpellID
	local savedByName = CU.GetAuraDataBySpellName
	local savedByInst = CU.GetAuraDataByAuraInstanceID
	local savedDC = CU.GetAuraApplicationDisplayCount
	local savedICL = _G.InCombatLockdown
	local inCombat = false
	local auraData = { applications = LIVE_STACKS, spellId = AURA_ID, auraInstanceID = INST_ID }
	CU.GetPlayerAuraBySpellID = function(id)
		if not inCombat and id == AURA_ID then
			return auraData
		end
		return nil
	end
	CU.GetAuraDataBySpellName = function(unit, name)
		if not inCombat and name == "Wise Prehot Buff" then
			return auraData
		end
		return nil
	end
	CU.GetAuraDataByAuraInstanceID = function()
		return nil -- data read blocked in combat too; only the display API answers
	end
	CU.GetAuraApplicationDisplayCount = function(unit, instID, minCount)
		if instID ~= INST_ID then
			return nil
		end
		if (minCount or 1) <= LIVE_STACKS then
			return tostring(LIVE_STACKS)
		end
		return nil
	end
	_G.InCombatLockdown = function()
		return inCombat
	end

	local savedGroups = WiseDB.groups
	local action = {
		type = "spell",
		value = CAST_ID,
		name = "Wise Prehot Buff",
		indicatorRules = {
			{ operator = "<=", value = 2, color = "Red", glow = false },
			{ operator = ">=", value = 8, color = "White", glow = false },
		},
	}
	WiseDB.groups = {
		PrehotTest = {
			actions = {
				[1] = {
					{ type = "spell", value = CAST_ID },
					graph = {
						nodes = { { id = 1, action = action, condition = "" } },
						connections = {},
					},
				},
			},
		},
	}

	local btn = CreateFrame("Button", "WisePrehotTestBtn", UIParent)
	btn:SetSize(30, 30)
	Wise.buttonMeta = Wise.buttonMeta or {}
	Wise.buttonMeta[btn] = {
		actionType = "spell",
		actionValue = CAST_ID,
		baseSpellID = CAST_ID,
		spellID = CAST_ID,
		states = WiseDB.groups.PrehotTest.actions[1],
	}
	Wise.frames = Wise.frames or {}
	Wise.frames["__PrehotTest"] = { buttons = { btn } }

	-- Prehot: one out-of-combat pass learns trackedAuraID AND the instance handle.
	Wise:RebuildIndicatorRules()
	Wise:UpdateIndicatorRules()

	-- Pull: every direct read goes dark; only the display-count API still answers.
	inCombat = true
	Wise:UpdateIndicatorRules()

	local countShown = btn.indicatorCount ~= nil and btn.indicatorCount:IsShown()
	local countText = btn.indicatorCount and btn.indicatorCount:GetText()
	local borderShown = btn.indicatorBorder ~= nil and btn.indicatorBorder:IsShown()
	local borderG = nil
	if borderShown then
		local _, g = btn.indicatorBorder:GetVertexColor()
		borderG = g
	end

	Wise.frames["__PrehotTest"] = nil
	Wise.buttonMeta[btn] = nil
	WiseDB.groups = savedGroups
	CU.GetPlayerAuraBySpellID = savedByID
	CU.GetAuraDataBySpellName = savedByName
	CU.GetAuraDataByAuraInstanceID = savedByInst
	CU.GetAuraApplicationDisplayCount = savedDC
	_G.InCombatLockdown = savedICL
	Wise:RebuildIndicatorRules()

	assertTrue(countShown)
	assertEquals(tostring(LIVE_STACKS), countText)
	-- The >=8 White rule must win (12 stacks) — not the <=2 Red one.
	-- White = (1,1,1); Red = (1,0,0) — the green channel tells them apart.
	assertTrue(borderShown)
	assertEquals(1, borderG)
end)
