-- core/conditionals/EvalToken.lua
--
-- The custom-conditional dispatcher, extracted from core/GUI.lua. One function,
-- EvalCustomToken, which turns a single token ("bank", "noprey", "level:70",
-- "available:slot3") into true or false. Everything it needs to answer the
-- question lives in the sibling files; this one owns the token grammar:
--
--   * `no` prefix negation — stripped only when the remainder is a known custom
--     token, so a real token that happens to start with "no" is not mangled.
--   * `base:arg` split, base lowercased, arg left in its original case (the
--     [available:<key>] providers match keys case-sensitively).
--   * the combat-sampled shortcut — in lockdown, listed tokens return their
--     frozen value from Vocabulary.lua instead of reading live state.
--
-- Then a long if/elseif over the base token. Ordering is by concern (frames,
-- location, identity, content, flight, pet/weapon, combat-sampled), matching
-- the grouping of CUSTOM_VIS_CONDITIONALS in Vocabulary.lua — when adding a
-- token, add it in both places and in the two tables named in that file's
-- warning comment.
--
-- Loaded after Predicates.lua and before ConditionString.lua.

local addonName, Wise = ...

local pcall = pcall
local tostring = tostring
local InCombatLockdown = InCombatLockdown
local C_PvP = C_PvP
local C_HousingNeighborhood = C_HousingNeighborhood
local Enum = Enum
local UnitName = UnitName
local UnitClass = UnitClass
local UnitRace = UnitRace
local UnitLevel = UnitLevel
local UnitPower = UnitPower
local UnitExists = UnitExists
local UnitFactionGroup = UnitFactionGroup
local GetRealZoneText = GetRealZoneText
local GetSubZoneText = GetSubZoneText
local GetInstanceInfo = GetInstanceInfo
local GetUnitSpeed = GetUnitSpeed
local GetWeaponEnchantInfo = GetWeaponEnchantInfo
local IsFalling = IsFalling
local HasPetUI = HasPetUI

local E = Wise.CondEngine or {}
Wise.CondEngine = E

-- Vocabulary + state.
local CUSTOM_VIS_CONDITIONALS = E.CUSTOM_VIS_CONDITIONALS
local COMBAT_SAMPLED = E.COMBAT_SAMPLED
local combatSamples = E.combatSamples
local NoteCombatSampledToken = E.NoteCombatSampledToken
local IsGroupAvailableNow = E.IsGroupAvailableNow

-- Argument matchers.
local ArgMatches = E.ArgMatches
local ArgMatchesAny = E.ArgMatchesAny
local AtLeast = E.AtLeast
local HasProfession = E.HasProfession

-- Game-state predicates.
local IsZoneAbilityActive = E.IsZoneAbilityActive
local IsSpellOrItemReady = E.IsSpellOrItemReady
local HasItemInBags = E.HasItemInBags
local IsWarbandBankAvailable = E.IsWarbandBankAvailable
local IsInActiveDelve = E.IsInActiveDelve
local GetActivePrey = E.GetActivePrey
local GetActiveKeystone = E.GetActiveKeystone
local GetCovenantToken = E.GetCovenantToken
local SlotHasUsableItem = E.SlotHasUsableItem
local IsSuperFlyable = E.IsSuperFlyable
local IsPlainFlyable = E.IsPlainFlyable
local IsMouseOverWorld = E.IsMouseOverWorld
local IsFlightBlocked = E.IsFlightBlocked
local HasAura = E.HasAura

-- Evaluate a single custom conditional token. Returns true/false.
-- `groupName` provides context for group-scoped tokens such as [available].
-- `forceLive` bypasses the frozen-sample shortcut; the combat-entry sampler uses
-- it to read the true value at the moment lockdown begins.
local function EvalCustomToken(token, groupName, forceLive)
	local negated = false
	local t = token:match("^%s*(.-)%s*$") -- trim
	if t:sub(1, 2) == "no" and not CUSTOM_VIS_CONDITIONALS[t:lower()] then
		negated = true
		t = t:sub(3)
	end
	local base = t:match("^([^:]+)") or t
	base = base:lower()
	local arg = t:match("^[^:]+:(.+)$")

	-- Combat-sampled tokens: out of combat evaluate live and record the token so
	-- combat entry knows to sample it; in combat return the frozen value.
	if COMBAT_SAMPLED[base] then
		NoteCombatSampledToken(t)
		-- InCombatLockdown is hoisted to an upvalue at the top of this file, so a
		-- test cannot stub it via _G. Wise._forceCombatSampling is the seam that
		-- makes the freeze path reachable from tests; it is nil in normal play.
		local locked = Wise._forceCombatSampling
		if locked == nil then
			locked = InCombatLockdown()
		end
		if locked and not forceLive then
			local result = combatSamples[t] or false
			if negated then
				result = not result
			end
			return result
		end
	end

	local result = false
	if base == "bank" then
		result = BankFrame and BankFrame:IsShown() or false
	elseif base == "guildbank" then
		result = GuildBankFrame and GuildBankFrame:IsShown() or false
	elseif base == "mailbox" then
		result = MailFrame and MailFrame:IsShown() or false
	elseif base == "auctionhouse" then
		result = AuctionHouseFrame and AuctionHouseFrame:IsShown() or false
	elseif base == "zoneability" then
		result = IsZoneAbilityActive()
	elseif base == "available" then
		-- [available] asks about the interface as a whole; [available:<key>] asks
		-- about one named part of it (a slot). The key keeps its original case —
		-- providers match it against their own slot names.
		local key = t:match("^[^:]+:(.+)$")
		result = IsGroupAvailableNow(groupName, key)

	-- Location. [zone:] matches either the real zone or the sub-zone, so
	-- [zone:Dornogal] and [zone:The Radiant Sanctum] both work.
	elseif base == "zone" then
		result = ArgMatches(arg, GetRealZoneText()) or ArgMatches(arg, GetSubZoneText())
	elseif base == "instance" or base == "in" then
		local _, instanceType = GetInstanceInfo()
		if arg and arg ~= "" then
			for piece in arg:lower():gmatch("[^/]+") do
				piece = piece:match("^%s*(.-)%s*$")
				-- "delve" is a Wise-only synonym: matches only the narrower Delve
				-- check, not every scenario. [instance:scenario] is untouched and
				-- still matches ALL scenario content, delves included.
				if piece == "delve" then
					if IsInActiveDelve() then
						result = true
						break
					end
				elseif piece == instanceType then
					result = true
					break
				end
			end
		else
			result = true
		end

	-- Character identity.
	elseif base == "me" then
		local _, class = UnitClass("player")
		result = ArgMatches(arg, UnitName("player")) or ArgMatches(arg, class)
	elseif base == "level" then
		result = AtLeast(arg, UnitLevel("player"))
	elseif base == "race" then
		local raceName, raceToken = UnitRace("player")
		result = ArgMatches(arg, raceToken) or ArgMatches(arg, raceName)
	elseif base == "game" then
		-- Wise is retail-only, so the only version token that can match is "modern".
		result = ArgMatches(arg, "modern")
	elseif base == "horde" then
		result = UnitFactionGroup("player") == "Horde"
	elseif base == "alliance" then
		result = UnitFactionGroup("player") == "Alliance"
	elseif base == "mercenary" or base == "merc" then
		result = (C_PvP and C_PvP.IsMercenary and C_PvP.IsMercenary()) or false
	elseif base == "prof" then
		result = HasProfession(arg)

	-- ── Extended content-state tokens ──────────────────────────────────
	elseif base == "warbank" then
		result = IsWarbandBankAvailable()
	elseif base == "prey" then
		-- Bare [prey] = hunting anything; [prey:12345] = that specific quest.
		local qid = GetActivePrey()
		result = qid ~= nil and ArgMatches(arg, qid)
	elseif base == "housereturn" then
		local ok, v = pcall(function()
			return C_HousingNeighborhood
				and C_HousingNeighborhood.CanReturnAfterVisitingHouse
				and C_HousingNeighborhood.CanReturnAfterVisitingHouse()
		end)
		result = ok and v and true or false
	elseif base == "myth" then
		-- Value is "mapID/name", so alternatives exist on both sides.
		local key = GetActiveKeystone()
		result = key ~= nil and ArgMatchesAny(arg, key)
	elseif base == "coven" or base == "covenant" then
		local cov = GetCovenantToken()
		result = cov ~= nil and (arg == nil or arg == "" or ArgMatchesAny(arg, cov))
	elseif base == "uslot" then
		if arg and arg ~= "" then
			for piece in arg:lower():gmatch("[^/]+") do
				piece = piece:match("^%s*(.-)%s*$")
				if piece ~= "" and SlotHasUsableItem(piece) then
					result = true
					break
				end
			end
		end
	elseif base == "superflyable" then
		result = IsSuperFlyable()
	elseif base == "blockedflyable" then
		result = IsFlightBlocked()
	elseif base == "anyflyable" then
		result = IsSuperFlyable() or (IsPlainFlyable() and not IsFlightBlocked())
	elseif base == "worldhover" then
		result = IsMouseOverWorld()

	-- Pet / weapon state.
	elseif base == "havepet" then
		result = UnitExists("pet") and ArgMatches(arg, UnitName("pet")) or false
	elseif base == "petcontrol" then
		result = (HasPetUI and HasPetUI()) and true or false
	elseif base == "imbuedmh" then
		local hasMH = GetWeaponEnchantInfo()
		result = hasMH and true or false
	elseif base == "imbuedoh" then
		local _, _, _, _, hasOH = GetWeaponEnchantInfo()
		result = hasOH and true or false

	-- Combat-sampled. Reached only out of combat; the in-combat path returned the
	-- frozen sample above.
	elseif base == "moving" then
		local speedFn = GetUnitSpeed or _G.GetUnitSpeed
		result = speedFn and (speedFn("player") or 0) > 0 or false
	elseif base == "falling" then
		result = IsFalling and IsFalling() and true or false
	elseif base == "ready" then
		result = IsSpellOrItemReady(arg)
	elseif base == "have" then
		result = HasItemInBags(arg)
	elseif base == "buff" then
		result = HasAura("target", arg, "HELPFUL")
	elseif base == "debuff" then
		result = HasAura("target", arg, "HARMFUL")
	elseif base == "selfbuff" then
		result = HasAura("player", arg, "HELPFUL")
	elseif base == "selfdebuff" then
		result = HasAura("player", arg, "HARMFUL")
	elseif base == "combo" then
		result = AtLeast(arg, UnitPower("player", Enum.PowerType.ComboPoints))
	end

	if negated then
		result = not result
	end
	return result
end

-- Published to the engine's internals. Vocabulary.lua's combat sampler reads
-- this back off E at call time, and ConditionString.lua takes it as an upvalue.
E.EvalCustomToken = EvalCustomToken
