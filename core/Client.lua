-- core/Client.lua
--
-- Client flavour detection (retail vs WoW Forever, codename "Camelot") and the
-- `/wise client` diagnostic that checks the Forever port's assumptions in-game.
--
-- Forever runs the modern Mainline UI and API, so almost all of Wise works
-- unchanged. Two things make it look different to addon code (full survey in
-- docs/forever-port-plan.md):
--
--   * The interface number is 16001 (build 1.60.x), so any `>= 1xxxxx` gate
--     reads it as an ancient client. Never compare the interface number to mean
--     "modern client". Probe the capability, or use Wise.IS_FOREVER for
--     behaviour that is genuinely Forever-specific.
--   * Retail's Blizzard_Deprecated* shim addons do not load there. Their TOC
--     gates (`standard` / `mainline`) exclude the `camelot` game type, so bare
--     globals like GetSpecialization and GetItemCount are nil. Call the C_*
--     functions those shims aliased instead; they exist on both clients.
--
-- Loaded first in Wise.toc's Core section so every later file can read
-- Wise.IS_FOREVER at load time.

local addonName, Wise = ...

local _G = _G
local type = type
local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local print = print
local pcall = pcall
local tconcat = table.concat
local GetBuildInfo = GetBuildInfo

local VERSION, BUILD, _, INTERFACE = GetBuildInfo()
INTERFACE = tonumber(INTERFACE) or 0

-- C_GameRules.GetForeverExperiencePreset exists only on Forever (it drives the
-- Classic/Modern UI preset chosen at the glue screen).
local HAS_FOREVER_API = type(_G.C_GameRules) == "table"
	and type(_G.C_GameRules.GetForeverExperiencePreset) == "function"

-- Forever reports 1.60.x → 16001; Classic Era is 1.15.x → 115xx, so a 16000–19999
-- interface number is Forever's alone today. The project-ID / Forever-API test
-- stops a hypothetical future Classic client in that range from matching.
-- WOW_PROJECT_ID is reportedly WOW_PROJECT_MAINLINE on Forever (unverified —
-- `/wise client` prints it), hence the API fallback.
local IS_FOREVER = INTERFACE >= 16000
	and INTERFACE < 20000
	and (_G.WOW_PROJECT_ID == _G.WOW_PROJECT_MAINLINE or HAS_FOREVER_API)

Wise.Client = Wise.Client or {}
local Client = Wise.Client
Client.VERSION = VERSION
Client.BUILD = BUILD
Client.INTERFACE = INTERFACE
Client.IS_FOREVER = IS_FOREVER
Wise.IS_FOREVER = IS_FOREVER

-- Class IDs that exist on this client, ascending.
--
-- Never loop `for classID = 1, GetNumClasses()`: class IDs are not contiguous
-- everywhere. Measured on Forever 1.60.1 (2026-09-26): GetNumClasses() is 9 but
-- the IDs are 1-5, 7-9 and 11, so that loop skips Druid (11) entirely and
-- visits the missing Death Knight slot (6). Scan upward instead, until we have
-- found as many classes as the client reports. On retail (13 contiguous IDs)
-- this returns 1..13, exactly what the old loop did.
local MAX_CLASS_ID_SCAN = 32
function Client.GetClassIDs()
	local ids = {}
	local GetNumClasses, GetClassInfo = _G.GetNumClasses, _G.GetClassInfo
	if type(GetNumClasses) ~= "function" or type(GetClassInfo) ~= "function" then
		return ids
	end
	local want = GetNumClasses() or 0
	for classID = 1, MAX_CLASS_ID_SCAN do
		if #ids >= want then
			break
		end
		local _, classTag = GetClassInfo(classID)
		if classTag then
			ids[#ids + 1] = classID
		end
	end
	return ids
end

-- True for a talent config type that holds a player's combat loadout. Forever
-- stores them as Enum.TraitConfigType.CamelotCombat (4), not Combat (1) —
-- measured 2026-09-26 — so a `== Combat` test hides every Forever loadout.
function Client.IsCombatTraitConfigType(configType)
	local types = _G.Enum and _G.Enum.TraitConfigType
	if configType == nil or not types then
		return false
	end
	return configType == types.Combat or (types.CamelotCombat ~= nil and configType == types.CamelotCombat)
end

-- ─── /wise client ────────────────────────────────────────────────────
-- Phase 0 of docs/forever-port-plan.md: everything the port inferred from
-- Blizzard's source but could not prove without a running client. Read-only
-- apart from one SavedVariables counter (WiseDB.clientProbeRuns).

-- Retail deprecation-shim globals Wise used to call bare. Expected MISSING on
-- Forever (the Phase 1 premise); on retail they exist only while the
-- loadDeprecationFallbacks CVar is on. Wise no longer depends on any of them.
local SHIM_GLOBALS = {
	"GetSpecialization",
	"GetSpecializationInfo",
	"GetNumSpecializationsForClassID",
	"GetItemCount",
	"GetItemInfo",
	"GetItemIcon",
	"IsEquippedItem",
	"GetCoinTextureString",
}

-- Undocumented natives / FrameXML functions Wise still calls bare. They are
-- absent from the generated API docs, so only a runtime read settles whether
-- Forever has them. Any MISSING here is a new Phase 3 item.
local NATIVE_GLOBALS = {
	"GetClassInfo",
	"GetNumClasses",
	"GetNumSpecializations",
	"GetSpecializationInfoByID",
	"GetSpecializationInfoForClassID",
	"GetFlyoutInfo",
	"GetFlyoutSlotInfo",
	"GetActionInfo",
	"GetMacroInfo",
	"GetMacroBody",
	"GetNumMacros",
	"GetShapeshiftForm",
	"GetShapeshiftFormID",
	"GetShapeshiftFormInfo",
	"GetNumShapeshiftForms",
	"GetProfessions",
	"GetProfessionInfo",
	"GetInventoryItemID",
	"GetInventoryItemTexture",
	"GetBindingKey",
	"GetBindingAction",
	"GetCurrentBindingSet",
	"SetBinding",
	"SaveBindings",
	"SetOverrideBindingClick",
	"ClearOverrideBindings",
	"PlayerHasToy",
	"HasPetUI",
	"IsPlayerSpell",
	"IsSpellKnownOrOverridesKnown",
	"SecureCmdOptionParse",
	"EnumerateFrames",
	"PlaySoundFile",
	"ReloadUI",
}

-- Blizzard frames Wise hides, anchors to, or reads. ZoneAbilityFrame may be
-- absent (Blizzard_ZoneAbility is gated to `mainline`); MultiCastActionBarFrame
-- (shaman totem bar) should exist ONLY on Forever.
local FRAMES = {
	"MainActionBar",
	"MultiBarBottomLeft",
	"StanceBar",
	"PetActionBar",
	"OverrideActionBar",
	"ExtraActionBarFrame",
	"ZoneAbilityFrame",
	"MultiCastActionBarFrame",
	"MicroMenuContainer",
	"BagsBar",
	"EditModeManagerFrame",
}

-- Plain-text copy of the current report, persisted to WiseDB.clientReport so it
-- can be read from SavedVariables after a /reload instead of transcribed from chat.
local reportLines

local function Out(fmt, ...)
	local line = fmt:format(...)
	print("|cff00ccff[Wise]|r " .. line)
	if reportLines then
		reportLines[#reportLines + 1] = (line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
	end
end

local function Mark(ok)
	return ok and "|cff00ff00ok|r" or "|cffff5555MISSING|r"
end

-- Split names into present/absent in _G.
local function Partition(names)
	local present, absent = {}, {}
	for _, name in ipairs(names) do
		if _G[name] ~= nil then
			present[#present + 1] = name
		else
			absent[#absent + 1] = name
		end
	end
	return present, absent
end

local function EnumName(enumTable, value)
	if type(enumTable) ~= "table" then
		return "?"
	end
	for k, v in pairs(enumTable) do
		if v == value then
			return k
		end
	end
	return "?"
end

local function ReportIdentity()
	Out(
		"Client %s (%s), interface %d, WOW_PROJECT_ID=%s, IS_FOREVER=%s",
		tostring(VERSION),
		tostring(BUILD),
		INTERFACE,
		tostring(_G.WOW_PROJECT_ID),
		tostring(IS_FOREVER)
	)
	local rules = _G.C_GameRules
	if HAS_FOREVER_API then
		local ok, preset = pcall(rules.GetForeverExperiencePreset)
		Out(
			"Forever experience preset: %s (%s)",
			tostring(ok and preset),
			ok and EnumName(_G.Enum and _G.Enum.ForeverExperiencePreset, preset) or "error"
		)
	end
	if type(rules) == "table" and type(rules.GetActiveGameMode) == "function" then
		local ok, mode = pcall(rules.GetActiveGameMode)
		Out(
			"Game mode: %s (%s)",
			tostring(ok and mode),
			ok and EnumName(_G.Enum and _G.Enum.GameMode, mode) or "error"
		)
	end
	Out("HAS_IGNORE_GCD=%s (expect true on Forever and retail 12.0.5+)", tostring(Wise.HAS_IGNORE_GCD))
end

local function ReportGlobals()
	local present, absent = Partition(SHIM_GLOBALS)
	Out(
		"Retail shim globals (expect none on Forever): %s",
		#present > 0 and tconcat(present, ", ") or "none present"
	)
	if #absent > 0 then
		Out("  absent: %s", tconcat(absent, ", "))
	end

	present, absent = Partition(NATIVE_GLOBALS)
	Out("Native globals Wise calls bare: %d/%d present", #present, #NATIVE_GLOBALS)
	if #absent > 0 then
		Out("  |cffff5555MISSING|r: %s", tconcat(absent, ", "))
	end
end

local function ReportSpecsAndClasses()
	local CSI = _G.C_SpecializationInfo
	if type(CSI) == "table" and type(CSI.GetSpecialization) == "function" then
		local ok, idx = pcall(CSI.GetSpecialization)
		local specID, specName
		if ok and idx and type(CSI.GetSpecializationInfo) == "function" then
			local okInfo, id, name = pcall(CSI.GetSpecializationInfo, idx)
			if okInfo then
				specID, specName = id, name
			end
		end
		local selection = "n/a"
		if type(CSI.IsSpecSelectionEnabled) == "function" then
			local okSel, enabled = pcall(CSI.IsSpecSelectionEnabled)
			selection = okSel and tostring(enabled) or "error"
		end
		Out(
			"Spec: index=%s id=%s name=%s, selection enabled=%s",
			tostring(ok and idx),
			tostring(specID),
			tostring(specName),
			selection
		)
	else
		Out("Spec: C_SpecializationInfo.GetSpecialization %s", Mark(false))
	end

	local GetNumClasses = _G.GetNumClasses
	if type(GetNumClasses) == "function" then
		local ids = Client.GetClassIDs()
		local labels = {}
		for _, id in ipairs(ids) do
			labels[#labels + 1] = tostring(id)
		end
		Out("Classes: GetNumClasses()=%d, class IDs found: %s", GetNumClasses() or 0, tconcat(labels, ","))
	end
end

local function ReportTalents()
	local CCT, CT = _G.C_ClassTalents, _G.C_Traits
	if not (type(CCT) == "table" and CCT.GetActiveConfigID and type(CT) == "table" and CT.GetConfigInfo) then
		Out("Talents: C_ClassTalents/C_Traits %s", Mark(false))
		return
	end
	local ok, configID = pcall(CCT.GetActiveConfigID)
	local info
	if ok and configID then
		local okInfo, result = pcall(CT.GetConfigInfo, configID)
		info = okInfo and result or nil
	end
	local enumTable = _G.Enum and _G.Enum.TraitConfigType
	Out(
		"Talent config: id=%s type=%s (%s); Enum Combat=%s CamelotCombat=%s",
		tostring(ok and configID),
		tostring(info and info.type),
		info and EnumName(enumTable, info.type) or "?",
		tostring(enumTable and enumTable.Combat),
		tostring(enumTable and enumTable.CamelotCombat)
	)
end

local function ReportFrames()
	local parts = {}
	for _, name in ipairs(FRAMES) do
		parts[#parts + 1] = name .. " " .. Mark(_G[name] ~= nil)
	end
	Out("Frames: %s", tconcat(parts, ", "))
end

-- A counter that must keep climbing across /reload. A third-party report says
-- the Forever beta writes SavedVariables but never reads them back; if so, this
-- restarts at 1 after every reload and no addon can persist settings.
local function ReportSavedVariables()
	local db = _G.WiseDB
	if type(db) ~= "table" then
		Out("SavedVariables: WiseDB is %s", Mark(false))
		return
	end
	local previous = tonumber(db.clientProbeRuns) or 0
	db.clientProbeRuns = previous + 1
	Out(
		"SavedVariables probe: run #%d. /reload and run /wise client again — it must show #%d.",
		previous + 1,
		previous + 2
	)
end

function Client.Report()
	reportLines = {}
	Out("--- client report (docs/forever-port-plan.md, Phase 0) ---")
	-- Each section isolated: one surprise on an unknown client must not hide
	-- the rest of the report.
	for _, section in ipairs({
		ReportIdentity,
		ReportGlobals,
		ReportSpecsAndClasses,
		ReportTalents,
		ReportFrames,
		ReportSavedVariables,
	}) do
		local ok, err = pcall(section)
		if not ok then
			Out("|cffff5555section error|r: %s", tostring(err))
		end
	end
	-- Keep a copy (written to disk on /reload or logout). Run history is kept
	-- per run number so a before/after-reload pair can be compared.
	local db = _G.WiseDB
	if type(db) == "table" then
		db.clientReports = type(db.clientReports) == "table" and db.clientReports or {}
		local runs = tonumber(db.clientProbeRuns) or 0
		db.clientReports[runs] = { time = _G.date and _G.date("%Y-%m-%d %H:%M:%S"), lines = reportLines }
	end
	reportLines = nil
end
