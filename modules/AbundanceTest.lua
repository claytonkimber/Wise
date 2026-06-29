local addonName, Wise = ...

-- Abundance rules migration --------------------------------------------------
-- The Abundance "Colors, Glows & Sounds" feature was originally a GLOBAL,
-- Resto-Druid-only rule set stored at WiseDB.settings.abundanceExperiment.rules.
-- It is now a general PER-ACTION feature (modules/IndicatorRules.lua,
-- action.indicatorRules) authored in the slot configurator node window. This
-- module just migrates any pre-existing global rule set onto the Abundance
-- action(s) the player has configured, then retires the global store. After
-- migration this file does nothing.

-- True when an action IS Abundance — a plain Abundance spell action OR a
-- graph-compiled custom_macro that casts it.
local function ActionIsAbundance(action)
	if type(action) ~= "table" then
		return false
	end
	if action.type == "spell" and action.value then
		local spellName
		local valNum = tonumber(action.value)
		if valNum then
			local spellInfo = C_Spell.GetSpellInfo(valNum)
			spellName = spellInfo and spellInfo.name
		else
			spellName = action.value
		end
		return spellName == "Abundance"
	elseif action.type == "misc" and action.value == "custom_macro" and action.macroText then
		return action.macroText:find("Abundance", 1, true) ~= nil
	end
	return false
end

local function MigrateAbundanceRules()
	if not WiseDB or not WiseDB.settings then
		return
	end
	local exp = WiseDB.settings.abundanceExperiment
	if not exp or type(exp.rules) ~= "table" or #exp.rules == 0 then
		-- Nothing to migrate (already done, or never configured).
		WiseDB.settings.abundanceExperiment = nil
		return
	end
	if not WiseDB.groups then
		return
	end

	local copiedToAny = false
	for _, group in pairs(WiseDB.groups) do
		if type(group.actions) == "table" then
			for _, states in pairs(group.actions) do
				if type(states) == "table" and states.graph and type(states.graph.nodes) == "table" then
					for _, node in ipairs(states.graph.nodes) do
						local a = node.action
						-- The original feature only ever applied to Abundance, so move the
						-- global rules onto the Abundance node(s). Don't clobber rules a user
						-- has already set per-action.
						if a and ActionIsAbundance(a) and type(a.indicatorRules) ~= "table" then
							a.indicatorRules = CopyTable(exp.rules)
							copiedToAny = true
						end
					end
				end
			end
		end
	end

	-- Retire the global store regardless: the data now lives per-action (or there
	-- was no Abundance action to attach it to, in which case it's obsolete anyway).
	WiseDB.settings.abundanceExperiment = nil
	if copiedToAny and Wise.RebuildIndicatorRules then
		Wise:RebuildIndicatorRules()
	end
end

local migrationFrame = CreateFrame("Frame")
migrationFrame:RegisterEvent("PLAYER_LOGIN")
migrationFrame:SetScript("OnEvent", function(self)
	self:UnregisterAllEvents()
	-- Run after the saved variables + groups are fully available.
	MigrateAbundanceRules()
end)
