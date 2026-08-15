-- DisenchantConvert.lua
-- Wiser interface backed by auction-house price data (TSM / ProfitProphet / Auctionator).
--
-- ONE interface, "Disenchant/Convert", holding two slots that are each
-- dynamically loaded out of combat with the bag items that match:
--   Slot 1 Disenchant — item is worth more disenchanted than vendored/auctioned.
--   Slot 2 Convert    — stack is worth more prospected/milled than kept as-is.
--
-- Each slot is one button whose action targets the top-ranked item for that slot;
-- the matching items live in the slot's action list, so the bar stays two
-- buttons wide regardless of how many items qualify.
--
-- Each slot shows INDEPENDENTLY, gated on [available:<slot>]: if only ore is
-- convertible, only the Convert button appears. The group is `dynamic` because
-- only dynamic groups evaluate per-slot conditions.
--
-- NOTE: `propertyType` and the SavedVariables keys deliberately keep their
-- original "VendorDisenchantConvert"/`vdc*` spelling even though the Vendor slot
-- and the file name are gone — propertyType is the key the migration matches on,
-- so renaming it would strand existing saved settings.
--
-- NOTE: there is deliberately no Vendor slot. Deciding "should this be sold"
-- depends on too many variables to resolve behind a single click (bind state,
-- transmog value, reagent demand, alt usage, upgrade paths), and a wrong answer
-- destroys an item irreversibly. The vendor PRICE is still computed — it is the
-- baseline both remaining slots must beat.
--
-- Pressing a slot acts on the FIRST item in its list; the list re-sorts on the
-- next bag update, so repeated presses walk the queue. Convert alternates between
-- distinct source items on each press (see BuildConvertMacro) because different
-- salvage spells sit on different cooldowns/GCDs — alternating lets a second
-- conversion fire while the first is still on GCD.
--
-- SECURITY: each slot is a secure button written out of combat only (AGENTS.md
-- Rule 1), using type="spell" plus target-bag/target-slot attributes. There is no
-- macrotext: 11.x removed macrotext execution of protected actions, and a bare
-- `/use <bag> <slot>` would EQUIP a wearable item instead of feeding it to the
-- spell (see BuildDisenchantMacro).

local addonName, Wise = ...

local VDC = {}
Wise.VDC = VDC

-- One interface holding both slots.
VDC.GROUP_NAME = "Disenchant/Convert"

-- Slot keys, in bar order. The names double as the per-slot filter keys and the
-- labels shown in the properties panel.
VDC.SLOT_DISENCHANT = "Disenchant"
VDC.SLOT_CONVERT = "Convert"
VDC.SLOT_ORDER = { VDC.SLOT_DISENCHANT, VDC.SLOT_CONVERT }

-- Prospecting and milling consume a fixed batch of the source item per cast.
-- Both were 5 through Dragonflight; TWW (10) and Midnight (11) milling eat 10.
local PROSPECT_BATCH = 5
local MILL_BATCH_DEFAULT = 5
local MILL_BATCH_BY_EXPANSION = { [10] = 10, [11] = 10 }

-- Per-expansion salvage spells. The base Prospecting/Milling spells are no longer
-- player-castable in retail (Dragonflight profession revamp) — each expansion has
-- its own spell. Mirrors ProfitProphet's verified SALVAGE map; an unmapped
-- expansion yields no castable spell, so the item is skipped rather than arming a
-- dead cast.
local SALVAGE = {
	[1] = { prospect = 382980 },
	[9] = { prospect = 374627, mill = 382981 },
	[10] = { prospect = 434018, mill = 444181 },
	[11] = { prospect = 1231127, mill = 1269575 },
}

local DISENCHANT_SPELL_ID = 13262

-- Fallback icons shown when a slot has no qualifying items, so the slot stays
-- recognisable on the bar instead of collapsing to a question mark.
local SLOT_EMPTY_ICON = {
	Disenchant = 136244, -- Enchanting
	Convert = 134435, -- Prospecting/gem
}

-- Equip locations that can be disenchanted (armor and weapons only).
local DE_EQUIPLOCS = {
	INVTYPE_HEAD = true,
	INVTYPE_NECK = true,
	INVTYPE_SHOULDER = true,
	INVTYPE_CLOAK = true,
	INVTYPE_CHEST = true,
	INVTYPE_ROBE = true,
	INVTYPE_WRIST = true,
	INVTYPE_HAND = true,
	INVTYPE_WAIST = true,
	INVTYPE_LEGS = true,
	INVTYPE_FEET = true,
	INVTYPE_FINGER = true,
	INVTYPE_TRINKET = true,
	INVTYPE_SHIELD = true,
	INVTYPE_HOLDABLE = true,
	INVTYPE_RANGED = true,
	INVTYPE_RANGEDRIGHT = true,
	INVTYPE_THROWN = true,
	INVTYPE_RELIC = true,
	INVTYPE_WEAPON = true,
	INVTYPE_2HWEAPON = true,
	INVTYPE_WEAPONMAINHAND = true,
	INVTYPE_WEAPONOFFHAND = true,
}

-- Default per-slot filters. Stored on the group so each slot is independently
-- configurable from the properties panel.
local DEFAULT_FILTERS = {
	Disenchant = { minValue = 0, minQuality = 2, maxQuality = 4, minILvl = 0, maxILvl = 0, minMargin = 0, maxItems = 24 },
	Convert = { minValue = 0, minQuality = 0, maxQuality = 5, minILvl = 0, maxILvl = 0, minMargin = 0, maxItems = 24 },
}

-- ---------------------------------------------------------------------------
-- Price sources
-- ---------------------------------------------------------------------------

-- Which pricing addon is providing data. Resolved lazily so load order and
-- on-demand (LoadOnDemand) addons are handled.
function VDC:GetPriceProvider()
	if TSM_API and TSM_API.GetCustomPriceValue then
		return "TSM"
	end
	if PP and PP.Destroying and PP.Destroying.deValueOf then
		return "PP"
	end
	if Auctionator and Auctionator.API and Auctionator.API.v1 then
		return "Auctionator"
	end
	return nil
end

function VDC:IsAvailable()
	return self:GetPriceProvider() ~= nil
end

-- Evaluate a TSM custom price string. TSM errors on malformed strings and on
-- items it cannot resolve, so every call is pcall-guarded and a nil result is
-- treated as "no data" rather than zero — zero would make everything look
-- profitable to vendor.
local function tsmValue(priceStr, itemLink)
	if not (TSM_API and TSM_API.GetCustomPriceValue) then
		return nil
	end
	local ok, itemString = pcall(TSM_API.ToItemString, itemLink)
	if not ok or not itemString then
		return nil
	end
	local okVal, value = pcall(TSM_API.GetCustomPriceValue, priceStr, itemString)
	if not okVal or type(value) ~= "number" then
		return nil
	end
	return value
end

-- Market (auction) value of one item, in copper. nil when unknown.
function VDC:GetMarketValue(itemLink, itemID)
	local provider = self:GetPriceProvider()
	if provider == "TSM" then
		return tsmValue("dbmarket", itemLink)
	elseif provider == "Auctionator" and Auctionator.API.v1.GetAuctionPriceByItemLink then
		local ok, value = pcall(Auctionator.API.v1.GetAuctionPriceByItemLink, addonName, itemLink)
		if ok and type(value) == "number" then
			return value
		end
	end
	return nil
end

-- Vendor sell price of one item, in copper. Read straight from the item info —
-- this is authoritative and needs no pricing addon.
function VDC:GetVendorValue(itemLink)
	local sellPrice = select(11, C_Item.GetItemInfo(itemLink))
	if type(sellPrice) ~= "number" or sellPrice <= 0 then
		return nil
	end
	return sellPrice
end

-- Expected disenchant material value of one item, in copper. nil when unknown.
function VDC:GetDisenchantValue(itemLink, quality, ilvl, itemID)
	if TSM_API and TSM_API.GetCustomPriceValue then
		local value = tsmValue("destroy", itemLink)
		if value and value > 0 then
			return value
		end
	end
	if PP and PP.Destroying and PP.Destroying.deValueOf then
		local ok, value = pcall(PP.Destroying.deValueOf, itemLink)
		if ok and type(value) == "number" and value > 0 then
			return value
		end
	end
	return nil
end

-- Expected conversion (prospect/mill) value for ONE source item, plus the kind
-- of conversion and how many source items a single cast consumes.
-- Returns: perItemValue, kind ("prospect"|"mill"), batchSize  — or nil.
function VDC:GetConvertValue(itemLink, itemID)
	if not itemID then
		return nil
	end
	local expansion = select(15, C_Item.GetItemInfo(itemLink))
	local kind
	if PP and PP.ProspectRetail and PP.ProspectRetail.isOre and PP.ProspectRetail.isOre(itemID) then
		kind = "prospect"
	elseif PP and PP.MillRetail and PP.MillRetail.isHerb and PP.MillRetail.isHerb(itemID) then
		kind = "mill"
	else
		return nil
	end

	local batch = PROSPECT_BATCH
	if kind == "mill" then
		batch = MILL_BATCH_BY_EXPANSION[expansion] or MILL_BATCH_DEFAULT
	end

	-- Prefer TSM's own conversion valuation when present; it tracks the same
	-- per-one-source convention (amountOfMats bakes the batch divisor in).
	local value
	if TSM_API and TSM_API.GetCustomPriceValue then
		value = tsmValue("convert", itemLink)
	end
	if not value or value <= 0 then
		local fn = (kind == "prospect") and PP and PP.ProspectRetail and PP.ProspectRetail.value
			or (PP and PP.MillRetail and PP.MillRetail.value)
		if fn then
			local ok, v = pcall(fn, itemID)
			if ok and type(v) == "number" then
				value = v
			end
		end
	end

	if not value or value <= 0 then
		return nil
	end
	return value, kind, batch
end

-- ---------------------------------------------------------------------------
-- Ignore list & equipment-set protection
-- ---------------------------------------------------------------------------

-- Per-item opt-out, keyed by itemID. Right-clicking a slot ignores whatever that
-- slot was about to act on, so a queue can be pruned without opening the bags.
function VDC:GetIgnored(group)
	group.vdcIgnored = group.vdcIgnored or {}
	return group.vdcIgnored
end

function VDC:IsIgnored(group, itemID)
	if not itemID then
		return false
	end
	return self:GetIgnored(group)[itemID] and true or false
end

function VDC:SetIgnored(group, itemID, ignored)
	if not itemID then
		return
	end
	self:GetIgnored(group)[itemID] = ignored or nil
end

-- Item IDs that belong to any saved equipment set, rebuilt on demand. Gear the
-- player has deliberately saved into a set is almost never meant to be destroyed,
-- so this is on by default (vdcProtectEquipmentSets).
--
-- C_EquipmentSet.GetItemIDs returns a slot->itemID map (with nil holes for empty
-- slots), so it is iterated with pairs, not ipairs.
function VDC:GetEquipmentSetItemIDs()
	local ids = {}
	if not (C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs) then
		return ids
	end
	local setIDs = C_EquipmentSet.GetEquipmentSetIDs()
	if not setIDs then
		return ids
	end
	for _, setID in ipairs(setIDs) do
		local itemIDs = C_EquipmentSet.GetItemIDs(setID)
		if itemIDs then
			for _, itemID in pairs(itemIDs) do
				-- Empty slots are reported as 0 or the "ignored slot" sentinel; both
				-- are meaningless as item IDs.
				if type(itemID) == "number" and itemID > 0 then
					ids[itemID] = true
				end
			end
		end
	end
	return ids
end

-- ---------------------------------------------------------------------------
-- Filters
-- ---------------------------------------------------------------------------

function VDC:GetFilters(group, slotKey)
	group.vdcFilters = group.vdcFilters or {}
	local existing = group.vdcFilters[slotKey]
	if not existing then
		existing = {}
		for k, v in pairs(DEFAULT_FILTERS[slotKey] or DEFAULT_FILTERS.Disenchant) do
			existing[k] = v
		end
		group.vdcFilters[slotKey] = existing
	end
	return existing
end

-- Does this candidate pass the slot's filters? `gain` is the copper advantage of
-- taking the action over the alternative; `alternative` is what it is measured
-- against, used for the percentage-margin test.
local function passesFilters(filters, quality, ilvl, gain, alternative)
	if quality and filters.minQuality and quality < filters.minQuality then
		return false
	end
	if quality and filters.maxQuality and filters.maxQuality > 0 and quality > filters.maxQuality then
		return false
	end
	if ilvl and filters.minILvl and filters.minILvl > 0 and ilvl < filters.minILvl then
		return false
	end
	if ilvl and filters.maxILvl and filters.maxILvl > 0 and ilvl > filters.maxILvl then
		return false
	end
	-- minValue is stored in GOLD (the unit the options panel shows); every
	-- valuation here is in copper, so scale before comparing.
	if filters.minValue and filters.minValue > 0 and gain < (filters.minValue * COPPER_PER_GOLD) then
		return false
	end
	-- Percentage margin: how much better the action is than the alternative.
	-- Guarded against a zero alternative (division by zero when an item has no
	-- vendor price at all).
	if filters.minMargin and filters.minMargin > 0 then
		if not alternative or alternative <= 0 then
			return false
		end
		if (gain / alternative) * 100 < filters.minMargin then
			return false
		end
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Bag scanning
-- ---------------------------------------------------------------------------

-- Scan every bag slot once and bucket the results into the two lists. A single
-- pass feeds both slots so bag iteration cost is paid once per refresh.
-- Returns disenchant[], convert[] — each sorted by gain descending.
function VDC:ScanBags()
	local disenchant, convert = {}, {}
	local convertBySource = {}

	local group = WiseDB.groups[self.GROUP_NAME]
	if not group then
		return disenchant, convert
	end

	-- Both filter sets live on the single interface, keyed by slot.
	local deFilters = self:GetFilters(group, self.SLOT_DISENCHANT)
	local convertFilters = self:GetFilters(group, self.SLOT_CONVERT)

	local hasEnchanting = self:HasProfession("Enchanting")

	-- Exclusions. Both are cheap O(1) lookups per bag slot; the equipment-set map
	-- is built once per scan rather than per item.
	local ignored = self:GetIgnored(group)
	local protectSets = group.vdcProtectEquipmentSets
	if protectSets == nil then
		protectSets = true
	end
	local equipmentSetIDs = protectSets and self:GetEquipmentSetItemIDs() or nil

	-- Backpack + equipped bags, PLUS the reagent bag. Ore and herbs auto-store
	-- into the reagent bag, so omitting it leaves the Convert slot permanently
	-- empty on any character that has one.
	local bagsToScan = {}
	for bag = BACKPACK_CONTAINER, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
		table.insert(bagsToScan, bag)
	end
	if Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag then
		table.insert(bagsToScan, Enum.BagIndex.ReagentBag)
	end

	for _, bag in ipairs(bagsToScan) do
		local slots = C_Container.GetContainerNumSlots(bag)
		for slot = 1, slots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local itemLink = info and info.hyperlink
			-- Skip anything the player has opted out of, and (by default) anything
			-- saved into an equipment set — that gear is deliberately kept, and
			-- destroying it is irreversible.
			local excluded = info
				and info.itemID
				and (ignored[info.itemID] or (equipmentSetIDs and equipmentSetIDs[info.itemID]))
			if itemLink and not info.isLocked and not excluded then
				local itemID = info.itemID
				local count = info.stackCount or 1
				local name, _, quality, ilvl, _, _, _, _, equipLoc = C_Item.GetItemInfo(itemLink)
				-- An uncached item returns nil; skip it this pass rather than
				-- valuing it at zero. The next BAG_UPDATE re-evaluates it.
				if name then
					-- Vendor price is still computed: it is the floor an item is
					-- always worth, so both slots must beat it before suggesting
					-- destroying the item. There is no Vendor slot (see header).
					local vendorValue = self:GetVendorValue(itemLink)
					local marketValue = self:GetMarketValue(itemLink, itemID)

					-- DISENCHANT: worth more disenchanted than vendored or auctioned.
					local deCandidate = quality and DE_EQUIPLOCS[equipLoc]
							and self:GetDisenchantValue(itemLink, quality, ilvl, itemID)
						or nil
					if deCandidate then
						local deValue = deCandidate
						local baseline = math.max(vendorValue or 0, marketValue or 0)
						if deValue and deValue > baseline then
							local gain = deValue - baseline
							if passesFilters(deFilters, quality, ilvl, gain, baseline) then
								table.insert(disenchant, {
									itemLink = itemLink,
									itemID = itemID,
									bag = bag,
									slot = slot,
									count = count,
									quality = quality,
									ilvl = ilvl,
									gain = gain,
									value = deValue,
									hasEnchanting = hasEnchanting,
								})
							end
						end
					end

					-- CONVERT: worth more converted than kept. Needs a full batch
					-- in a single stack to fire one cast.
					local perItem, kind, batch = self:GetConvertValue(itemLink, itemID)
					if perItem and kind and batch then
						local keepValue = math.max(marketValue or 0, vendorValue or 0)
						if perItem > keepValue then
							-- Aggregate across bag slots: a cast consumes from the
							-- whole inventory, not one stack, so batch availability
							-- is a total-count question.
							local entry = convertBySource[itemID]
							if not entry then
								entry = {
									itemLink = itemLink,
									itemID = itemID,
									bag = bag,
									slot = slot,
									count = 0,
									quality = quality,
									ilvl = ilvl,
									kind = kind,
									batch = batch,
									perItem = perItem,
									gain = 0,
								}
								convertBySource[itemID] = entry
							end
							entry.count = entry.count + count
							entry.gain = (perItem - keepValue) * entry.count
						end
					end
				end
			end
		end
	end

	-- Only surface conversions we can actually cast: a full batch on hand, a
	-- known salvage spell for the source's expansion, and the filters passed.
	for _, entry in pairs(convertBySource) do
		if entry.count >= entry.batch and self:GetSalvageSpellName(entry.itemLink, entry.kind) then
			if passesFilters(convertFilters, entry.quality, entry.ilvl, entry.gain, nil) then
				table.insert(convert, entry)
			end
		end
	end

	local byGain = function(a, b)
		return a.gain > b.gain
	end
	table.sort(disenchant, byGain)
	table.sort(convert, byGain)

	self:Truncate(disenchant, deFilters.maxItems)
	self:Truncate(convert, convertFilters.maxItems)

	return disenchant, convert
end

function VDC:Truncate(list, maxItems)
	if not maxItems or maxItems <= 0 then
		return
	end
	for i = #list, maxItems + 1, -1 do
		list[i] = nil
	end
end

-- Does the player know a given profession? Used to decide whether Disenchant
-- casts the spell or falls back to mailing the items to an enchanter.
function VDC:HasProfession(professionName)
	local profs = { GetProfessions() }
	for _, index in ipairs(profs) do
		if index then
			local name = GetProfessionInfo(index)
			if name == professionName then
				return true
			end
		end
	end
	return false
end

-- Resolve the castable salvage spell for an item.
-- Returns: name, spellID — or nil when the source's expansion has no mapped
-- spell (in which case the item is not offered).
--
-- The ID matters as much as the name: the button stores the ID, because
-- Wise:IsActionKnown resolves a NAME back to an ID via C_Spell.GetSpellInfo,
-- which is unreliable for profession/salvage spells. A failed resolve makes the
-- action look unknown, and the renderer greys the icon out.
function VDC:GetSalvageSpellName(itemLink, kind)
	local expansion = select(15, C_Item.GetItemInfo(itemLink))
	local spellID = expansion and SALVAGE[expansion] and SALVAGE[expansion][kind]
	if not spellID then
		return nil
	end
	local info = C_Spell.GetSpellInfo(spellID)
	return info and info.name, spellID
end

-- ---------------------------------------------------------------------------
-- Destroy-confirmation dismissal (opt-in safety net)
-- ---------------------------------------------------------------------------

-- The "equipping this item will bind it to you" prompt is GONE by construction:
-- the slots cast via type="spell" + target-bag/target-slot, so there is no /use
-- line that could equip anything (see BuildDisenchantMacro).
--
-- What can still appear is Blizzard's DESTROY confirmation on soulbound gear
-- ("Disenchanting will destroy it"). StaticPopup buttons are protected, so Lua
-- cannot click them from an event handler — the click must come from a macro
-- line on a real hardware press.
--
-- The naive version of this ("/click StaticPopup1Button1") is WRONG twice over:
--   * StaticPopup1 is whichever dialog happens to occupy slot 1. If anything else
--     is open — a trade, a summon, a ready check — the macro clicks THAT dialog's
--     first button instead. Blind-confirming an arbitrary popup is exactly the
--     kind of accident this feature must not cause.
--   * The relevant popup may not be showing at all on any given press.
--
-- Instead this mirrors the approach WarPlan uses for the same problem: a
-- dedicated button that, on each PreClick, looks up the REAL popup by name via
-- StaticPopup_Visible() and points itself at that popup's own button1. When none
-- of the recognised popups is up it clears its attributes and does nothing.
local confirmButton

local DESTROY_POPUPS = {
	"CONFIRM_DESTROY_ITEM",
	"CONFIRM_LOOT_DISTRIBUTION",
	"USE_BIND",
	"EQUIP_BIND",
	"AUTOEQUIP_BIND",
}

function VDC:GetConfirmButton()
	if confirmButton then
		return confirmButton
	end

	local name = "WiseVDCConfirmBindButton"
	local b = CreateFrame("Button", name, nil, "SecureActionButtonTemplate")
	b:RegisterForClicks("AnyUp")
	b:Hide()

	b:SetScript("PreClick", function(self)
		if InCombatLockdown() then
			return
		end
		-- Resolve which recognised popup (if any) is actually on screen, and aim
		-- at its real accept button. Anything else showing is left strictly alone.
		local target
		for _, popupName in ipairs(DESTROY_POPUPS) do
			local _, frame = StaticPopup_Visible(popupName)
			if frame and frame.button1 and frame.button1:IsShown() then
				target = frame.button1:GetName()
				break
			end
		end
		if target then
			self:SetAttribute("type", "click")
			self:SetAttribute("clickbutton", _G[target])
		else
			self:SetAttribute("type", nil)
			self:SetAttribute("clickbutton", nil)
		end
	end)

	b:SetScript("PostClick", function(self)
		if InCombatLockdown() then
			return
		end
		self:SetAttribute("type", nil)
		self:SetAttribute("clickbutton", nil)
	end)

	confirmButton = b
	return b
end

-- ---------------------------------------------------------------------------
-- Macro construction
-- ---------------------------------------------------------------------------

-- Disenchant: cast Disenchant on the top item when the player is an enchanter.
-- Otherwise, when the mail window is open, attach the items and send them to the
-- configured enchanter alt.
function VDC:BuildDisenchantMacro(list, group)
	if #list == 0 then
		return nil
	end
	local entry = list[1]
	local spellInfo = C_Spell.GetSpellInfo(DISENCHANT_SPELL_ID)
	local spellName = spellInfo and spellInfo.name

	if entry.hasEnchanting and spellName then
		-- Applied via type="spell" + target-bag/target-slot, NOT macrotext.
		--
		-- This is the only sanctioned way to cast a spell onto a specific bag
		-- item. The modern (11.x+) engine REMOVED macrotext execution of
		-- protected actions, so the old "/cast Disenchant" + "/use <bag> <slot>"
		-- macro is forbidden ("only available to the Blizzard UI"). Worse, when
		-- the /cast half was suppressed the /use half still ran on its own, and
		-- "/use <bag> <slot>" on a wearable item EQUIPS it — which is exactly
		-- what raised the "equipping this item will bind it to you" prompt on
		-- every press.
		--
		-- With target-bag/target-slot, SecureActionButton_OnClick casts the spell
		-- and, once SpellCanTargetItem() is true, calls UseContainerItem(bag,
		-- slot) itself. There is no /use line and therefore no equip path and no
		-- bind prompt. Spam safety comes free: the button re-casts the same spell
		-- at the same target, and a press during the cast is simply ignored.
		--
		-- (target-item is NOT this — it routes to SpellTargetItem, which wants an
		-- item NAME.)
		-- Store the spell ID, not the name. type="spell" accepts either, but
		-- Wise:IsActionKnown resolves a name back to an ID via
		-- C_Spell.GetSpellInfo — unreliable for Disenchant — and a failed resolve
		-- marks the action unknown, which greys the icon out.
		return {
			secureType = "spell",
			secureValue = DISENCHANT_SPELL_ID,
			attributes = {
				["target-bag"] = entry.bag,
				["target-slot"] = entry.slot,
			},
		}
	end

	-- Mail fallback. Attaching items and sending mail is not protected, so this
	-- runs as a /run body driven by the module's own helper.
	local recipient = group and group.vdcMailTarget
	if not recipient or recipient == "" then
		return nil
	end
	return { secureType = "macro", secureValue = "/run Wise.VDC:MailDisenchantables()" }
end

-- Convert: alternate between distinct source items on each press.
--
-- Different salvage spells have independent cooldowns and the GCD applies per
-- cast, so firing the same source twice in a row stalls on the GCD. Rotating
-- through the available sources lets the next press act on a different spell
-- immediately.
--
-- Uses the same type="spell" + target-bag/target-slot path as Disenchant (see
-- BuildDisenchantMacro) — no macrotext, so no /use line that could equip the
-- source item, and no bind prompt. The rotation advances on each rebuild, so
-- holding the key chains conversions across different salvage spells.
function VDC:BuildConvertMacro(list, group)
	if #list == 0 then
		return nil
	end
	-- Advance the rotation pointer, wrapping over the current candidate count.
	self.convertIndex = ((self.convertIndex or 0) % #list) + 1
	local entry = list[self.convertIndex]
	local spellName, spellID = self:GetSalvageSpellName(entry.itemLink, entry.kind)
	if not (spellName and spellID) then
		return nil
	end
	-- ID, not name — see BuildDisenchantMacro.
	return {
		secureType = "spell",
		secureValue = spellID,
		attributes = {
			["target-bag"] = entry.bag,
			["target-slot"] = entry.slot,
		},
	}
end

-- Attach and send disenchantable items to the configured enchanter. Mail APIs are
-- insecure, so this is a normal Lua path. Only runs with the mail window open.
function VDC:MailDisenchantables()
	local group = WiseDB.groups[self.GROUP_NAME]
	local recipient = group and group.vdcMailTarget
	if not recipient or recipient == "" then
		print("|cff00ccff[Wise]|r Set a Disenchant mail target in the interface options first.")
		return
	end
	if not (MailFrame and MailFrame:IsShown()) then
		print("|cff00ccff[Wise]|r Open your mailbox to send disenchantables.")
		return
	end

	-- ScanBags now returns disenchant FIRST (the vendor list is gone), so this
	-- takes the first return, not the second.
	local list = self:ScanBags()
	if #list == 0 then
		print("|cff00ccff[Wise]|r No disenchantable items match the current filters.")
		return
	end

	-- One mail carries up to 12 attachments.
	local attached = 0
	for _, entry in ipairs(list) do
		if attached >= 12 then
			break
		end
		C_Container.UseContainerItem(entry.bag, entry.slot)
		attached = attached + 1
	end

	if attached > 0 then
		SendMail(recipient, "Disenchant", "")
		print(string.format("|cff00ccff[Wise]|r Sent %d item(s) to %s.", attached, recipient))
	end
end

-- ---------------------------------------------------------------------------
-- Cast tracking
-- ---------------------------------------------------------------------------

-- Is the player currently casting one of the destroy-style spells this module
-- drives? Used to hold off macro rebuilds so a spammed button cannot have its
-- target swapped mid-cast.
function VDC:IsDestroyCastInProgress()
	if not (UnitCastingInfo and UnitChannelInfo) then
		return false
	end
	local castName = UnitCastingInfo("player")
	if not castName then
		castName = UnitChannelInfo("player")
	end
	if not castName then
		return false
	end
	return self.destroySpellNames and self.destroySpellNames[castName] or false
end

-- Is this the spell ID of a destroy cast this module drives? Used to filter
-- UNIT_SPELLCAST_* so an unrelated cast never triggers a bag scan.
function VDC:IsDestroySpellID(spellID)
	if not spellID then
		return false
	end
	return self.destroySpellIDs and self.destroySpellIDs[spellID] or false
end

-- Cache the localized names AND the IDs of every spell that counts as a destroy
-- cast, so both checks are hash lookups rather than per-call spell resolution.
function VDC:BuildDestroySpellNameCache()
	local names, ids = {}, {}
	local function add(spellID)
		if not spellID then
			return
		end
		ids[spellID] = true
		local info = C_Spell.GetSpellInfo(spellID)
		if info and info.name then
			names[info.name] = true
		end
	end
	add(DISENCHANT_SPELL_ID)
	for _, spells in pairs(SALVAGE) do
		add(spells.prospect)
		add(spells.mill)
	end
	self.destroySpellNames = names
	self.destroySpellIDs = ids
end

-- ---------------------------------------------------------------------------
-- Tooltip
-- ---------------------------------------------------------------------------

-- The secure action is type="spell", so the default tooltip would show the
-- Disenchant/Prospecting spell — useless for deciding whether to press it. This
-- provider shows the actual QUEUE instead: what the next press destroys, then
-- everything behind it, so the player can spot something they don't want to lose
-- before clicking.
local MAX_TOOLTIP_ROWS = 12

function VDC:BuildSlotTooltip(tooltip, button, actionData)
	local slotKey = actionData and actionData.vdcSlot
	if not slotKey then
		return false
	end
	local list = self.lastLists and self.lastLists[slotKey]

	tooltip:SetText(slotKey, 1, 0.82, 0)

	if not list or #list == 0 then
		tooltip:AddLine("Nothing matches the current filters.", 0.6, 0.6, 0.6)
		return true
	end

	tooltip:AddLine(
		slotKey == self.SLOT_CONVERT and "Next conversion, then the queue:" or "Next to disenchant, then the queue:",
		0.8, 0.8, 0.8
	)
	tooltip:AddLine(" ")

	local shown = math.min(#list, MAX_TOOLTIP_ROWS)
	for i = 1, shown do
		local entry = list[i]
		local label = entry.itemLink or "?"
		local gain = GetCoinTextureString(math.floor(entry.gain or 0))
		if i == 1 then
			-- Mark the head of the queue: this is what the next press acts on.
			tooltip:AddDoubleLine("> " .. label, gain, 0.4, 1, 0.4, 1, 0.82, 0)
		else
			tooltip:AddDoubleLine("   " .. label, gain, 0.9, 0.9, 0.9, 0.8, 0.7, 0.3)
		end
	end

	if #list > shown then
		tooltip:AddLine(string.format("...and %d more", #list - shown), 0.6, 0.6, 0.6)
	end

	tooltip:AddLine(" ")
	tooltip:AddLine("Right-click: skip the top item from now on", 1, 0.5, 0.5)

	local group = WiseDB.groups[self.GROUP_NAME]
	local ignoredCount = 0
	if group and group.vdcIgnored then
		for _ in pairs(group.vdcIgnored) do
			ignoredCount = ignoredCount + 1
		end
	end
	if ignoredCount > 0 then
		tooltip:AddLine(string.format("%d item(s) skipped — clear in options", ignoredCount), 0.6, 0.6, 0.6)
	end

	return true
end

-- Right-click a slot to drop its top item from the queue. The secure button has
-- no type2 attribute, so a right-click fires no protected action and this
-- insecure PostClick is free to handle it.
function VDC:HandleSlotRightClick(slotKey)
	local group = WiseDB.groups[self.GROUP_NAME]
	if not group then
		return
	end
	local list = self.lastLists and self.lastLists[slotKey]
	local entry = list and list[1]
	if not entry then
		return
	end

	self:SetIgnored(group, entry.itemID, true)
	print(string.format(
		"|cff00ccff[Wise]|r Skipping %s. Clear the skip list in the interface options.",
		entry.itemLink or ("item " .. tostring(entry.itemID))
	))

	-- Rebuild so the slot immediately advances to the next candidate. Refresh
	-- redraws any open tooltip itself (RefreshOpenTooltip).
	self:Refresh()
end

-- ---------------------------------------------------------------------------
-- Slot population
-- ---------------------------------------------------------------------------

-- Rebuild the interface's two slots from a fresh bag scan. Out of combat only —
-- writing action data leads to secure attribute writes downstream.
function VDC:Refresh()
	if InCombatLockdown() then
		self.pendingRefresh = true
		return
	end
	-- Never rewrite the actions while a Disenchant/prospect/mill is in flight.
	-- Destroying an item fires BAG_UPDATE_DELAYED mid-cast; rebuilding here would
	-- repoint the button at a different bag slot underneath the running cast, so
	-- the press that lands next would act on an item the player never chose.
	--
	-- The normal wake-up is UNIT_SPELLCAST_SUCCEEDED/STOP/INTERRUPTED, which fires
	-- the rebuild the moment the cast ends. This short retry is only a safety net
	-- for a cast that ends without any of those reaching us; keep it well under
	-- one GCD so a stale queue can never sit visible in the tooltip.
	if self:IsDestroyCastInProgress() then
		self.pendingRefresh = true
		C_Timer.After(0.2, function()
			if VDC.pendingRefresh then
				VDC.pendingRefresh = nil
				VDC:Refresh()
			end
		end)
		return
	end
	if not (WiseDB and WiseDB.groups) then
		return
	end
	if not self:IsAvailable() then
		return
	end

	local group = WiseDB.groups[self.GROUP_NAME]
	if not group then
		return
	end

	local disenchant, convert = self:ScanBags()

	local lists = {
		[self.SLOT_DISENCHANT] = disenchant,
		[self.SLOT_CONVERT] = convert,
	}
	local builders = {
		[self.SLOT_DISENCHANT] = self.BuildDisenchantMacro,
		[self.SLOT_CONVERT] = self.BuildConvertMacro,
	}

	-- Rebuild every slot from scratch. The interface is NOT dynamic (see
	-- EnsureGroups), so slot indices stay stable at 1/2/3 and the bar keeps its
	-- shape even when a slot has nothing to offer.
	group.actions = {}
	group.slotNames = group.slotNames or {}
	self.slotCounts = {}
	-- Keep the resolved lists so the tooltip can show the live queue without
	-- re-scanning bags on every mouseover.
	self.lastLists = lists

	for index, slotKey in ipairs(self.SLOT_ORDER) do
		local list = lists[slotKey]
		-- Builders return a descriptor: { secureType, secureValue, attributes }.
		-- Disenchant/Convert use type="spell" + target-bag/target-slot (the only
		-- sanctioned way to cast onto a bag item); the mail fallback uses a macro.
		local action = builders[slotKey](self, list, group)
		group.slotNames[index] = slotKey
		self.slotCounts[slotKey] = #list

		local top = list[1]
		if action and top then
			group.actions[index] = {
				{
					type = action.secureType == "spell" and "spell" or "macro",
					value = action.secureValue,
					secureAttributes = action.attributes,
					-- Name carries the queue depth and the gain of the top item, so
					-- the tooltip answers "what will this press do, and how many are
					-- waiting" without opening the bags.
					name = string.format(
						"%s: %s (%d queued, +%s)",
						slotKey,
						top.itemLink,
						#list,
						GetCoinTextureString(math.floor(top.gain or 0))
					),
					icon = C_Item.GetItemIconByID(top.itemID),
					category = "global",
					autoLoaded = true,
					-- Show the queue instead of the raw spell tooltip, and let the
					-- right-click handler know which slot it is acting on.
					tooltipProvider = "VDC",
					vdcSlot = slotKey,
					-- Disenchant/Prospecting/Milling are spell-TARGETING casts:
					-- C_Spell.IsSpellUsable reports false until something is on the
					-- targeting cursor, so the usability pass would grey the icon
					-- permanently. The slot's real "can I press this" answer is the
					-- per-slot condition below, so skip the spell-usability check.
					alwaysUsable = true,
					-- Disenchant/Prospecting/Milling live on PROFESSION skill lines,
					-- not the Player spell bank Wise:IsActionKnown scans, and
					-- IsPlayerSpell reports false for them. Unknown actions are
					-- desaturated AND dropped outright from a dynamic group, so the
					-- slot must opt out of that check.
					alwaysKnown = true,
					-- These conditions gate VISIBILITY only. Without this flag they
					-- would also be baked into the secure action, turning the cast
					-- into "/cast [actionbar:99] Disenchant" (always-false) and
					-- discarding target-bag/target-slot — a button that shows but
					-- does nothing.
					visibilityOnlyConditions = true,
					-- Per-slot gate: this button shows only while THIS slot has
					-- something queued. The group is dynamic, so the renderer
					-- evaluates this and drops the slot when it does not match.
					conditions = string.format("[available:%s]", slotKey),
				},
			}
		else
			-- Nothing qualifies for this slot. Keep an entry so the slot still
			-- exists (and stays configurable), but gate it on the same per-slot
			-- condition — which is false right now, so the dynamic renderer drops
			-- the button entirely instead of showing a dead icon.
			group.actions[index] = {
				{
					type = "macro",
					value = "",
					name = slotKey .. ": nothing matches the current filters",
					icon = SLOT_EMPTY_ICON[slotKey],
					category = "global",
					autoLoaded = true,
					tooltipProvider = "VDC",
					vdcSlot = slotKey,
					alwaysUsable = true,
					alwaysKnown = true,
					visibilityOnlyConditions = true,
					conditions = string.format("[available:%s]", slotKey),
				},
			}
		end
	end

	if Wise.frames[self.GROUP_NAME] then
		Wise:UpdateGroupDisplay(self.GROUP_NAME)
		-- Buttons may have been rebuilt by the display update, so re-attach the
		-- right-click handler (guarded per button, so this is idempotent).
		self:HookSlotRightClick()
	end

	-- Redraw a tooltip that is already on screen. Rebuilding the lists does not
	-- touch an open GameTooltip, so without this the player keeps reading the
	-- pre-cast queue — including the item that was just destroyed — until they
	-- move the mouse off the button and back on.
	self:RefreshOpenTooltip()
end

-- Re-run the OnEnter of whichever of our buttons the mouse is currently over, so
-- an open queue tooltip reflects the new lists immediately.
function VDC:RefreshOpenTooltip()
	if not (GameTooltip and GameTooltip:IsShown()) then
		return
	end
	local owner = GameTooltip.GetOwner and GameTooltip:GetOwner()
	if not (owner and owner.GetScript) then
		return
	end
	-- Only redraw for our own slots; never touch another addon's tooltip.
	local meta = Wise.buttonMeta and Wise.buttonMeta[owner]
	local data = (meta and meta.actionData) or owner.actionData
	if not (data and data.tooltipProvider == "VDC") then
		return
	end
	local onEnter = owner:GetScript("OnEnter")
	if onEnter then
		onEnter(owner)
	end
end

-- ---------------------------------------------------------------------------
-- Interface creation and events
-- ---------------------------------------------------------------------------

-- Migration: earlier builds shipped (a) three separate interfaces, then (b) one
-- combined "Disenchant/Vendor/Convert". Fold any saved settings forward and
-- remove the stale groups so upgrading users don't keep dead bars around.
local LEGACY_GROUPS = { "Vendor", "Disenchant", "Convert", "Disenchant/Vendor/Convert" }

function VDC:MigrateLegacyGroups(group)
	if group.vdcMigratedNoVendor_v2 then
		return
	end
	for _, legacyName in ipairs(LEGACY_GROUPS) do
		local legacy = WiseDB.groups[legacyName]
		-- Only touch groups this module created, never a same-named user bar.
		if legacy and legacy.propertyType == "VendorDisenchantConvert" and legacy ~= group then
			if legacy.vdcFilters then
				group.vdcFilters = group.vdcFilters or {}
				-- Carry forward only the slots that still exist. The Vendor slot is
				-- gone (too many variables to resolve behind one click), so its saved
				-- filters are intentionally dropped rather than migrated.
				for _, slotKey in ipairs(VDC.SLOT_ORDER) do
					if legacy.vdcFilters[slotKey] and not group.vdcFilters[slotKey] then
						group.vdcFilters[slotKey] = legacy.vdcFilters[slotKey]
					end
				end
			end
			if legacy.vdcMailTarget and legacy.vdcMailTarget ~= "" then
				group.vdcMailTarget = group.vdcMailTarget or legacy.vdcMailTarget
			end
			if legacy.vdcAutoConfirmBind ~= nil and group.vdcAutoConfirmBind == nil then
				group.vdcAutoConfirmBind = legacy.vdcAutoConfirmBind
			end
			-- Preserve where the user had placed the old bar.
			if legacy.anchor and not group.vdcInheritedAnchor then
				group.anchor = legacy.anchor
				group.vdcInheritedAnchor = true
			end
			WiseDB.groups[legacyName] = nil
			if Wise.frames[legacyName] then
				Wise.frames[legacyName]:Hide()
				Wise.frames[legacyName] = nil
			end
		end
	end
	-- Drop any Vendor filters saved directly on this group by an earlier version.
	if group.vdcFilters then
		group.vdcFilters.Vendor = nil
	end
	group.vdcMigratedCombined_v1 = true
	group.vdcMigratedNoVendor_v2 = true
end

function VDC:EnsureGroups()
	local name = self.GROUP_NAME
	if not WiseDB.groups[name] then
		Wise:CreateGroup(name, "circle")
		WiseDB.groups[name].enabled = false
	end
	local group = WiseDB.groups[name]
	group.isWiser = true
	group.propertyType = "VendorDisenchantConvert"

	-- Dynamic: each slot shows only when IT has something to do. Only dynamic
	-- groups evaluate per-slot conditions, which is what lets [available:<slot>]
	-- hide an idle Disenchant button while Convert is showing. The bar does
	-- reflow as a result — that is the intended trade: a button that cannot do
	-- anything is worse than a stable position.
	group.dynamic = true

	self:MigrateLegacyGroups(group)

	for _, slotKey in ipairs(self.SLOT_ORDER) do
		self:GetFilters(group, slotKey)
	end

	-- Protect equipment-set gear by default. Set here (not in the options panel)
	-- so it holds for players who never open the panel — destroying saved gear is
	-- irreversible, so the safe default must not depend on the UI being visited.
	if group.vdcProtectEquipmentSets == nil then
		group.vdcProtectEquipmentSets = true
	end

	-- Default visibility: show out of combat only while something is actionable.
	-- Seeded once so the interface is useful immediately; the user is free to edit
	-- or clear it afterwards (vdcSeededVisibility_v1 stops us re-applying it).
	if not group.vdcSeededVisibility_v1 then
		group.visibilitySettings = group.visibilitySettings or {}
		if not group.visibilitySettings.customShow or group.visibilitySettings.customShow == "" then
			group.visibilitySettings.customShow = "[nocombat,available]"
		end
		group.vdcSeededVisibility_v1 = true
	end
end

function VDC:Initialize()
	if not (WiseDB and WiseDB.groups) then
		return
	end
	self:BuildDestroySpellNameCache()
	self:EnsureGroups()

	-- Availability, answered at two scopes:
	--   [available]            — the interface as a whole (any slot has a match),
	--                            which drives whether the bar shows at all.
	--   [available:Disenchant] — that ONE slot, which drives whether that button
	--                            shows. Each slot carries this as its per-slot
	--                            condition, so Convert appearing never drags an
	--                            empty Disenchant button onto the bar with it.
	Wise:RegisterAvailabilityProvider(self.GROUP_NAME, function(_, key)
		if not VDC.slotCounts then
			return false
		end
		if key then
			return (VDC.slotCounts[key] or 0) > 0
		end
		for _, slotKey in ipairs(VDC.SLOT_ORDER) do
			if (VDC.slotCounts[slotKey] or 0) > 0 then
				return true
			end
		end
		return false
	end)

	-- Queue tooltip, opted into per-action via actionData.tooltipProvider.
	if Wise.RegisterTooltipProvider then
		Wise:RegisterTooltipProvider("VDC", function(tooltip, button, actionData)
			return VDC:BuildSlotTooltip(tooltip, button, actionData)
		end)
	end

	self:HookSlotRightClick()
	Wise:InitializeVDCProperties()
	self:Refresh()
end

-- Attach the right-click handler to this interface's buttons. Re-run after each
-- display rebuild because buttons are recreated. PostClick is insecure and fires
-- after the secure action (which does nothing on button 2, since no type2 is set).
function VDC:HookSlotRightClick()
	local frame = Wise.frames and Wise.frames[self.GROUP_NAME]
	if not (frame and frame.buttons) then
		return
	end
	for _, btn in ipairs(frame.buttons) do
		if not btn._vdcRightClickHooked then
			btn:HookScript("PostClick", function(self_btn, mouseButton, down)
				-- Buttons register AnyUp+AnyDown; act on the up edge only.
				if down or mouseButton ~= "RightButton" then
					return
				end
				local meta = Wise.buttonMeta and Wise.buttonMeta[self_btn]
				local data = (meta and meta.actionData) or self_btn.actionData
				local slotKey = data and data.vdcSlot
				if slotKey then
					VDC:HandleSlotRightClick(slotKey)
				end
			end)
			btn._vdcRightClickHooked = true
		end
	end
end

-- ---------------------------------------------------------------------------
-- Options panel
-- ---------------------------------------------------------------------------

-- Build a labelled numeric entry bound to one filter key. Committing the value
-- triggers a refresh so the bar reflects the new filter immediately.
local function addNumericFilter(panel, group, filters, key, label, y, suffix)
	local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("TOPLEFT", 10, y)
	text:SetText(label)
	tinsert(panel.controls, text)

	local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	box:SetSize(70, 20)
	box:SetPoint("TOPLEFT", 150, y + 4)
	box:SetAutoFocus(false)
	box:SetNumeric(false)
	box:SetText(tostring(filters[key] or 0))

	local function commit(self)
		local value = tonumber(self:GetText()) or 0
		if value < 0 then
			value = 0
		end
		filters[key] = value
		self:SetText(tostring(value))
		self:ClearFocus()
		Wise.VDC:Refresh()
	end

	box:SetScript("OnEnterPressed", commit)
	box:SetScript("OnEditFocusLost", commit)
	box:SetScript("OnEscapePressed", function(self)
		self:SetText(tostring(filters[key] or 0))
		self:ClearFocus()
	end)
	tinsert(panel.controls, box)

	if suffix then
		local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		hint:SetPoint("LEFT", box, "RIGHT", 4, 0)
		hint:SetText(suffix)
		tinsert(panel.controls, hint)
	end

	return y - 26
end

function Wise:InitializeVDCProperties()
	Wise.PropertyHooks = Wise.PropertyHooks or {}
	Wise.PropertyHooks["VendorDisenchantConvert"] = {
		suppress = {
			Actions = true, -- Slots are generated from bag contents, not hand-edited.
			Rename = true,
		},
		inject = {
			Bottom = function(panel, group, y)
				local VDCref = Wise.VDC

				local provider = VDCref:GetPriceProvider()
				local status = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
				status:SetPoint("TOPLEFT", 10, y)
				status:SetWidth(220)
				status:SetJustifyH("LEFT")
				if provider then
					status:SetText("Price data: |cff00ff00" .. provider .. "|r")
				else
					status:SetText("|cffff6600Requires TradeSkillMaster, ProfitProphet, or Auctionator.|r")
				end
				tinsert(panel.controls, status)
				y = y - 30

				-- One collapsible-style block of filters per slot, in bar order, so
				-- both are configured from the single interface's panel.
				for index, slotKey in ipairs(VDCref.SLOT_ORDER) do
					local filters = VDCref:GetFilters(group, slotKey)
					local queued = VDCref.slotCounts and VDCref.slotCounts[slotKey]

					local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
					header:SetPoint("TOPLEFT", 10, y)
					header:SetText(string.format("Slot %d — %s", index, slotKey))
					tinsert(panel.controls, header)

					if queued then
						local countFS = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
						countFS:SetPoint("LEFT", header, "RIGHT", 6, 0)
						countFS:SetText(string.format("(%d queued)", queued))
						tinsert(panel.controls, countFS)
					end
					y = y - 22

					y = addNumericFilter(panel, group, filters, "minValue", "Minimum gain (gold)", y, "g")
					y = addNumericFilter(panel, group, filters, "minMargin", "Minimum margin", y, "%")
					y = addNumericFilter(panel, group, filters, "minQuality", "Min quality (0-5)", y)
					y = addNumericFilter(panel, group, filters, "maxQuality", "Max quality (0=any)", y)
					y = addNumericFilter(panel, group, filters, "minILvl", "Min item level", y)
					y = addNumericFilter(panel, group, filters, "maxILvl", "Max item level (0=any)", y)
					y = addNumericFilter(panel, group, filters, "maxItems", "Max items queued", y)

					-- Disenchant-only: where to mail items when not an enchanter.
					if slotKey == VDCref.SLOT_DISENCHANT then
						local mailLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
						mailLabel:SetPoint("TOPLEFT", 10, y)
						mailLabel:SetText("Mail to (non-enchanters)")
						tinsert(panel.controls, mailLabel)
						y = y - 22

						local mailBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
						mailBox:SetSize(180, 20)
						mailBox:SetPoint("TOPLEFT", 14, y)
						mailBox:SetAutoFocus(false)
						mailBox:SetText(group.vdcMailTarget or "")
						local function commitMail(self)
							group.vdcMailTarget = self:GetText()
							self:ClearFocus()
							Wise.VDC:Refresh()
						end
						mailBox:SetScript("OnEnterPressed", commitMail)
						mailBox:SetScript("OnEditFocusLost", commitMail)
						tinsert(panel.controls, mailBox)
						y = y - 30
					end

					y = y - 10
				end

				-- Equipment-set protection. Default ON: gear the player deliberately
				-- saved into a set is almost never meant to be destroyed, and
				-- disenchanting is irreversible.
				if group.vdcProtectEquipmentSets == nil then
					group.vdcProtectEquipmentSets = true
				end
				local setCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
				setCheck:SetSize(24, 24)
				setCheck:SetPoint("TOPLEFT", 10, y)
				setCheck:SetChecked(group.vdcProtectEquipmentSets)
				setCheck:SetScript("OnClick", function(self)
					group.vdcProtectEquipmentSets = self:GetChecked()
					Wise.VDC:Refresh()
				end)
				tinsert(panel.controls, setCheck)

				local setLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				setLabel:SetPoint("LEFT", setCheck, "RIGHT", 4, 0)
				setLabel:SetText("Never destroy equipment-set gear")
				tinsert(panel.controls, setLabel)
				y = y - 30

				-- Skip list (populated by right-clicking a slot).
				local ignoredCount = 0
				for _ in pairs(Wise.VDC:GetIgnored(group)) do
					ignoredCount = ignoredCount + 1
				end

				local skipLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
				skipLabel:SetPoint("TOPLEFT", 10, y)
				skipLabel:SetWidth(210)
				skipLabel:SetJustifyH("LEFT")
				skipLabel:SetText(
					ignoredCount == 0 and "No skipped items. Right-click a slot to skip its top item."
						or string.format("%d item(s) skipped by right-click.", ignoredCount)
				)
				tinsert(panel.controls, skipLabel)
				y = y - 30

				if ignoredCount > 0 then
					local clearBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
					clearBtn:SetSize(140, 22)
					clearBtn:SetPoint("TOPLEFT", 10, y)
					clearBtn:SetText("Clear skip list")
					clearBtn:SetScript("OnClick", function()
						wipe(Wise.VDC:GetIgnored(group))
						Wise.VDC:Refresh()
						Wise:UpdateOptionsUI()
					end)
					tinsert(panel.controls, clearBtn)
					y = y - 30
				end

				-- Bind-confirmation auto-dismiss (applies to Disenchant + Convert).
				local bindCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
				bindCheck:SetSize(24, 24)
				bindCheck:SetPoint("TOPLEFT", 10, y)
				bindCheck:SetChecked(group.vdcAutoConfirmBind or false)
				bindCheck:SetScript("OnClick", function(self)
					group.vdcAutoConfirmBind = self:GetChecked()
					Wise.VDC:Refresh()
				end)
				tinsert(panel.controls, bindCheck)

				local bindLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				bindLabel:SetPoint("LEFT", bindCheck, "RIGHT", 4, 0)
				bindLabel:SetText("Auto-confirm destroy prompt")
				tinsert(panel.controls, bindLabel)
				y = y - 26

				local bindNote = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
				bindNote:SetWidth(210)
				bindNote:SetPoint("TOPLEFT", 14, y)
				bindNote:SetJustifyH("LEFT")
				bindNote:SetText(
					"Binds a key that clears Blizzard's destroy confirmation on soulbound gear. Only ever clicks that exact dialog, and only on a press you make."
				)
				tinsert(panel.controls, bindNote)
				y = y - 46

				local refreshBtn = CreateFrame("Button", nil, panel, "GameMenuButtonTemplate")
				refreshBtn:SetSize(140, 22)
				refreshBtn:SetPoint("TOPLEFT", 10, y)
				refreshBtn:SetText("Rescan Bags")
				refreshBtn:SetScript("OnClick", function()
					Wise.VDC:Refresh()
				end)
				tinsert(panel.controls, refreshBtn)
				y = y - 32

				return y
			end,
		},
	}
end

-- Bag changes, mail state, and combat exit all re-arm the slots.
-- Debounced so a mass loot or a vendor-sell sweep costs one rebuild, not N
-- (AGENTS.md Rule 12: coalesce event bursts, never poll).
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
-- Item data arrives asynchronously. At login most bag items are UNCACHED, and an
-- uncached item is skipped by the scan (C_Item.GetItemInfo returns nil), so the
-- first pass can legitimately find nothing. Without this the queue then sat empty
-- until some unrelated event happened to re-trigger a scan — which is why the
-- interface only appeared after visiting a mailbox or moving an item.
-- GET_ITEM_INFO_RECEIVED fires as each item resolves; it is debounced and
-- self-limiting (see the handler) so a login burst costs one rescan, not hundreds.
eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
-- Mail only: the disenchant fallback attaches items with the mailbox open. No
-- MERCHANT_* registration — with the Vendor slot gone, nothing here reacts to a
-- merchant window, and refreshing on it was pure wasted work.
eventFrame:RegisterEvent("MAIL_SHOW")
eventFrame:RegisterEvent("MAIL_CLOSED")
-- Saving/deleting an equipment set changes what the protection filter excludes.
eventFrame:RegisterEvent("EQUIPMENT_SETS_CHANGED")
-- Cast completion. The destroyed item leaves the bags the instant the cast ends,
-- but BAG_UPDATE_DELAYED lands later and the generic 1s debounce delays it
-- further — which left the tooltip showing an item that no longer exists. These
-- fire the rebuild immediately instead. UNIT_SPELLCAST_SUCCEEDED is the "it
-- worked" signal; the STOP/INTERRUPTED pair clears the in-flight guard so a
-- cancelled cast doesn't leave the queue frozen until the next bag event.
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

local refreshTimer
eventFrame:SetScript("OnEvent", function(_, event, unit, castGUID, spellID)
	if event == "PLAYER_LOGIN" then
		-- Deliberate 3s delay before the first bag scan. This is a TRADE, not an
		-- oversight — do not "optimise" it away:
		--   * TSM/ProfitProphet are still loading their price databases at login.
		--     Scanning earlier reads missing prices, which silently produces an
		--     empty or wrong queue rather than a late one.
		--   * Item info is often uncached this early; uncached items are skipped
		--     for the pass, so an early scan would drop items until the next bag
		--     event anyway.
		--   * A full bag scan competes with everything else loading at login.
		--     Deferring keeps reload lag off the critical path.
		-- The visible cost is that the interface appears a few seconds after
		-- reload; with [available] seeded it simply stays hidden until then.
		C_Timer.After(3, function()
			VDC:Initialize()
			-- Bounded retries after the first scan. Item info resolves
			-- asynchronously, so the 3s pass can still see uncached items and come
			-- back empty. GET_ITEM_INFO_RECEIVED normally covers this, but it only
			-- fires for items the client actually requests — these retries make the
			-- interface appear on its own rather than waiting for the player to
			-- open a mailbox or move an item. They stop as soon as anything is
			-- queued, so a genuinely empty bag costs three cheap scans and no more.
			for _, delay in ipairs({ 3, 6, 10 }) do
				C_Timer.After(delay, function()
					if InCombatLockdown() or not VDC.slotCounts then
						return
					end
					for _, slotKey in ipairs(VDC.SLOT_ORDER) do
						if (VDC.slotCounts[slotKey] or 0) > 0 then
							return -- already populated; nothing to chase
						end
					end
					VDC:Refresh()
				end)
			end
		end)
		return
	end

	if event == "PLAYER_REGEN_ENABLED" then
		if not VDC.pendingRefresh then
			return
		end
		VDC.pendingRefresh = nil
	end

	-- Item data resolving. This fires once per item and can burst in the hundreds
	-- at login, so it is rate-limited two ways: it only matters while we still
	-- have nothing queued (once the lists are populated, BAG_UPDATE_DELAYED and
	-- the cast events own refreshing), and it rides the same 1s debounce below.
	if event == "GET_ITEM_INFO_RECEIVED" then
		if not VDC.slotCounts then
			-- Not initialised yet; the login timer will do the first scan.
			return
		end
		local anyQueued = false
		for _, slotKey in ipairs(VDC.SLOT_ORDER) do
			if (VDC.slotCounts[slotKey] or 0) > 0 then
				anyQueued = true
				break
			end
		end
		if anyQueued then
			return
		end
	end

	if InCombatLockdown() then
		VDC.pendingRefresh = true
		return
	end

	-- Cast finished: rebuild NOW rather than waiting out the bag-event debounce.
	-- Only for the spells this module drives, so an unrelated cast doesn't
	-- trigger a bag scan.
	if
		event == "UNIT_SPELLCAST_SUCCEEDED"
		or event == "UNIT_SPELLCAST_STOP"
		or event == "UNIT_SPELLCAST_INTERRUPTED"
	then
		if not VDC:IsDestroySpellID(spellID) then
			return
		end
		-- Cancel any queued debounce so we don't rebuild twice for one destroy.
		if refreshTimer then
			refreshTimer:Cancel()
			refreshTimer = nil
		end
		VDC.pendingRefresh = nil
		-- One frame of slack: the item is removed as the cast completes, and
		-- reading the container on the same frame can still see the old contents.
		C_Timer.After(0, function()
			if not InCombatLockdown() then
				VDC:Refresh()
			end
		end)
		return
	end

	if refreshTimer then
		return
	end
	refreshTimer = C_Timer.NewTimer(1, function()
		refreshTimer = nil
		VDC:Refresh()
	end)
end)
