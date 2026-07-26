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
		-- charges <= 99 always matches (charges read 0 in the sim), so a bound
		-- indicator shows its border; an unbound one is cleared. Uses charges
		-- rather than stacks: "Aura stacks" was withdrawn as a metric because it
		-- cannot be evaluated under combat secrecy.
		indicatorRules = {
			{ metric = "charges", operator = "<=", value = 99, color = "Red", glow = false },
		},
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
-- buff 207640) must resolve its aura by the BUFF's id: learned from the first
-- successful lookup (persisted as action.trackedAuraID), or from the known-id
-- seed table — the name path is only a last resort. This drives the COUNT
-- display, which is the one piece of stack feedback that still works; stack
-- THRESHOLDS were withdrawn as a metric (unevaluatable under combat secrecy).
test("IndicatorRules: aura resolves by learned buff id when name lookup fails", function()
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
		indicatorRules = {
			{ metric = "buff_active", color = "Green", glow = false },
		},
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

-- "Aura stacks" has been withdrawn as an offerable metric: under 12.0.7 combat
-- secrecy a stack count can be displayed but never branched on, so a stacks rule
-- was silently inert exactly when it mattered (in a raid). Guard the removal --
-- any rule still carrying metric="stacks", and any legacy rule with NO metric
-- field, must not colour the button off a stale stack comparison.
test("IndicatorRules: withdrawn stacks metric never colours the button", function()
	local CAST_ID = 999011
	local CU = _G.C_UnitAuras or {}
	_G.C_UnitAuras = CU
	local savedByID = CU.GetPlayerAuraBySpellID
	local savedByName = CU.GetAuraDataBySpellName
	-- A live, readable 5-stack aura: out of combat the OLD code would happily
	-- match "<=99" here and light the border. It must not any more.
	local auraData = { applications = 5, spellId = CAST_ID, name = "Wise Stack Buff" }
	CU.GetPlayerAuraBySpellID = function() return auraData end
	CU.GetAuraDataBySpellName = function() return auraData end

	-- Force "available" TRUE. Without this the sim reports the spell unusable, so
	-- a retired rule falling through to the default metric would fail to match
	-- anyway and the test would pass for the wrong reason — it must fail loudly
	-- if the inert-rule guard is ever removed.
	local CS = _G.C_Spell or {}
	_G.C_Spell = CS
	local savedUsable = CS.IsSpellUsable
	local savedCD = CS.GetSpellCooldown
	CS.IsSpellUsable = function() return true end
	CS.GetSpellCooldown = function() return { startTime = 0, duration = 0 } end
	-- `available` is gated on `known` too, and a synthetic spell id is not known
	-- to the sim — without this the fallback still could not match.
	local savedKnown = Wise.IsActionKnown
	Wise.IsActionKnown = function() return true end

	local savedGroups = WiseDB.groups
	local action = {
		type = "spell",
		value = CAST_ID,
		name = "Wise Stack Buff",
		indicatorRules = {
			{ metric = "stacks", operator = "<=", value = 99, color = "Red", glow = false },
			-- No metric field at all: the legacy shape, authored against stacks.
			{ operator = "<=", value = 99, color = "Blue", glow = false },
		},
	}
	WiseDB.groups = {
		StacksRetiredTest = {
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

	local btn = CreateFrame("Button", "WiseStacksRetiredBtn", UIParent)
	btn:SetSize(30, 30)
	Wise.buttonMeta = Wise.buttonMeta or {}
	Wise.buttonMeta[btn] = {
		actionType = "spell",
		actionValue = CAST_ID,
		baseSpellID = CAST_ID,
		spellID = CAST_ID,
		states = WiseDB.groups.StacksRetiredTest.actions[1],
	}
	Wise.frames = Wise.frames or {}
	Wise.frames["__StacksRetiredTest"] = { buttons = { btn } }

	Wise:UpdateIndicatorRules()
	local borderShown = btn.indicatorBorder ~= nil and btn.indicatorBorder:IsShown()

	Wise.frames["__StacksRetiredTest"] = nil
	Wise.buttonMeta[btn] = nil
	WiseDB.groups = savedGroups
	CU.GetPlayerAuraBySpellID = savedByID
	CU.GetAuraDataBySpellName = savedByName
	CS.IsSpellUsable = savedUsable
	CS.GetSpellCooldown = savedCD
	Wise.IsActionKnown = savedKnown
	Wise:RebuildIndicatorRules()

	assertFalse(borderShown)
end)

-- In-combat display path, modelled on MEASURED 12.0.7 behaviour (Mechanic probes
-- v1-v3, build 68887) rather than on the API docs, which are wrong here:
--   * minDisplayCount does NOT gate the return (min=999 on a 1-stack aura still
--     returns non-nil), so >=N threshold inference is impossible.
--   * the return for a rotationally-relevant aura is a SECRET string: it can be
--     passed to SetText but comparing it throws.
-- So the contract under test is: the COUNT DISPLAYS, and stack-threshold colour
-- rules match NOTHING (clear border) rather than matching everything at once.
test("IndicatorRules: in-combat secret aura displays count but matches no stack rule", function()
	local CAST_ID, AURA_ID, INST_ID, LIVE_STACKS = 999021, 999022, 4242, 12
	local CU = _G.C_UnitAuras or {}
	_G.C_UnitAuras = CU
	local savedByID = CU.GetPlayerAuraBySpellID
	local savedByName = CU.GetAuraDataBySpellName
	local savedByInst = CU.GetAuraDataByAuraInstanceID
	local savedDC = CU.GetAuraApplicationDisplayCount
	local savedSlots = CU.GetAuraSlots
	local savedBySlot = CU.GetAuraDataBySlot
	local savedICL = _G.InCombatLockdown
	local inCombat = false
	local AURA_SLOT = 7
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
	-- Measured 12.0.7 shape: the aura still ENUMERATES in combat and its
	-- auraInstanceID stays PLAIN; only the identifying fields go secret. That is
	-- what lets the slot-based resolver find the live handle mid-combat. (First
	-- return of GetAuraSlots is the continuation token, hence the leading nil.)
	CU.GetAuraSlots = function()
		return nil, AURA_SLOT
	end
	CU.GetAuraDataBySlot = function(unit, slot)
		if slot ~= AURA_SLOT then
			return nil
		end
		if inCombat then
			-- spellId unreadable in combat; the instance id is not.
			return { auraInstanceID = INST_ID }
		end
		return auraData
	end
	-- Live-client model. The sim cannot represent a true secret (SetText demands a
	-- real string, and a proxy table hard-errors at file scope), so this models
	-- the OTHER half of the measured behaviour, which is equally fatal to
	-- threshold inference and IS expressible here: minDisplayCount is IGNORED, so
	-- every probe returns a value no matter how large the threshold. Any >=N
	-- inference therefore reads "true" at every N.
	--
	-- The secret-comparison half is covered by construction instead: StacksAtLeast
	-- no longer calls the API at all, so there is no comparison left to throw.
	CU.GetAuraApplicationDisplayCount = function(unit, instID, minCount)
		if instID ~= INST_ID then
			return nil
		end
		-- NOTE: minCount deliberately ignored — that is what the client does.
		return tostring(LIVE_STACKS)
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
	CU.GetAuraSlots = savedSlots
	CU.GetAuraDataBySlot = savedBySlot
	_G.InCombatLockdown = savedICL
	Wise:RebuildIndicatorRules()

	-- The count still displays: SetText accepts the secret.
	assertTrue(countShown)
	assertEquals(tostring(LIVE_STACKS), countText)
	-- ...but NO stack-threshold rule may match. Previously the <=2 Red rule and
	-- the >=8 White rule both "matched" (the nil-check misread every return as a
	-- hit) and Red won by rule order — a confidently wrong border for the whole
	-- fight. Unknown stacks must leave the border clear instead.
	assertFalse(borderShown)
	assertEquals(nil, borderG)
end)
