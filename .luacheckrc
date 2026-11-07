-- Luacheck configuration for the Wise addon.
--
-- Without WoW globals declared, luacheck flags every CreateFrame/UIParent/
-- C_Spell/etc. as "accessing undefined variable" — thousands of false
-- positives (~75% of all warnings) that bury real findings and waste tokens
-- when the lint output is read back.
--
-- The WoW global list lives in WoWGlobals.luacheckrc, GENERATED from Mechanic's
-- API database via `mech call api.luacheck`. Regenerate it after
-- `mech api download` to track new patches. Do not hand-edit that file.
--
-- Mechanic invokes:  luacheck <addonPath> --formatter plain --codes --no-color
-- so this file is picked up automatically from the addon root.

std = "lua51"

-- Load the generated WoW globals (relative to this config file). luacheck does
-- not put the addon dir on package.path, so resolve the path explicitly.
local config_dir = (debug.getinfo(1, "S").source:match("@?(.*[/\\])")) or "./"

-- WoW Forever guard. These names exist on retail only as Blizzard_Deprecated*
-- shims (and only while the loadDeprecationFallbacks CVar is on); on WoW Forever
-- they are nil. Strip them from the generated list so any bare use is reported
-- as an undefined global. Call the C_* function they alias instead
-- (C_SpecializationInfo.*, C_Item.*, C_CurrencyInfo.*). The generated file
-- itself must not be hand-edited. See docs/forever-port-plan.md.
local RETAIL_SHIM_ONLY = {
	GetSpecialization = true,
	GetSpecializationInfo = true,
	GetNumSpecializationsForClassID = true,
	GetItemCount = true,
	GetItemInfo = true,
	GetItemIcon = true,
	IsEquippedItem = true,
	GetCoinTextureString = true,
}
local wowGlobals = {}
for _, name in ipairs(dofile(config_dir .. "WoWGlobals.luacheckrc")) do
	if not RETAIL_SHIM_ONLY[name] then
		wowGlobals[#wowGlobals + 1] = name
	end
end
read_globals = wowGlobals

-- Globals the Wise addon legitimately defines / mutates.
globals = {
	"Wise", -- addon namespace table
	"WiseDB", -- SavedVariables (declared in Wise.toc)
	"_", -- conventional throwaway placeholder
}

-- Don't lint vendored third-party libraries we don't maintain.
exclude_files = {
	"Libs/",
	"node_modules/",
	"patches/",
}

-- Busted spec files get the test DSL as globals instead of undefined-variable
-- noise. Adjust the pattern if specs live elsewhere.
files["**/*_spec.lua"] = {
	std = "+busted",
}
files["**/spec/**/*.lua"] = {
	std = "+busted",
}

-- Quiet a few stylistic warnings that are pure noise for a WoW addon.
ignore = {
	"212/self", -- unused argument 'self' (ubiquitous in :method definitions)
	"212/event", -- unused 'event' arg in OnEvent handlers
	"212/_.*", -- unused args explicitly named with a leading underscore
	"432", -- shadowing an upvalue (common with localized API caches)
	"631", -- line is too long (let stylua own formatting width)
}
