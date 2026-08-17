-- Regression tests for the OPie conditionals ported into Wise.
--
-- The bug these guard against is structural, not arithmetic: a custom token has
-- to be present in THREE tables that live in two files, and being present in
-- only some of them fails SILENTLY.
--
--   VALID_CONDITIONALS      (core/Conditionals.lua) — editor accept/reject
--   opieConditionals        (core/Conditionals.lua) — options-tab reference list
--   CUSTOM_VIS_CONDITIONALS (core/GUI.lua)          — runtime dispatch
--
-- Before this port, ~24 tokens appeared in opieConditionals but in NEITHER of the
-- other two. They rendered in the options window as if supported, were rejected
-- by the editor's validator, and — had they got past it — would have fallen
-- through to SecureCmdOptionParse, which does not know them, and evaluated false
-- forever. Nothing errored; conditions just never matched.
--
-- So the load-bearing assertion here is table agreement, not "does [horde] work".

local PORTED = {
	"zone",
	"instance",
	"in",
	"me",
	"level",
	"race",
	"game",
	"horde",
	"alliance",
	"mercenary",
	"merc",
	"prof",
	"havepet",
	"petcontrol",
	"imbuedmh",
	"imbuedoh",
	"moving",
	"falling",
	"ready",
	"have",
	"buff",
	"debuff",
	"selfbuff",
	"selfdebuff",
	"combo",
	-- Second wave, ported from OPie 8.3–8.8.
	"warbank",
	"prey",
	"housereturn",
	"myth",
	"coven",
	"covenant",
	"uslot",
	"superflyable",
	"blockedflyable",
	"anyflyable",
	"worldhover",
}

-- assertEquals takes only (expected, actual) — a third argument is ignored — so
-- context-carrying failures are raised directly.
local function assertWith(cond, message)
	if not cond then
		error(message, 2)
	end
end

test("ported conditionals: every token validates in the editor", function()
	-- Wise:ValidateVisibilityCondition is the editor gate. A token missing from
	-- VALID_CONDITIONALS returns false + "Unknown conditional", which is exactly
	-- what every one of these did before the port.
	for _, token in ipairs(PORTED) do
		local probe = "[" .. token .. "]"
		local ok, err = Wise:ValidateVisibilityCondition(probe)
		assertWith(ok, probe .. " rejected by validator: " .. tostring(err))
	end
end)

test("ported conditionals: parameterised and negated forms validate", function()
	for _, probe in ipairs({
		"[zone:Dornogal]",
		"[in:raid]",
		"[level:80]",
		"[race:Orc]",
		"[prof:tail]",
		"[combo:3]",
		"[selfbuff:Arcane Intellect]",
		"[nomoving]",
		"[nohorde]",
		-- Mixed with native tokens in one bracket group, which is the common shape.
		"[combat,in:raid]",
		"[nocombat,zone:Dornogal]",
	}) do
		local ok, err = Wise:ValidateVisibilityCondition(probe)
		assertWith(ok, probe .. " rejected by validator: " .. tostring(err))
	end
end)

test("ported conditionals: each token actually reaches the custom evaluator", function()
	-- Wise:EvalConditionExact routes through EvalConditionString, which only treats
	-- a token as custom if CUSTOM_VIS_CONDITIONALS holds it. If a token is absent
	-- there it silently goes to SecureCmdOptionParse instead.
	--
	-- We assert routing, not truth: the correct VALUE depends on live game state,
	-- but a token that reaches the evaluator must produce a boolean and must not
	-- error. A token that fell through to the secure path with an argument (e.g.
	-- "zone:Dornogal") cannot produce true under any state, so pairing each token
	-- with its negation catches the fall-through: exactly one of the two must hold.
	for _, token in ipairs(PORTED) do
		local plain = Wise:EvalConditionExact("[" .. token .. "]")
		local negated = Wise:EvalConditionExact("[no" .. token .. "]")
		assertWith(type(plain) == "boolean", token .. " did not return a boolean")
		assertWith(type(negated) == "boolean", "no" .. token .. " did not return a boolean")
		assertWith(
			plain ~= negated,
			"["
				.. token
				.. "] and [no"
				.. token
				.. "] both returned "
				.. tostring(plain)
				.. "; token is not reaching the custom evaluator"
		)
	end
end)

test("ported conditionals: options list only advertises implemented tokens", function()
	-- The list users read must not name a token the runtime cannot dispatch. This
	-- is the check that would have caught the original bug at its source.
	for _, entry in ipairs(Wise.opieConditionals) do
		if entry.type ~= "header" and entry.name then
			-- Entries are display forms ("zone:name", "combo:n"); take the base.
			local base = entry.name:match("^([^:]+)") or entry.name
			base = base:lower()

			-- aml: and available: are Wise-native and handled separately; spec/form/
			-- stance are NATIVE WoW conditionals served by the secure driver, so they
			-- are correctly absent from the custom table.
			local nativeOrSpecial = {
				aml = true,
				available = true,
				spec = true,
				form = true,
				stance = true,
				undermouse = true,
			}

			if not nativeOrSpecial[base] then
				local ok = Wise:ValidateVisibilityCondition("[" .. base .. "]")
				assertWith(ok, "options tab lists [" .. base .. "] but the validator rejects it")
			end
		end
	end
end)

test("ported conditionals: [ready:] and [have:] reject nonexistent things", function()
	-- Regression: C_Item.GetItemCooldown returns start=0,duration=0 for an item
	-- that DOES NOT EXIST, which is indistinguishable from a real item that is off
	-- cooldown. [ready:AnyGarbage] therefore reported TRUE — a condition that is
	-- always satisfied is worse than one that never is, because it silently shows
	-- interfaces that should be hidden. The fix resolves the item via
	-- GetItemInfoInstant (nil for garbage) before trusting the cooldown.
	assertEquals(false, Wise:EvalConditionExact("[ready:NoSuchSpellQZX]"))
	assertEquals(false, Wise:EvalConditionExact("[ready:ZZZNotAThing]"))
	assertEquals(false, Wise:EvalConditionExact("[have:NoSuchItemQZX]"))

	-- Negation of a false token must be true — proves these are still evaluated
	-- rather than short-circuiting to a constant.
	assertEquals(true, Wise:EvalConditionExact("[noready:NoSuchSpellQZX]"))
	assertEquals(true, Wise:EvalConditionExact("[nohave:NoSuchItemQZX]"))

	-- Empty argument is not a wildcard for these two: [ready:] with nothing to
	-- check cannot be satisfied.
	assertEquals(false, Wise:EvalConditionExact("[ready:]"))
	assertEquals(false, Wise:EvalConditionExact("[have:]"))
end)

test("ported conditionals: [coven:] matches both spellings, case-insensitively", function()
	-- Covenant tokens carry alternatives on the VALUE side ("fae/nightfae"), the
	-- reverse of every other token, where alternatives are on the argument side.
	-- That needs ArgMatchesAny rather than ArgMatches; using the wrong one makes
	-- [coven:nightfae] silently fail while [coven:fae] works.
	local saved = C_Covenants and C_Covenants.GetActiveCovenantID
	if not saved then
		return -- API absent; nothing to assert
	end

	C_Covenants.GetActiveCovenantID = function()
		return 3 -- Night Fae
	end
	local ok, err = pcall(function()
		assertEquals(true, Wise:EvalConditionExact("[coven:fae]"))
		assertEquals(true, Wise:EvalConditionExact("[coven:nightfae]"))
		assertEquals(true, Wise:EvalConditionExact("[coven:NIGHTFAE]"))
		assertEquals(true, Wise:EvalConditionExact("[covenant:fae]")) -- alias
		assertEquals(false, Wise:EvalConditionExact("[coven:kyrian]"))
		assertEquals(true, Wise:EvalConditionExact("[nocoven:kyrian]"))
		-- Bare [coven] = "in any covenant".
		assertEquals(true, Wise:EvalConditionExact("[coven]"))

		C_Covenants.GetActiveCovenantID = function()
			return 0 -- none
		end
		assertEquals(false, Wise:EvalConditionExact("[coven]"))
		assertEquals(false, Wise:EvalConditionExact("[coven:fae]"))
	end)

	C_Covenants.GetActiveCovenantID = saved
	if not ok then
		error(err, 0)
	end
end)

test("ported conditionals: [uslot:] requires an equipped ON-USE item", function()
	-- Two ways to get this wrong: report true for an empty slot, or report true
	-- for an item whose only effect is passive. Both would make the token useless
	-- for its actual purpose (showing a trinket button only when it can be used).
	local sLink = _G.GetInventoryItemLink
	local sID = _G.GetInventoryItemID
	local sSpell = C_Item and C_Item.GetItemSpell
	local sPassive = _G.IsPassiveSpell
	if not (sSpell and _G.GetInventorySlotInfo) then
		return
	end

	-- Only TRINKET0SLOT (13) holds anything. Both link and ID must be stubbed —
	-- the code falls back from one to the other, so stubbing only the link leaves
	-- the real item ID visible and the slot reads as occupied.
	_G.GetInventoryItemLink = function(_, slot)
		return slot == 13 and "item:12345" or nil
	end
	_G.GetInventoryItemID = function(_, slot)
		return slot == 13 and 12345 or nil
	end
	C_Item.GetItemSpell = function()
		return "Fake Use", 99999
	end
	_G.IsPassiveSpell = function()
		return false
	end

	local ok, err = pcall(function()
		assertEquals(true, Wise:EvalConditionExact("[uslot:trinket1]"))
		assertEquals(false, Wise:EvalConditionExact("[uslot:trinket2]"))
		assertEquals(false, Wise:EvalConditionExact("[uslot:head]"))
		-- Alternation: any listed slot satisfying it is enough.
		assertEquals(true, Wise:EvalConditionExact("[uslot:trinket2/trinket1]"))
		-- An unknown slot name is not a wildcard.
		assertEquals(false, Wise:EvalConditionExact("[uslot:bogusslot]"))
		-- Bare [uslot] with no slot named cannot be satisfied.
		assertEquals(false, Wise:EvalConditionExact("[uslot]"))

		-- A PASSIVE effect must not count as usable.
		_G.IsPassiveSpell = function()
			return true
		end
		assertEquals(false, Wise:EvalConditionExact("[uslot:trinket1]"))

		-- An item with no spell at all must not count.
		_G.IsPassiveSpell = function()
			return false
		end
		C_Item.GetItemSpell = function()
			return nil, nil
		end
		assertEquals(false, Wise:EvalConditionExact("[uslot:trinket1]"))
	end)

	_G.GetInventoryItemLink = sLink
	_G.GetInventoryItemID = sID
	C_Item.GetItemSpell = sSpell
	_G.IsPassiveSpell = sPassive
	if not ok then
		error(err, 0)
	end
end)

test("ported conditionals: [prey] needs an active hunt, not just a quest", function()
	-- The quest can linger while the hunt is not running, so OPie also gates on
	-- the widget's shownState. Dropping that check makes [prey] stick on.
	local sPrey = C_QuestLog and C_QuestLog.GetActivePreyQuest
	local sComp = C_QuestLog and C_QuestLog.IsComplete
	local sViz = C_UIWidgetManager and C_UIWidgetManager.GetPreyHuntProgressWidgetVisualizationInfo
	if not (sPrey and sViz) then
		return
	end

	C_QuestLog.GetActivePreyQuest = function()
		return 8888
	end
	C_QuestLog.IsComplete = function()
		return false
	end
	C_UIWidgetManager.GetPreyHuntProgressWidgetVisualizationInfo = function()
		return { shownState = 1 }
	end

	local ok, err = pcall(function()
		assertEquals(true, Wise:EvalConditionExact("[prey]"))
		assertEquals(true, Wise:EvalConditionExact("[prey:8888]"))
		assertEquals(false, Wise:EvalConditionExact("[prey:9999]"))

		-- Widget not shown = hunt not running, even though the quest is active.
		C_UIWidgetManager.GetPreyHuntProgressWidgetVisualizationInfo = function()
			return { shownState = 0 }
		end
		assertEquals(false, Wise:EvalConditionExact("[prey]"))

		-- Completed quest = not hunting.
		C_UIWidgetManager.GetPreyHuntProgressWidgetVisualizationInfo = function()
			return { shownState = 1 }
		end
		C_QuestLog.IsComplete = function()
			return true
		end
		assertEquals(false, Wise:EvalConditionExact("[prey]"))
	end)

	C_QuestLog.GetActivePreyQuest = sPrey
	C_QuestLog.IsComplete = sComp
	C_UIWidgetManager.GetPreyHuntProgressWidgetVisualizationInfo = sViz
	if not ok then
		error(err, 0)
	end
end)

test("ported conditionals: combat-sampled values freeze and thaw", function()
	-- Wise drives visibility from insecure Lua and cannot write secure attributes
	-- during lockdown, so these tokens hold their combat-entry value rather than
	-- drifting to a live value that can never reach the driver.
	--
	-- InCombatLockdown is hoisted to an upvalue in core/GUI.lua, so stubbing
	-- _G.InCombatLockdown does NOT affect the code under test — an earlier version
	-- of this test did exactly that and silently exercised the live path instead of
	-- the frozen one. Wise._forceCombatSampling is the seam that actually works.
	--
	-- GetUnitSpeed is likewise absent under wow-ui-sim, so [moving] is driven here
	-- by stubbing _G.GetUnitSpeed, which EvalCustomToken resolves at call time.
	local savedSpeed = _G.GetUnitSpeed
	local savedForce = Wise._forceCombatSampling
	local speed = 5
	_G.GetUnitSpeed = function()
		return speed
	end

	local ok, err = pcall(function()
		Wise.ClearCombatConditionalSamples()
		Wise._forceCombatSampling = false -- out of combat

		-- Out of combat the token is live.
		assertEquals(true, Wise:EvalConditionExact("[moving]"))
		speed = 0
		assertEquals(false, Wise:EvalConditionExact("[moving]"))

		-- Moving at the moment combat starts: the value freezes true.
		speed = 5
		Wise:EvalConditionExact("[moving]") -- register the token
		Wise.SampleCombatConditionals()
		Wise._forceCombatSampling = true -- combat begins
		speed = 0 -- stop moving mid-combat
		assertEquals(true, Wise:EvalConditionExact("[moving]"))
		-- Negation must read the same frozen sample, not re-evaluate live.
		assertEquals(false, Wise:EvalConditionExact("[nomoving]"))

		-- Combat ends: live again.
		Wise.ClearCombatConditionalSamples()
		Wise._forceCombatSampling = false
		assertEquals(false, Wise:EvalConditionExact("[moving]"))
	end)

	_G.GetUnitSpeed = savedSpeed
	Wise._forceCombatSampling = savedForce
	Wise.ClearCombatConditionalSamples()

	if not ok then
		error(err, 0)
	end
end)
