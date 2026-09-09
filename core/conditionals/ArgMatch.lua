-- core/conditionals/ArgMatch.lua
--
-- Argument matching for parameterised custom conditionals, extracted from
-- core/GUI.lua. Pure string/number logic — no WoW API is touched here, which is
-- what makes this the one part of the conditional engine that is trivially
-- unit-testable.
--
-- Wise tokens take their argument after a colon and accept /-separated
-- alternatives, matching WoW macro-conditional style:
--
--   [race:orc/troll]   ArgMatches    — one value, several accepted spellings
--   [coven:fae]        ArgMatchesAny — value side ALSO has alternatives
--   [level:70]         AtLeast       — numeric tokens mean ">= n", never "== n"
--   [prof:jc]          HasProfession — localised names plus English aliases
--
-- A bare token with an empty argument ([zone:]) means "any", so ArgMatches and
-- ArgMatchesAny both return true for it; that is deliberate, not a missing
-- guard.
--
-- Loaded after Vocabulary.lua and before Predicates.lua.

local addonName, Wise = ...

local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber

local E = Wise.CondEngine or {}
Wise.CondEngine = E

-- Parameterised tokens accept alternatives as [race:orc/troll], and a bare
-- [zone:] with no argument is treated as "any".
local function ArgMatches(arg, want)
	if not arg or arg == "" then
		return true
	end
	if not want then
		return false
	end
	want = tostring(want):lower()
	for piece in arg:lower():gmatch("[^/]+") do
		piece = piece:match("^%s*(.-)%s*$")
		if piece ~= "" and piece == want then
			return true
		end
	end
	return false
end

-- Like ArgMatches, but the VALUE side also carries /-separated alternatives —
-- e.g. the covenant token "fae/nightfae" accepts either spelling. Matches when
-- any requested alternative equals any value alternative.
local function ArgMatchesAny(arg, value)
	if not arg or arg == "" then
		return true
	end
	if not value then
		return false
	end
	for want in arg:lower():gmatch("[^/]+") do
		want = want:match("^%s*(.-)%s*$")
		if want ~= "" then
			for have in tostring(value):lower():gmatch("[^/]+") do
				have = have:match("^%s*(.-)%s*$")
				if have == want then
					return true
				end
			end
		end
	end
	return false
end

-- Numeric threshold tokens ([level:70], [combo:3]) mean ">= n".
local function AtLeast(arg, actual)
	local n = tonumber(arg)
	if not n then
		return false
	end
	return (tonumber(actual) or 0) >= n
end

-- [prof:name] — matches a known profession by localised name, and by the short
-- English aliases below so imported conditions keep working across locales.
local PROF_ALIASES = {
	alch = "Alchemy",
	bs = "Blacksmithing",
	ench = "Enchanting",
	engi = "Engineering",
	herb = "Herbalism",
	insc = "Inscription",
	jc = "Jewelcrafting",
	lw = "Leatherworking",
	mine = "Mining",
	skin = "Skinning",
	tail = "Tailoring",
	cook = "Cooking",
	fish = "Fishing",
	firstaid = "First Aid",
}

local function HasProfession(arg)
	if not arg or arg == "" then
		return false
	end
	if not GetProfessions then
		return false
	end
	-- Resolve aliases to their English names before comparing.
	local wanted = {}
	for piece in arg:lower():gmatch("[^/]+") do
		piece = piece:match("^%s*(.-)%s*$")
		if piece ~= "" then
			wanted[piece] = true
			local full = PROF_ALIASES[piece]
			if full then
				wanted[full:lower()] = true
			end
		end
	end
	for _, index in ipairs({ GetProfessions() }) do
		local name = index and GetProfessionInfo(index)
		if name and wanted[name:lower()] then
			return true
		end
	end
	return false
end

-- Spell 61304 is the shared global-cooldown "spell"; reading its cooldown is how
-- you get the CURRENT gcd, which is haste-scaled and differs by class (1.0s for
-- some, 1.5s baseline). Never hardcode 1.5 — that misreports readiness for any

-- Published to the engine's internals for EvalToken.lua.
E.ArgMatches = ArgMatches
E.ArgMatchesAny = ArgMatchesAny
E.AtLeast = AtLeast
E.HasProfession = HasProfession
