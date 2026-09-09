-- core/conditionals/Predicates.lua
--
-- Game-state queries behind the custom conditionals, extracted from
-- core/GUI.lua. Each function answers exactly one question about the world
-- ("is this spell ready?", "am I in a delve?", "is flight suppressed here?")
-- and returns a plain value; none of them parse tokens or know about the
-- conditional syntax — EvalToken.lua does that and calls these.
--
-- Grouped as: readiness (GCDEndTime, IsSpellOrItemReady, HasItemInBags),
-- content state (IsWarbandBankAvailable, IsInActiveDelve, GetActivePrey,
-- GetActiveKeystone, GetCovenantToken) and equipment (SlotHasUsableItem).
-- Flight, mouse-over-world and aura checks are in Environment.lua, split off to
-- keep both files inside the 100-300 line target in AGENTS.md.
--
-- These are the volatile ones: they call live C_* APIs, several are on the
-- combat-sampled list in Vocabulary.lua, and they are where client-version
-- fallbacks accumulate. Argument matching lives next door in ArgMatch.lua so
-- that logic stays free of API churn.
--
-- Loaded after ArgMatch.lua and before Environment.lua.

local addonName, Wise = ...

local ipairs = ipairs
local pcall = pcall
local tonumber = tonumber
local tostring = tostring
local math = math
local table = table
local C_Spell = C_Spell
local C_Item = C_Item
local C_Bank = C_Bank
local C_Covenants = C_Covenants
local C_DelvesUI = C_DelvesUI
local C_QuestLog = C_QuestLog
local C_ChallengeMode = C_ChallengeMode
local C_PlayerInfo = C_PlayerInfo
local C_UnitAuras = C_UnitAuras
local C_UIWidgetManager = C_UIWidgetManager
local UnitExists = UnitExists

local E = Wise.CondEngine or {}
Wise.CondEngine = E

-- Argument matchers from ArgMatch.lua, pulled into upvalues at load time
-- (that file loads first, so these are already populated).
local ArgMatches = E.ArgMatches
local AtLeast = E.AtLeast

-- Secret-value probe. Hoisted to a named local and passed to pcall by reference
-- so no closure is allocated per call — HasAura runs on the per-button state
-- pass. Mirrors the identical helper in core/GUI.lua, which keeps its own copy
-- for the cooldown/charge read paths.
local function checkSecret(val)
	return issecretvalue and issecretvalue(val)
end

-- hasted character. Returns the timestamp the GCD ends, or math.huge if unknown.
local function GCDEndTime()
	if not (C_Spell and C_Spell.GetSpellCooldown) then
		return math.huge
	end
	local ok, info = pcall(C_Spell.GetSpellCooldown, 61304)
	if not ok or not info or not info.startTime or not info.duration then
		return math.huge
	end
	return info.startTime + info.duration
end

-- [ready:spell] — spell or item is off cooldown, ignoring the GCD.
-- A spell whose cooldown ends within the GCD counts as ready: you are about to
-- be able to cast it, and a bar that hides for the length of every global would
-- flicker constantly.
local function IsSpellOrItemReady(arg)
	if not arg or arg == "" then
		return false
	end
	local gcdEnd = GCDEndTime()

	-- Each /-separated alternative is checked; any one ready satisfies the token.
	for piece in tostring(arg):gmatch("[^/]+") do
		piece = piece:match("^%s*(.-)%s*$")
		if piece ~= "" then
			local id = tonumber(piece) or piece

			-- Spell first. An unknown spell yields no usable cooldown info, in which
			-- case we must FALL THROUGH to the item lookup rather than returning —
			-- C_Spell.GetSpellCooldown can hand back a table for a name it does not
			-- know, which would otherwise swallow every item argument.
			local handled = false
			if C_Spell and C_Spell.GetSpellCooldown then
				local ok, info = pcall(C_Spell.GetSpellCooldown, id)
				if ok and info and info.duration then
					handled = true
					local duration = info.duration or 0
					if duration == 0 then
						return true
					end
					local endsAt = (info.startTime or 0) + duration
					if endsAt <= gcdEnd then
						return true
					end
				end
			end

			-- Item fallback. C_Item.GetItemCooldown returns start=0,duration=0 for an
			-- item that DOES NOT EXIST, which is indistinguishable from a real item
			-- that is off cooldown — so [ready:NoSuchThing] reported true. Confirm
			-- the item resolves first; GetItemInfoInstant returns nil for garbage.
			if not handled and C_Item and C_Item.GetItemCooldown then
				local resolves = false
				if C_Item.GetItemInfoInstant then
					local infoOk, itemID = pcall(C_Item.GetItemInfoInstant, id)
					resolves = infoOk and itemID ~= nil
				end
				if resolves then
					local ok, start, duration = pcall(C_Item.GetItemCooldown, id)
					if ok and start then
						if (duration or 0) == 0 then
							return true
						end
						if (start + duration) <= gcdEnd then
							return true
						end
					end
				end
			end
		end
	end
	return false
end

-- [have:item] — item is present in bags.
local function HasItemInBags(arg)
	if not arg or arg == "" then
		return false
	end
	if not (C_Item and C_Item.GetItemCount) then
		return false
	end
	local id = tonumber(arg) or arg
	local ok, count = pcall(C_Item.GetItemCount, id)
	return ok and (count or 0) > 0
end

-- ── Extended content-state conditionals ─────────────────────────────────────

-- [warbank] — the warband bank is reachable. FetchBankLockedReason(2) returns a
-- reason code when it is NOT available, and nil when it is.
local function IsWarbandBankAvailable()
	if not (C_Bank and C_Bank.FetchBankLockedReason) then
		return false
	end
	local ok, reason = pcall(C_Bank.FetchBankLockedReason, 2)
	return ok and reason == nil
end

-- Delves report instanceType == "scenario" just like several other content
-- types, so native [instance:scenario] can't tell a Delve apart from the rest.
-- [instance:delve]/[in:delve] is a Wise-only synonym for the narrower check;
-- [instance:scenario] is untouched and still matches ALL scenario content.
local function IsInActiveDelve()
	if not (C_DelvesUI and C_DelvesUI.HasActiveDelve) then
		return false
	end
	local ok, v = pcall(C_DelvesUI.HasActiveDelve)
	return ok and v and true or false
end

-- [prey] / [prey:questID] — hunting Prey. Gated on the widget's shownState as
-- well as the quest being active, because the quest can linger while the hunt
-- is not actually running.
local PREY_WIDGET_ID = 7663
local function GetActivePrey()
	if not (C_QuestLog and C_QuestLog.GetActivePreyQuest) then
		return nil
	end
	local ok, qid = pcall(C_QuestLog.GetActivePreyQuest)
	if not ok or not qid then
		return nil
	end
	local doneOk, isComplete = pcall(C_QuestLog.IsComplete, qid)
	if doneOk and isComplete then
		return nil
	end
	if C_UIWidgetManager and C_UIWidgetManager.GetPreyHuntProgressWidgetVisualizationInfo then
		local vOk, viz = pcall(C_UIWidgetManager.GetPreyHuntProgressWidgetVisualizationInfo, PREY_WIDGET_ID)
		if not vOk or not viz or viz.shownState ~= 1 then
			return nil
		end
	end
	return tostring(qid)
end

-- [myth] / [myth:token] — an M+ keystone run is active. The bare form is true
-- during any run; the argument form matches the dungeon's map ID or its name.
local function GetActiveKeystone()
	if not (C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo) then
		return nil
	end
	local ok, level = pcall(C_ChallengeMode.GetActiveKeystoneInfo)
	if not ok or not level or level <= 0 then
		return nil
	end
	local mapOk, mapID = pcall(C_ChallengeMode.GetActiveChallengeMapID)
	if not mapOk or not mapID then
		return tostring(level)
	end
	local nameOk, name = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
	return (nameOk and name) and (tostring(mapID) .. "/" .. tostring(name)) or tostring(mapID)
end

-- [coven:kyrian/venthyr/fae/necro] — Shadowlands covenant. Index order matches
-- Blizzard's covenant IDs; each entry carries both a short and long spelling.
local COVENANT_TOKENS = {
	[1] = "kyrian",
	[2] = "venthyr",
	[3] = "fae/nightfae",
	[4] = "necro/necrolord",
}
local function GetCovenantToken()
	if not (C_Covenants and C_Covenants.GetActiveCovenantID) then
		return nil
	end
	local ok, id = pcall(C_Covenants.GetActiveCovenantID)
	if not ok or not id or id == 0 then
		return nil
	end
	return COVENANT_TOKENS[id]
end

-- [uslot:trinket1/head/...] — an equipped item in that slot has an ON-USE effect.
-- Resolves the item's spell and rejects passives; a slot whose item merely has
-- a passive proc must not satisfy this.
local USLOT_SLOTS = {
	head = "HEADSLOT",
	neck = "NECKSLOT",
	shoulders = "SHOULDERSLOT",
	shirt = "SHIRTSLOT",
	chest = "CHESTSLOT",
	waist = "WAISTSLOT",
	legs = "LEGSSLOT",
	feet = "FEETSLOT",
	wrist = "WRISTSLOT",
	hands = "HANDSSLOT",
	finger1 = "FINGER0SLOT",
	finger2 = "FINGER1SLOT",
	trinket1 = "TRINKET0SLOT",
	trinket2 = "TRINKET1SLOT",
	back = "BACKSLOT",
	tabard = "TABARDSLOT",
}
local function SlotHasUsableItem(token)
	local slotKey = USLOT_SLOTS[token]
	if not slotKey then
		return false
	end
	local okSlot, slotIndex = pcall(GetInventorySlotInfo, slotKey)
	if not okSlot or not slotIndex then
		return false
	end
	local link = GetInventoryItemLink and GetInventoryItemLink("player", slotIndex)
	local ref = link or (GetInventoryItemID and GetInventoryItemID("player", slotIndex))
	if not ref then
		return false
	end
	if not (C_Item and C_Item.GetItemSpell) then
		return false
	end
	local okSpell, _, spellID = pcall(C_Item.GetItemSpell, ref)
	if not okSpell or not spellID then
		return false
	end
	local okPassive, isPassive = pcall(IsPassiveSpell, spellID)
	return okPassive and not isPassive
end

-- Published to the engine's internals for EvalToken.lua. Flight, mouse-over-world
-- and aura checks live in Environment.lua, which loads next.
E.IsSpellOrItemReady = IsSpellOrItemReady
E.HasItemInBags = HasItemInBags
E.IsWarbandBankAvailable = IsWarbandBankAvailable
E.IsInActiveDelve = IsInActiveDelve
E.GetActivePrey = GetActivePrey
E.GetActiveKeystone = GetActiveKeystone
E.GetCovenantToken = GetCovenantToken
E.SlotHasUsableItem = SlotHasUsableItem
