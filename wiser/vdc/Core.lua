-- wiser/vdc/Core.lua
--
-- Shared table, constants, and the design notes for the whole Disenchant/Convert
-- wiser. The implementation is split across this directory, cutting on the
-- section boundaries this file's author had already marked:
--
--   Core     this file — VDC table, constants, the notes below
--   Pricing  price providers, the ignore list, filter resolution
--   Scan     one bag pass that feeds both slots
--   Actions  destroy-confirm safety net, macro construction, cast tracking
--   Slots    tooltip and slot population
--   Options  the properties panel
--   Events   load-time registration: events, hooks, availability provider
--
-- Load order is Core first (everything reads its constants), then the rest in
-- the order above; Events last, because it wires up functions the earlier files
-- define and has load-time side effects.
--
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


-- Constants published on VDC for the sibling files under wiser/vdc/. They stay
-- `local` above for the cheap read inside this file; the table entries are how
-- Pricing/Scan/Actions/Slots reach them, since Lua locals do not cross files.
VDC.PROSPECT_BATCH = PROSPECT_BATCH
VDC.MILL_BATCH_DEFAULT = MILL_BATCH_DEFAULT
VDC.MILL_BATCH_BY_EXPANSION = MILL_BATCH_BY_EXPANSION
VDC.SALVAGE = SALVAGE
VDC.DISENCHANT_SPELL_ID = DISENCHANT_SPELL_ID
VDC.SLOT_EMPTY_ICON = SLOT_EMPTY_ICON
VDC.DE_EQUIPLOCS = DE_EQUIPLOCS
VDC.DEFAULT_FILTERS = DEFAULT_FILTERS
