-- wiser/vdc/Scan.lua
--
-- One pass over the bags that feeds BOTH slots.
-- See wiser/vdc/Core.lua for the wiser's design notes.
--
-- Deliberately a single pass: bag iteration plus per-item price lookups is the
-- expensive part of a refresh, and scanning twice (once per slot) doubled it for
-- no benefit. ScanBags buckets each qualifying item into disenchant[] or
-- convert[] and returns both, each sorted by gain descending, so the slot that
-- acts on "the best item" only has to read index 1.
--
-- passesFilters lives here rather than with the filter accessors in Pricing.lua
-- because it is the thing the scan applies per candidate; `gain` is the copper
-- advantage over `alternative`, which is what makes the percentage-margin test
-- meaningful.
--
-- Loaded after Pricing.lua, before Actions.lua.

local addonName, Wise = ...

local VDC = Wise.VDC

local DE_EQUIPLOCS = VDC.DE_EQUIPLOCS
local SALVAGE = VDC.SALVAGE

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

					-- DISENCHANT: worth more disenchanted than the alternative.
					--
					-- Which alternative depends on intent, so it is configurable:
					--   ignoreMarket=false (default) — compare against the better of
					--     vendor and AUCTION price. Right for loot you might resell.
					--   ignoreMarket=true — compare against vendor price only. Right
					--     for items BOUGHT to disenchant: their market price is the
					--     price you already paid, and it usually sits just under the
					--     mat value (that spread is the whole flip), so including it
					--     rejects exactly the items you bought for this purpose.
					local deCandidate = quality and DE_EQUIPLOCS[equipLoc]
							and self:GetDisenchantValue(itemLink, quality, ilvl, itemID)
						or nil
					if deCandidate then
						local deValue = deCandidate
						local baseline
						if deFilters.ignoreMarket then
							baseline = vendorValue or 0
						else
							baseline = math.max(vendorValue or 0, marketValue or 0)
						end
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

