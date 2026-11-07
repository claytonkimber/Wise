local addonName, Wise = ...

-- The "Menu Bar" wiser interface: one button per micro-menu panel.
--
-- The other wiser interfaces are rebuilt from scratch by
-- Wise:UpdateWiserInterfaces, which runs on every SPELLS_CHANGED, spec change
-- and loading screen. Nothing on this bar depends on the character, so it is
-- seeded instead: each default is added once, and after that the bar is left
-- alone. The rebuild used to wipe .actions every time, so a slot the user added
-- (or a keybind or extra state on a default slot) was gone within seconds.
--
-- group.keepsUserSlots marks an interface that works this way:
--   * once seeded, every slot is the user's, defaults included: any of them can
--     be deleted, replaced or reordered (Wise:IsAutoImportedSlot)
--   * group.seededDefaults records each default once it is added, so one the
--     user deleted or replaced stays gone, while a panel shipped in a later
--     release still reaches existing bars
--   * "Reset to Default" calls Wise:ResetKeptSlots, and the refresh that
--     follows seeds every default again

-- uipanel values, in bar order.
local DEFAULT_PANELS = {
	"menu",
	"shop",
	"adventureguide",
	"collections",
	"groupfinder",
	"guild",
	"housing",
	"questlog",
	"achievements",
	"talents",
	"professions",
	"character",
}

local function NewPanelAction(panel)
	return {
		type = "uipanel",
		value = panel,
		category = "global",
		visibilityEnable = {},
		visibilityDisable = {},
	}
end

-- Add each default panel the bar has not had yet. Runs on every wiser refresh,
-- so it returns straight away once every default is recorded.
function Wise:SeedMenuBar(group)
	Wise:MigrateGroupToActions(group)
	-- The old rebuild's list, now copied into .actions. Left in place it goes
	-- stale, and [available] would still count a bar the user emptied.
	group.buttons = nil
	group.keepsUserSlots = true
	local seeded = group.seededDefaults or {}
	group.seededDefaults = seeded

	local pending = {}
	for _, panel in ipairs(DEFAULT_PANELS) do
		if not seeded[panel] then
			pending[#pending + 1] = panel
		end
	end
	if #pending == 0 then
		return
	end

	-- A bar saved before seeding existed already holds the defaults, so record
	-- those rather than adding them a second time.
	local onBar, lastSlot = {}, 0
	for slotIdx, states in pairs(group.actions) do
		if type(slotIdx) == "number" then
			if slotIdx > lastSlot then
				lastSlot = slotIdx
			end
			for _, action in ipairs(states) do
				if action.type == "uipanel" and action.value then
					onBar[action.value] = true
				end
			end
		end
	end

	for _, panel in ipairs(pending) do
		if not onBar[panel] then
			lastSlot = lastSlot + 1
			group.actions[lastSlot] = { NewPanelAction(panel) }
		end
		seeded[panel] = true
	end
end

-- "Reset to Default" for an interface that keeps user slots. A refresh never
-- clears them, so drop them here; the next refresh seeds the defaults again.
function Wise:ResetKeptSlots(group)
	group.actions = nil
	group.buttons = nil
	group.migratedToActions = nil
	group.slotNames = nil
	group.seededDefaults = nil
end
