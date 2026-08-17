-- Tests for core/Retoken.lua — durable macro tokens.
--
-- The whole point of the module is that a macro stored once keeps working when
-- the client's LANGUAGE or a SPELL ID changes. Neither of those can be triggered
-- in the simulator, so these tests pin the two mechanisms that deliver it:
--
--   * expansion resolves an ID to whatever this client calls it right now
--     (a locale change is just a different answer from the same call), and
--   * a /-separated ID list falls through to the first ID that resolves
--     (which is what carries a macro across a spell-ID change).
--
-- Plus the failure modes, which are where the real bugs were.

local R = Wise.Retoken

local FIREBALL = 133 -- resolves in the sim
local ABUNDANCE = 207383
local HEARTHSTONE_ITEM = 6948
local BOGUS = 99999999 -- resolves nowhere

test("Retoken: expands a spell token to the client's current name", function()
	local out, resolved, unresolved = R:Expand("/cast {{spell:" .. FIREBALL .. "}}")
	assertEquals("/cast Fireball", out)
	assertEquals(1, resolved)
	assertEquals(0, unresolved)
end)

test("Retoken: expands an item token", function()
	local out = R:Expand("/use {{item:" .. HEARTHSTONE_ITEM .. "}}")
	assertEquals("/use Hearthstone", out)
end)

test("Retoken: an ID list falls through to the first ID that resolves", function()
	-- This is the spell-ID-change mechanism: store "new/old" and the same macro
	-- works on both sides of the patch that renumbered the spell.
	assertEquals("/cast Fireball", R:Expand("/cast {{spell:" .. BOGUS .. "/" .. FIREBALL .. "}}"))
	-- Order matters: the FIRST resolvable candidate wins.
	assertEquals("/cast Fireball", R:Expand("/cast {{spell:" .. FIREBALL .. "/" .. ABUNDANCE .. "}}"))
	assertEquals("/cast Abundance", R:Expand("/cast {{spell:" .. ABUNDANCE .. "/" .. FIREBALL .. "}}"))
end)

test("Retoken: an unresolvable token is left VERBATIM, never blanked", function()
	-- Blanking would turn "/cast {{spell:X}}" into a bare "/cast" — a valid
	-- command that silently does nothing. Leaving the token keeps the failure
	-- visible and preserves the stored intent for a character that CAN resolve it
	-- (different class, spell not yet learned).
	local out, resolved, unresolved = R:Expand("/cast {{spell:" .. BOGUS .. "}}")
	assertEquals("/cast {{spell:" .. BOGUS .. "}}", out)
	assertEquals(0, resolved)
	assertEquals(1, unresolved)
end)

test("Retoken: rejects the APIs' fake 'Unknown' names", function()
	-- Both C_Spell.GetSpellName and C_Item.GetItemInfo return the literal string
	-- "Unknown" for an id that does not exist, rather than nil. Trusting either
	-- would expand to "/cast Unknown" — a silently broken macro that looks like a
	-- Wise bug. GetItemInfoInstant is worse: it echoes back ANY number given, so
	-- it cannot be used as an existence check at all.
	assertEquals(nil, R.Resolvers.spell(BOGUS))
	assertEquals(nil, R.Resolvers.item(BOGUS))
	assertEquals(nil, R.Resolvers.toy(BOGUS))

	local out = R:Expand("/use {{item:" .. BOGUS .. "}}")
	assertEquals(true, out:find("Unknown", 1, true) == nil)
end)

test("Retoken: leaves unknown kinds and non-numeric args alone", function()
	assertEquals("/cast {{bogus:133}}", R:Expand("/cast {{bogus:133}}"))
	assertEquals("/cast {{spell:notanumber}}", R:Expand("/cast {{spell:notanumber}}"))
end)

test("Retoken: text without tokens is returned unchanged", function()
	assertEquals("/cast Fireball", R:Expand("/cast Fireball"))
	assertEquals("", R:Expand(""))
	assertEquals(false, R:HasTokens("/cast Fireball"))
	assertEquals(true, R:HasTokens("/cast {{spell:133}}"))
end)

test("Retoken: expands every token in a multi-line macro", function()
	local macro = "#showtooltip {{spell:"
		.. FIREBALL
		.. "}}\n/cast [combat] {{spell:"
		.. ABUNDANCE
		.. "}}; {{spell:"
		.. FIREBALL
		.. "}}"
	local out, resolved = R:Expand(macro)
	assertEquals(3, resolved)
	assertEquals(true, out:find("{{", 1, true) == nil)
	assertEquals("#showtooltip Fireball\n/cast [combat] Abundance; Fireball", out)
end)

test("Retoken: Inspect reports each token and whether it resolves", function()
	local list = R:Inspect("/cast {{spell:" .. FIREBALL .. "}} {{spell:" .. BOGUS .. "}}")
	assertEquals(2, #list)
	assertEquals("spell", list[1].kind)
	assertEquals("Fireball", list[1].resolved)
	assertEquals(nil, list[2].resolved)
end)

test("Retoken: Tokenize round-trips a plain macro", function()
	local plain = "/cast Fireball"
	local tokenized, count = R:Tokenize(plain)
	assertEquals(1, count)
	assertEquals("/cast {{spell:" .. FIREBALL .. "}}", tokenized)
	-- The round trip must return the original text exactly.
	assertEquals(plain, R:Expand(tokenized))
end)

test("Retoken: Tokenize preserves [conditions] and skips non-cast lines", function()
	assertEquals("/cast [combat] {{spell:" .. FIREBALL .. "}}", (R:Tokenize("/cast [combat] Fireball")))
	assertEquals("/say hello", (R:Tokenize("/say hello")))
	-- Already tokenized text is left alone (no double-wrapping).
	local already = "/cast {{spell:" .. FIREBALL .. "}}"
	assertEquals(already, (R:Tokenize(already)))
	-- A name that does not resolve is left as plain text rather than guessed at.
	assertEquals("/cast NotARealSpellName", (R:Tokenize("/cast NotARealSpellName")))
end)

test("Retoken: stored macro text keeps its tokens (expansion is read-only)", function()
	-- The bug this guards: the macro editor used to expand tokens, strip the
	-- colors, and SAVE the plain localized name — so typing a token destroyed it
	-- on the first keystroke, and merely opening the editor destroyed tokens in
	-- existing macros. That defeats the entire feature, and silently.
	--
	-- The contract is that expansion happens on READ. Expand must never be the
	-- thing that writes to action.macroText.
	local action = { type = "misc", value = "custom_macro", macroText = "/cast {{spell:" .. FIREBALL .. "}}" }
	local stored = action.macroText

	-- Both read paths expand...
	assertEquals("/cast Fireball", R:Expand(action.macroText))
	local _, _, icon = Wise:ResolveMacroData(action.macroText)
	assertEquals(true, icon ~= nil)

	-- ...and neither mutates the stored text.
	assertEquals(stored, action.macroText)
	assertEquals(true, action.macroText:find("{{", 1, true) ~= nil)
end)

test("Retoken: ResolveMacroData resolves a tokenized macro's icon", function()
	-- Without expansion here the icon is resolved from the literal "{{spell:133}}"
	-- and the button shows a question mark, which reads as a broken action.
	local plainType, plainValue, plainIcon = Wise:ResolveMacroData("#showtooltip Fireball\n/cast Fireball")
	local tokType, tokValue, tokIcon =
		Wise:ResolveMacroData("#showtooltip {{spell:" .. FIREBALL .. "}}\n/cast {{spell:" .. FIREBALL .. "}}")
	-- A tokenized macro must resolve to exactly what its plain equivalent does.
	assertEquals(plainType, tokType)
	assertEquals(plainValue, tokValue)
	assertEquals(plainIcon, tokIcon)
end)

test("Retoken: Tokenize does NOT touch /use lines", function()
	-- Many items share a name with a spell — Hearthstone is item 6948 AND spell
	-- 8690. A name lookup on a /use line silently rebinds an ITEM reference to a
	-- SPELL, and because both expand to the same text the mistake is invisible
	-- until the two diverge. Items have to be tokenized explicitly.
	local out, count = R:Tokenize("/use Hearthstone")
	assertEquals("/use Hearthstone", out)
	assertEquals(0, count)
end)
