-- wiser/vdc/Pricing.lua
--
-- What an item is worth, and whether the player wants to hear about it.
-- See wiser/vdc/Core.lua for the wiser's design notes.
--
-- Three concerns, in dependency order:
--   * Price providers -- TSM / ProfitProphet / Auctionator, resolved LAZILY
--     (GetPriceProvider) because pricing addons can be LoadOnDemand and may not
--     exist when this file loads. Never cache the provider at load time.
--   * Ignore list -- per-item opt-out keyed by itemID, plus equipment-set
--     protection so a slot never offers to destroy gear the player has saved to
--     a set.
--   * Filters -- the per-slot thresholds, resolved against DEFAULT_FILTERS.
--
-- Every value here is COPPER, and `gain` throughout the wiser means "copper
-- advantage of taking this action over the alternative" -- not a ratio, and not
-- the action's own value. The percentage-margin test in Scan.lua depends on
-- that convention.
--
-- Loaded after Core.lua, before Scan.lua.

local addonName, Wise = ...

local VDC = Wise.VDC

local PROSPECT_BATCH = VDC.PROSPECT_BATCH
local MILL_BATCH_DEFAULT = VDC.MILL_BATCH_DEFAULT
local MILL_BATCH_BY_EXPANSION = VDC.MILL_BATCH_BY_EXPANSION
local DEFAULT_FILTERS = VDC.DEFAULT_FILTERS

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

-- TSM custom-price expressions for "what are this item's mats worth".
--
-- `destroy` is NOT a price source — it is only the /tsm destroy slash command,
-- so GetCustomPriceValue("destroy", ...) failed for EVERY item and the whole TSM
-- path silently produced nothing. The real syntax is the `convert()` FUNCTION,
-- which takes a price source and returns the value of what the item converts
-- into (disenchant / mill / prospect). Ordered best-data-first; the first
-- expression that yields a positive number wins.
local DE_PRICE_EXPRESSIONS = {
	"convert(dbmarket)",
	"convert(dbregionmarketavg)",
	"convert(dbminbuyout)",
}

-- Expected disenchant material value of one item, in copper. nil when unknown.
function VDC:GetDisenchantValue(itemLink, quality, ilvl, itemID)
	if TSM_API and TSM_API.GetCustomPriceValue then
		for i = 1, #DE_PRICE_EXPRESSIONS do
			local value = tsmValue(DE_PRICE_EXPRESSIONS[i], itemLink)
			if value and value > 0 then
				return value
			end
		end
	end
	if PP and PP.Destroying and PP.Destroying.deValueOf then
		-- PP returns 0 (not nil) when it has no scanned price for the resulting
		-- mats, so a 0 here means "no data", not "worthless".
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
		-- `convert` is a FUNCTION taking a price source, not a bare source; a
		-- bare "convert" never resolves. Same fix as GetDisenchantValue.
		for i = 1, #DE_PRICE_EXPRESSIONS do
			value = tsmValue(DE_PRICE_EXPRESSIONS[i], itemLink)
			if value and value > 0 then
				break
			end
		end
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
