-- core/blizzui/Registry.lua
--
-- What Wise can hide, and when the "puzzle" exception applies -- extracted from
-- Wise.lua.
--
-- Wise.BlizzardFrames is the catalogue: each entry pairs a settings key with the
-- Blizzard frames it controls and the label shown in Settings. modules/Settings.lua
-- builds its checkbox list straight off this table, so adding an entry here is
-- what makes a new toggle appear -- no UI change needed.
--
-- The puzzle exception exists because some world content (puzzle objects, vehicle
-- segments) replaces the action bar with its own controls. If the player has hidden
-- Blizzard's bars, those controls vanish too and the content becomes unplayable, so
-- IsPuzzleActive() temporarily un-hides them.
--
-- SECRET-VALUE TRAP, do not "simplify" this: HasPuzzleAura must never read
-- aura.spellId off GetAuraDataByIndex and use it as a table key. In combat that
-- field is a secret number and indexing with it throws ("cannot be indexed with
-- secret keys"). Query by our OWN constant spellID via GetPlayerAuraBySpellID
-- instead, which never touches a secret value.
--
-- Loaded immediately after Wise.lua, before the rest of core/blizzui/.

local addonName, Wise = ...

local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local CreateFrame = CreateFrame
local C_UnitAuras = C_UnitAuras
local C_Timer = C_Timer
local UnitInVehicle = UnitInVehicle
local UnitHasVehicleUI = UnitHasVehicleUI


-- HUD Edit Mode Integration

Wise.BlizzardFrames = {
	-- Action Bar 1: MainMenuBarArtFrame (art background), ActionButton1..12 (buttons)
	-- We avoid hiding MainMenuBar itself because it contains XP/Rep bars (StatusTrackingBarManager) and MicroMenu in some modes.
	-- Additional decorative art (end caps, background) is handled separately in UpdateBlizzardUI.
	{ key = "hideActionBar1", label = "Action Bar 1", frames = { "MainMenuBarArtFrame" } },
	{ key = "hideStanceBar", label = "Stance Bar", frames = { "StanceBar" } },
	{ key = "hidePetBar", label = "Pet Bar", frames = { "PetActionBar" } },
	{ key = "hideOverrideBar", label = "Override Bar", frames = { "OverrideActionBar" } },
	{ key = "hideMicroMenu", label = "Micro Menu", frames = { "MicroMenuContainer", "MicroMenu" } },
	{ key = "hideBagsBar", label = "Bags Bar", frames = { "BagsBar", "BagBarExpandable" } },
	{ key = "hideExtraActionBar", label = "Extra Action Button", frames = { "ExtraActionBarFrame" } },
	{ key = "hideZoneAbility", label = "Zone Ability Button", frames = { "ZoneAbilityFrame" } },
	{ key = "hidePuzzleUI", label = "Puzzle Event UI", frames = {} },
}

-- Hook into Edit Mode to re-apply visibility when exiting Edit Mode
if EditModeManagerFrame then
	EditModeManagerFrame:HookScript("OnHide", function()
		if Wise.UpdateBlizzardUI then
			-- Delay slightly to let Blizzard UI finish its layout updates
			C_Timer.After(0.1, function()
				Wise:UpdateBlizzardUI()
			end)
		end
	end)
end

Wise.managedFrames = Wise.managedFrames or {}

-- Programmatic check for an active puzzle event
-- Puzzles generally give the player an Override Action Bar but do NOT put them
-- in a traditional vehicle or possess state.
-- Auras that put the player into a quest puzzle/minigame that renders its own UI
-- (UIWidget / fullscreen overlay) WITHOUT triggering an override action bar — so
-- HasOverrideActionBar() alone misses them. Matched by spellId (locale-independent).
-- Add more puzzle aura spellIds here as they're found.
--
-- NOTE: we must NOT read aura.spellId off GetAuraDataByIndex and index a table with
-- it — in combat that field is a "secret number" and using it as a table key throws
-- ("cannot be indexed with secret keys"). Instead we query by our OWN constant
-- spellID via GetPlayerAuraBySpellID, which never touches a secret value.
local PUZZLE_AURA_SPELLIDS = {
	1293367, -- "Unravel the Magical Ward" — Unraveling quest (Midnight)
}

local function HasPuzzleAura()
	if not C_UnitAuras or not C_UnitAuras.GetPlayerAuraBySpellID then
		return false
	end
	for _, spellID in ipairs(PUZZLE_AURA_SPELLIDS) do
		if C_UnitAuras.GetPlayerAuraBySpellID(spellID) then
			return true
		end
	end
	return false
end

local function IsPuzzleActive()
	local inVehicle = UnitInVehicle("player") or UnitHasVehicleUI("player")
	if inVehicle then
		return false
	end
	-- A puzzle is identified ONLY by a known puzzle aura (locale-independent).
	-- We previously treated *any* override action bar as a puzzle, but that is wrong:
	-- ordinary override-bar events (e.g. the Stormwind "Torch Tossing" world quest)
	-- raise [overridebar] without being a fullscreen/UIWidget puzzle, and the blanket
	-- rule hid every Wise interface — including override-bar replacement bars the user
	-- WANTS visible during override. Match by aura instead; add new puzzle spellIds to
	-- PUZZLE_AURA_SPELLIDS as they're found. See memory: override_bar_torch_event_127.
	return HasPuzzleAura()
end

local lastPuzzleState = false

-- Event frame for puzzle UI hiding
local puzzleEventFrame = CreateFrame("Frame")
puzzleEventFrame:RegisterEvent("UPDATE_UI_WIDGET")
puzzleEventFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
puzzleEventFrame:RegisterEvent("ACTIONBAR_UPDATE_STATE")
puzzleEventFrame:RegisterEvent("UNIT_ENTERED_VEHICLE")
puzzleEventFrame:RegisterEvent("UNIT_EXITED_VEHICLE")
-- Aura-driven puzzles (e.g. "Unravel the Magic Ward") have no override bar, so
-- watch player auras too. UNIT_AURA fires frequently — gate on a real state change.
puzzleEventFrame:RegisterUnitEvent("UNIT_AURA", "player")
puzzleEventFrame:SetScript("OnEvent", function(self, event, ...)
	local currentState = IsPuzzleActive()
	local stateChanged = (currentState ~= lastPuzzleState)
	lastPuzzleState = currentState

	if
		stateChanged
		or event == "UNIT_ENTERED_VEHICLE"
		or event == "UNIT_EXITED_VEHICLE"
		or event == "UPDATE_BONUS_ACTIONBAR"
	then
		if Wise.UpdateBlizzardUI then
			Wise:UpdateBlizzardUI()
		end
	end
end)

-- Exposed for the /wise puzzle debug command in Wise.lua and for the sibling
-- modules under core/blizzui/, which gate hiding on the same answer.
Wise.IsPuzzleActive = IsPuzzleActive
