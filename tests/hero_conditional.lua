-- tests/hero_conditional.lua
-- [hero] / [hero:<tree>] custom conditional: active hero talent tree.
-- Asserts the three tables agree (validates AND reaches the custom evaluator),
-- name/ID/alternative matching, absent-API safety and cache invalidation.
-- API fields are stubbed on the existing namespaces and restored afterwards.

local E = Wise.CondEngine

-- Run fn with C_ClassTalents / C_Traits stubs installed; always restore.
-- `state` is mutable so a test can change the answer between evaluations.
local function withHeroStubs(state, fn)
	local createdCT, createdTraits = false, false
	if not _G.C_ClassTalents then
		_G.C_ClassTalents = {}
		createdCT = true
	end
	if not _G.C_Traits then
		_G.C_Traits = {}
		createdTraits = true
	end
	local ct, traits = _G.C_ClassTalents, _G.C_Traits
	local saved = {
		spec = ct.GetActiveHeroTalentSpec,
		cfg = ct.GetActiveConfigID,
		sub = traits.GetSubTreeInfo,
	}
	ct.GetActiveHeroTalentSpec = function()
		return state.subTreeID
	end
	ct.GetActiveConfigID = function()
		return 1
	end
	traits.GetSubTreeInfo = function(configID, subTreeID)
		if state.subTreeID == subTreeID and state.name then
			return { name = state.name }
		end
		return nil
	end
	E.InvalidateHeroTree()
	local ok, err = pcall(fn)
	ct.GetActiveHeroTalentSpec = saved.spec
	ct.GetActiveConfigID = saved.cfg
	traits.GetSubTreeInfo = saved.sub
	if createdCT then
		_G.C_ClassTalents = nil
	end
	if createdTraits then
		_G.C_Traits = nil
	end
	E.InvalidateHeroTree()
	if not ok then
		error(err, 0)
	end
end

local function eval(token)
	return E.EvalCustomToken(token)
end

test("Hero: token is registered in all three tables and validates", function()
	assertEquals(true, E.CUSTOM_VIS_CONDITIONALS["hero"], "CUSTOM_VIS_CONDITIONALS")
	for _, str in ipairs({ "[hero]", "[hero:Templar]", "[nohero:31]", "[hero:Templar/Herald of the Sun]" }) do
		local ok, err = Wise:ValidateVisibilityCondition(str)
		assertEquals(true, ok, str .. " should validate: " .. tostring(err))
	end
	local listed = false
	for _, item in ipairs(Wise.extendedConditionals) do
		if item.name == "hero" or item.name == "hero:name" then
			listed = true
		end
	end
	assertEquals(true, listed, "display list entry")
end)

test("Hero: positive and negated forms disagree (reaches the custom evaluator)", function()
	withHeroStubs({ subTreeID = 31, name = "Templar" }, function()
		assertEquals(true, eval("hero:Templar"))
		assertEquals(false, eval("nohero:Templar"))
		assertEquals(false, eval("hero:Lightsmith"))
		assertEquals(true, eval("nohero:Lightsmith"))
	end)
end)

test("Hero: matches by name case-insensitively, by ID, and with alternatives", function()
	withHeroStubs({ subTreeID = 31, name = "Herald of the Sun" }, function()
		assertEquals(true, eval("hero:herald of the sun"))
		assertEquals(true, eval("hero:HERALD OF THE SUN"))
		assertEquals(true, eval("hero:31"))
		assertEquals(false, eval("hero:32"))
		assertEquals(true, eval("hero:Templar/Herald of the Sun"))
		assertEquals(true, eval("hero:Templar/31"))
		assertEquals(false, eval("hero:Templar/Lightsmith"))
		assertEquals(true, eval("hero"))
		assertEquals(false, eval("nohero"))
	end)
end)

test("Hero: ID still matches when the name cannot be resolved", function()
	withHeroStubs({ subTreeID = 31, name = nil }, function()
		assertEquals(true, eval("hero:31"))
		assertEquals(false, eval("hero:Templar"))
		assertEquals(true, eval("hero"))
	end)
end)

test("Hero: no hero tree chosen is false for every form", function()
	withHeroStubs({ subTreeID = nil, name = nil }, function()
		assertEquals(false, eval("hero"))
		assertEquals(false, eval("hero:Templar"))
		assertEquals(false, eval("hero:31"))
		assertEquals(true, eval("nohero"))
		assertEquals(true, eval("nohero:Templar"))
	end)
end)

test("Hero: absent APIs are false without error", function()
	withHeroStubs({ subTreeID = 31, name = "Templar" }, function()
		local ct, traits = _G.C_ClassTalents, _G.C_Traits
		local savedSpec, savedSub = ct.GetActiveHeroTalentSpec, traits.GetSubTreeInfo

		ct.GetActiveHeroTalentSpec = nil
		E.InvalidateHeroTree()
		local ok, v = pcall(eval, "hero")
		assertEquals(true, ok, "no error with spec API absent")
		assertEquals(false, v)
		ok, v = pcall(eval, "hero:Templar")
		assertEquals(true, ok)
		assertEquals(false, v)
		ct.GetActiveHeroTalentSpec = savedSpec

		-- Name API absent: still a hero tree, matched by ID only.
		traits.GetSubTreeInfo = nil
		E.InvalidateHeroTree()
		ok, v = pcall(eval, "hero:31")
		assertEquals(true, ok, "no error with GetSubTreeInfo absent")
		assertEquals(true, v)
		assertEquals(false, eval("hero:Templar"))
		traits.GetSubTreeInfo = savedSub

		-- An API that throws must not escape either.
		ct.GetActiveHeroTalentSpec = function()
			error("boom")
		end
		E.InvalidateHeroTree()
		ok, v = pcall(eval, "hero")
		assertEquals(true, ok, "throwing API is contained")
		assertEquals(false, v)
		ct.GetActiveHeroTalentSpec = savedSpec
	end)
end)

test("Hero: result is cached until an invalidating event fires", function()
	local state = { subTreeID = 31, name = "Templar" }
	withHeroStubs(state, function()
		assertEquals(true, eval("hero:Templar"))

		-- Change the underlying answer; the cache must still serve the old one.
		state.subTreeID, state.name = 32, "Lightsmith"
		assertEquals(true, eval("hero:Templar"), "served from cache")
		assertEquals(false, eval("hero:Lightsmith"), "served from cache")

		local handler = E.heroEventFrame:GetScript("OnEvent")
		assertNotNil(handler, "event frame has an OnEvent handler")
		handler(E.heroEventFrame, "TRAIT_CONFIG_UPDATED")
		assertEquals(false, eval("hero:Templar"), "stale after TRAIT_CONFIG_UPDATED")
		assertEquals(true, eval("hero:Lightsmith"))
		assertEquals(true, eval("hero:32"))

		-- The other three events invalidate the same way.
		for _, event in ipairs({
			"PLAYER_SPECIALIZATION_CHANGED",
			"ACTIVE_COMBAT_CONFIG_CHANGED",
			"PLAYER_ENTERING_WORLD",
		}) do
			state.subTreeID, state.name = 31, "Templar"
			handler(E.heroEventFrame, event)
			assertEquals(true, eval("hero:Templar"), event)
			state.subTreeID, state.name = 32, "Lightsmith"
			handler(E.heroEventFrame, event)
			assertEquals(true, eval("hero:Lightsmith"), event)
		end
	end)
end)

test("Hero: not combat-sampled", function()
	assertEquals(nil, E.COMBAT_SAMPLED["hero"])
end)
