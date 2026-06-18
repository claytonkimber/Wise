-- Unit tests for the scope-waterfall filter primitives (all in core/Filters.lua):
--   * Wise:GetActionScopeRank — pure tag->rank mapping
--   * the build: branch of Wise:MatchesRestrictionTag
--   * Wise:ShouldShowAction character-filter exclusivity
--
-- The addon files use the `local addonName, addon = ...` bootstrap, so we load
-- each real source via loadfile(...)(addonName, Wise) against a stubbed WoW
-- environment. This exercises the SHIPPING code, not a re-implementation.

local function makeWise()
	return { characterInfo = {} }
end

-- Minimal WoW global surface these two functions touch.
local function installGlobals(activeConfigID, knownTalents)
	_G.C_ClassTalents = {
		GetActiveConfigID = function()
			return activeConfigID
		end,
	}
	_G.IsPlayerSpell = function(id)
		return knownTalents and knownTalents[id] == true
	end
	_G.IsSpellKnownOrOverridesKnown = function(id)
		return knownTalents and knownTalents[id] == true
	end
	-- MatchesRestrictionTag references these for other branches; stub benignly.
	_G.UnitName = function()
		return "Tester"
	end
	_G.GetRealmName = function()
		return "Realm"
	end
end

-- Load the REAL Wise.lua/Actions.lua function definitions onto a Wise table.
-- Both files do heavy load-time work (event frames, hooksecurefunc, EditMode
-- hooks). We install a permissive, chainable _G fallback just for the load so
-- that work is absorbed, then restore the real _G so functions run unmasked.
local function loadRealAddon(Wise, files)
	local stub
	stub = setmetatable({}, {
		__index = function()
			return stub
		end,
		__call = function()
			return stub
		end,
	})
	_G.CreateFrame = function()
		return stub
	end
	local realMeta = getmetatable(_G)
	setmetatable(_G, {
		__index = function()
			return stub
		end,
	})
	for _, f in ipairs(files) do
		local chunk = assert(loadfile(f))
		local ok, err = pcall(chunk, "WiseTest", Wise)
		if not ok then
			setmetatable(_G, realMeta)
			error(f .. " failed to load: " .. tostring(err))
		end
	end
	setmetatable(_G, realMeta)
end

describe("GetActionScopeRank", function()
	local Wise
	before_each(function()
		Wise = makeWise()
		loadRealAddon(Wise, { "Wise.lua", "core/Filters.lua" })
	end)

	it("ships the expected scope-rank tables", function()
		assert.are.same({ global = 1, class = 2, spec = 3, talent = 4, build = 4, char = 5 }, Wise.SCOPE_RANK)
		assert.are.same({ global = 1, class = 2, spec = 3, build = 4, character = 5 }, Wise.SCOPE_FILTER_RANK)
	end)

	it("ranks an untagged action as global (1)", function()
		assert.are.equal(1, Wise:GetActionScopeRank({}))
		assert.are.equal(1, Wise:GetActionScopeRank({ visibilityEnable = {} }))
	end)

	it("ranks class/spec/build/char tags on the ladder", function()
		assert.are.equal(2, Wise:GetActionScopeRank({ visibilityEnable = { "class:MAGE" } }))
		assert.are.equal(3, Wise:GetActionScopeRank({ visibilityEnable = { "spec:62" } }))
		assert.are.equal(4, Wise:GetActionScopeRank({ visibilityEnable = { "build:7" } }))
		assert.are.equal(5, Wise:GetActionScopeRank({ visibilityEnable = { "char:Tester-Realm" } }))
	end)

	it("ranks legacy talent: tags at the build tier (4)", function()
		assert.are.equal(4, Wise:GetActionScopeRank({ visibilityEnable = { "talent:12345" } }))
	end)

	it("takes the NARROWEST (max) rank across mixed tags", function()
		assert.are.equal(
			5,
			Wise:GetActionScopeRank({
				visibilityEnable = { "class:MAGE", "spec:62", "char:Tester-Realm" },
			})
		)
		assert.are.equal(
			4,
			Wise:GetActionScopeRank({
				visibilityEnable = { "class:MAGE", "build:7" },
			})
		)
	end)

	it("treats role: as orthogonal — never raises rank", function()
		assert.are.equal(1, Wise:GetActionScopeRank({ visibilityEnable = { "role:HEALER" } }))
		assert.are.equal(2, Wise:GetActionScopeRank({ visibilityEnable = { "class:MAGE", "role:HEALER" } }))
	end)
end)

describe("MatchesRestrictionTag build: branch", function()
	local Wise
	before_each(function()
		Wise = makeWise()
		installGlobals(7, {})
		loadRealAddon(Wise, { "Wise.lua", "core/Filters.lua" })
	end)

	it("registers the build: tag handler (smoke)", function()
		assert.is_function(Wise.MatchesRestrictionTag)
	end)

	it("matches when the active config equals the tagged build", function()
		Wise.characterInfo.talentConfigID = 7
		assert.is_true(Wise:MatchesRestrictionTag("build:7"))
	end)

	it("does not match a different active build", function()
		Wise.characterInfo.talentConfigID = 9
		assert.is_false(Wise:MatchesRestrictionTag("build:7"))
	end)

	it("falls back to GetActiveConfigID when characterInfo is unset", function()
		Wise.characterInfo.talentConfigID = nil
		assert.is_true(Wise:MatchesRestrictionTag("build:7")) -- active stub returns 7
		assert.is_false(Wise:MatchesRestrictionTag("build:8"))
	end)

	it("never matches a malformed build: tag", function()
		Wise.characterInfo.talentConfigID = 7
		assert.is_false(Wise:MatchesRestrictionTag("build:"))
		assert.is_false(Wise:MatchesRestrictionTag("build:abc"))
	end)
end)

describe("ShouldShowAction character filter (exclusive)", function()
	local Wise
	before_each(function()
		Wise = makeWise()
		installGlobals(7, {})
		Wise.characterInfo.class = "PRIEST"
		Wise.characterInfo.specID = 258 -- Shadow
		Wise.characterInfo.role = "DAMAGER"
		loadRealAddon(Wise, { "Wise.lua", "core/Filters.lua" })
		Wise.ActionFilter = "character"
	end)

	it("shows an action pinned to THIS character", function()
		assert.is_true(Wise:ShouldShowAction({
			type = "spell",
			value = 1,
			visibilityEnable = { "char:Tester-Realm" },
		}))
	end)

	it("hides an action pinned to a DIFFERENT character", function()
		assert.is_false(Wise:ShouldShowAction({
			type = "spell",
			value = 1,
			visibilityEnable = { "char:Someone-Else" },
		}))
	end)

	it("hides actions with no character restriction (the Char != All fix)", function()
		assert.is_false(Wise:ShouldShowAction({ type = "spell", value = 1, visibilityEnable = {} }))
		assert.is_false(Wise:ShouldShowAction({
			type = "spell",
			value = 1,
			visibilityEnable = { "class:PRIEST", "spec:258" },
		}))
	end)

	it("honors the legacy character category pinned to this toon", function()
		assert.is_true(Wise:ShouldShowAction({
			type = "spell",
			value = 1,
			category = "character",
			addedByCharacter = "Tester-Realm",
		}))
		assert.is_false(Wise:ShouldShowAction({
			type = "spell",
			value = 1,
			category = "character",
			addedByCharacter = "Someone-Else",
		}))
	end)
end)
