local addonName, Wise = ...

-- Retoken.lua — durable macro tokens.
--
-- THE PROBLEM
--
-- A macro stored as plain text breaks in two ways that are invisible until they
-- bite:
--
--   1. Localization. "/cast Fireball" is stored on an enUS client and the same
--      account is played on deDE, where the spell is "Feuerball". The macro
--      silently does nothing — no error, the button just fails.
--   2. Spell-ID churn. Blizzard replaces a spell with a new ID across a patch
--      (or a talent rework splits one into several). The stored NAME may still
--      exist as a different, wrong spell, or stop existing entirely.
--
-- Wise's whole premise is that you configure once and it follows you across
-- every character. Storing localized display text directly contradicts that.
--
-- THE APPROACH
--
-- Store a stable token, resolve it to whatever the current client calls that
-- thing at the moment the macro is used:
--
--     /cast {{spell:133}}          -->  /cast Fireball        (enUS)
--                                  -->  /cast Feuerball       (deDE)
--     /use {{item:6948}}           -->  /use Hearthstone
--     /cast {{spell:999999/133}}   -->  falls back left-to-right; first ID that
--                                       resolves on THIS client wins
--
-- The ID list is the spell-ID-churn answer: put the new ID first and the old one
-- after it, and one stored macro works across the patch boundary in both
-- directions. Nothing here mutates saved data — expansion happens on read, so a
-- token that cannot resolve today (wrong class, spell not yet learned) still
-- resolves later on a character where it can.
--
-- WHY NOT JUST PORT REWIRE
--
-- OPie's Rewire/Imp pair does far more: it rewrites whole macro bodies, manages
-- named-macro ownership, and drives a secure snippet environment. Wise needs one
-- narrow thing — a durable reference to a spell/item/toy/mount — so this is a
-- self-contained resolver with no secure-frame involvement and no ownership
-- model. Different scope, different name, no shared code.

local Retoken = {}
Wise.Retoken = Retoken

local C_Spell = C_Spell
local C_Item = C_Item
local C_ToyBox = C_ToyBox
local C_MountJournal = C_MountJournal
local tonumber = tonumber
local tostring = tostring
local type = type
local pairs = pairs
local pcall = pcall

-- Token syntax: {{kind:arg}} where arg may be a /-separated fallback list.
-- Kinds are lowercase alpha; args are digits, letters, / and _ so that both
-- numeric IDs and named forms fit.
local TOKEN_PATTERN = "{{(%a+):([%w%d/_]+)}}"

-- ── Resolvers ───────────────────────────────────────────────────────────────
--
-- Each returns the CURRENT client's display string for one id, or nil when the
-- id does not resolve here. Returning nil is what lets the /-list fall through
-- to the next candidate.

-- C_Spell.GetSpellName returns the literal string "Unknown" for an id the client
-- cannot resolve — NOT nil. Writing that into a macro produces "/cast Unknown",
-- which fails silently and looks like a Wise bug. Always gate on GetSpellInfo,
-- which correctly returns nil, and take the name from it.
local function resolveSpell(id)
	local numeric = tonumber(id)
	if not numeric then
		return nil
	end
	if not (C_Spell and C_Spell.GetSpellInfo) then
		return nil
	end
	local ok, info = pcall(C_Spell.GetSpellInfo, numeric)
	if not ok or type(info) ~= "table" then
		return nil
	end
	local name = info.name
	if type(name) ~= "string" or name == "" then
		return nil
	end
	return name
end

-- Both item APIs lie about nonexistent ids, in different ways:
--   * GetItemInfoInstant ECHOES BACK any number it is given (and under
--     wow-ui-sim returns identical placeholder fields for real and bogus ids), so
--     it is useless as an existence check.
--   * GetItemInfo returns the literal string "Unknown" (not nil) for an id that
--     does not exist — the same trap as C_Spell.GetSpellName.
--
-- So the NAME is the only signal, and "Unknown" must be rejected explicitly.
-- Consequence: a real item whose name is genuinely not cached yet cannot be
-- distinguished from a nonexistent one, and both fall through to nil. That is the
-- safe direction — an unresolved token is left visible in the macro rather than
-- expanding to a wrong cast (see Expand).
local UNKNOWN_NAME = "Unknown"

local function resolveItem(id)
	local numeric = tonumber(id)
	if not numeric then
		return nil
	end
	if not (C_Item and C_Item.GetItemInfo) then
		return nil
	end
	local ok, name = pcall(C_Item.GetItemInfo, numeric)
	if ok and type(name) == "string" and name ~= "" and name ~= UNKNOWN_NAME then
		return name
	end
	return nil
end

local function resolveToy(id)
	local numeric = tonumber(id)
	if not numeric then
		return nil
	end
	if not (C_ToyBox and C_ToyBox.GetToyInfo) then
		return nil
	end
	local ok, _, name = pcall(C_ToyBox.GetToyInfo, numeric)
	if ok and type(name) == "string" and name ~= "" then
		return name
	end
	-- Fall back to the item name; toys are items and /use accepts either.
	return resolveItem(numeric)
end

local function resolveMount(id)
	local numeric = tonumber(id)
	if not numeric then
		return nil
	end
	if not (C_MountJournal and C_MountJournal.GetMountInfoByID) then
		return nil
	end
	local ok, name = pcall(C_MountJournal.GetMountInfoByID, numeric)
	if ok and type(name) == "string" and name ~= "" then
		return name
	end
	return nil
end

local RESOLVERS = {
	spell = resolveSpell,
	item = resolveItem,
	toy = resolveToy,
	mount = resolveMount,
}

Retoken.Resolvers = RESOLVERS

-- Resolve one token body. `arg` may be a /-separated candidate list; the first
-- candidate that resolves on this client wins, which is what makes a token
-- survive a spell-ID change (store "new/old").
local function resolveToken(kind, arg)
	local resolver = RESOLVERS[kind]
	if not resolver then
		return nil
	end
	for candidate in tostring(arg):gmatch("[^/]+") do
		local resolved = resolver(candidate)
		if resolved then
			return resolved
		end
	end
	return nil
end

Retoken.ResolveToken = resolveToken

-- ── Public API ──────────────────────────────────────────────────────────────

-- Expand every token in `text` to what this client calls it right now.
--
-- An UNRESOLVABLE token is left verbatim rather than blanked. That is
-- deliberate: a blank turns "/cast {{spell:123}}" into a bare "/cast", which is
-- a valid-but-wrong command that silently does nothing. Leaving the token makes
-- the failure visible in the macro editor and keeps the stored intent intact for
-- a character that CAN resolve it.
--
-- Returns: expandedText, numResolved, numUnresolved
function Retoken:Expand(text)
	if type(text) ~= "string" or text == "" then
		return text, 0, 0
	end
	if not text:find("{{", 1, true) then
		return text, 0, 0 -- fast path: no tokens
	end

	local resolved, unresolved = 0, 0
	local out = text:gsub(TOKEN_PATTERN, function(kind, arg)
		local value = resolveToken(kind:lower(), arg)
		if value then
			resolved = resolved + 1
			return value
		end
		unresolved = unresolved + 1
		return nil -- gsub: nil keeps the original match
	end)
	return out, resolved, unresolved
end

-- Does this text contain at least one token?
function Retoken:HasTokens(text)
	if type(text) ~= "string" or not text:find("{{", 1, true) then
		return false
	end
	return text:find(TOKEN_PATTERN) ~= nil
end

-- Report every token in `text` without expanding, for the editor's status line.
-- Returns an array of { kind, arg, resolved (string or nil) }.
function Retoken:Inspect(text)
	local list = {}
	if type(text) ~= "string" or text == "" then
		return list
	end
	for kind, arg in text:gmatch(TOKEN_PATTERN) do
		list[#list + 1] = {
			kind = kind:lower(),
			arg = arg,
			resolved = resolveToken(kind:lower(), arg),
		}
	end
	return list
end

-- ── Authoring helpers ───────────────────────────────────────────────────────

-- Turn a resolved name back INTO a token, so the editor can offer "make this
-- durable" on a macro that was typed by hand.
--
-- Only exact, unambiguous matches are converted. A name that does not resolve to
-- exactly one id is left alone — guessing here would silently rebind a macro to
-- the wrong spell, which is worse than leaving plain text that at least works on
-- the client it was written on.
function Retoken:Tokenize(text, kind)
	kind = kind or "spell"
	if type(text) ~= "string" or text == "" then
		return text, 0
	end
	if kind ~= "spell" then
		return text, 0 -- only spell-name lookup is reliable enough to reverse
	end
	if not (C_Spell and C_Spell.GetSpellInfo) then
		return text, 0
	end

	local count = 0
	-- Only rewrite /cast lines. /use is deliberately excluded: many items share a
	-- name with a spell (Hearthstone is both item 6948 and spell 8690), so a
	-- name-based lookup on a /use line silently rebinds an ITEM reference to a
	-- SPELL. The expanded text can even look identical, which makes the mistake
	-- invisible until the two diverge. Items must be tokenized explicitly.
	local out = text:gsub("(\n?)(/%a+)([^\n]*)", function(nl, cmd, rest)
		local lower = cmd:lower()
		if lower ~= "/cast" then
			return nil
		end
		-- Preserve any [conditions] prefix untouched.
		local conds, name = rest:match("^(%s*%b[]%s*)(.+)$")
		if not conds then
			conds, name = rest:match("^(%s*)(.+)$")
		end
		if not name or name == "" or name:find("{{", 1, true) then
			return nil
		end
		local trimmed = name:match("^(.-)%s*$")
		local ok, info = pcall(C_Spell.GetSpellInfo, trimmed)
		if not ok or type(info) ~= "table" or not info.spellID then
			return nil
		end
		-- Round-trip check: the id must resolve back to the same name, or the
		-- lookup was ambiguous and we must not touch it.
		if resolveSpell(info.spellID) ~= trimmed then
			return nil
		end
		count = count + 1
		return nl .. cmd .. conds .. "{{spell:" .. info.spellID .. "}}"
	end)
	return out, count
end
