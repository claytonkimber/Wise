-- wow-ui-sim tests for the "Addons" wiser interface.
--
-- Covers the contract added when Addons moved to one-slot-per-loaded-addon:
--   * every top-level addon gets exactly one slot (no duplicates)
--   * nested modules (BigWigs_Core, ConsolePort_Bar, ...) get no slot
--   * a slot may exist with NO command assigned yet — the user picks one in
--     the properties panel — and that must not error when the button is bound
--   * a saved slash-command override is honored unconditionally
--
-- The nil-command case is a regression guard: it previously crashed with
-- "GUI.lua: bad argument #1 to 'sub' (string expected, got nil)" because the
-- macro branch of the secure-attribute builder assumed a non-nil value.

-- 1. GetAddons produces at most one slot per addon.
test("Addons: no duplicate slots", function()
    assertNotNil(Wise.GetAddons)
    local items = Wise:GetAddons()
    assertNotNil(items)

    local counts = {}
    for _, it in ipairs(items) do
        local key = it.addonName or it.name
        counts[key] = (counts[key] or 0) + 1
    end
    for key, n in pairs(counts) do
        if n ~= 1 then
            error("expected exactly one slot for " .. tostring(key) .. ", got " .. n)
        end
    end
end)

-- 2. Every produced slot is well-formed.
test("Addons: slots are well-formed", function()
    for _, it in ipairs(Wise:GetAddons()) do
        assertEquals("Addons", it.category)
        assertNotNil(it.name)
        assertNotNil(it.icon)
        assertType("table", it.availableCommands or {})
    end
end)

-- 3. A command-less slot must bind without erroring.
-- This is the exact shape that crashed: type="macro" with value=nil.
test("Addons: command-less slot binds without error", function()
    local actionData = {
        type = "macro",
        value = nil,
        name = "!Mechanic",
        addonName = "!Mechanic",
        category = "Addons",
        hasCommand = false,
        availableCommands = {},
    }

    local ok, sType = pcall(function()
        return Wise:GetSecureAttributes(actionData, nil)
    end)
    if not ok then
        error("binding a command-less Addons slot errored: " .. tostring(sType))
    end
end)

-- 4. Same, but with saved parameters present (the second latent crash:
--    "attempt to concatenate a nil value" when slashArgs was set).
test("Addons: command-less slot with slashArgs binds without error", function()
    local actionData = {
        type = "macro",
        value = nil,
        name = "!Mechanic",
        addonName = "!Mechanic",
        category = "Addons",
        hasCommand = false,
        slashArgs = "window",
        availableCommands = {},
    }

    local ok, err = pcall(function()
        return Wise:GetSecureAttributes(actionData, nil)
    end)
    if not ok then
        error("binding a command-less slot with args errored: " .. tostring(err))
    end
end)

-- A real command still round-trips correctly through the same builder.
test("Addons: normal slash command still binds correctly", function()
    local ok, sType = pcall(function()
        return Wise:GetSecureAttributes({ type = "macro", value = "/bigwigs" }, nil)
    end)
    if not ok then
        error("binding a normal command errored: " .. tostring(sType))
    end
end)

-- 5. A command-less macro action still counts as "known", or the button would
--    be filtered out of the interface entirely.
test("Addons: command-less macro action is known", function()
    assertTrue(Wise:IsActionKnown("macro", nil))
    assertTrue(Wise:IsActionKnown("macro", ""))
    assertTrue(Wise:IsActionKnown("macro", "/bigwigs"))
end)

-- 6. The tooltip for a command-less slot must name the addon, never render the
--    literal "Macro: nil" (reported in-game after the crash was fixed).
test("Addons: command-less slot tooltip does not say 'Macro: nil'", function()
    local shown = {}
    local realSetText, realAddLine = GameTooltip.SetText, GameTooltip.AddLine
    local realOwner, realShow = GameTooltip.SetOwner, GameTooltip.Show
    GameTooltip.SetText = function(self, text) table.insert(shown, tostring(text)) end
    GameTooltip.AddLine = function(self, text) table.insert(shown, tostring(text)) end
    GameTooltip.SetOwner = function() end
    GameTooltip.Show = function() end

    local btn = CreateFrame("Button", "WiseAddonsTooltipProbe", UIParent)
    btn.actionType = "macro"
    btn.actionValue = nil
    btn.actionData = { type = "macro", value = nil, name = "!Mechanic", addonName = "!Mechanic" }

    WiseDB.settings = WiseDB.settings or {}
    local savedSetting = WiseDB.settings.showTooltips
    WiseDB.settings.showTooltips = true

    Wise:AddInterfaceTooltip(btn)
    local ok, err = pcall(function() btn:GetScript("OnEnter")(btn) end)

    WiseDB.settings.showTooltips = savedSetting
    GameTooltip.SetText, GameTooltip.AddLine = realSetText, realAddLine
    GameTooltip.SetOwner, GameTooltip.Show = realOwner, realShow

    if not ok then
        error("tooltip for a command-less slot errored: " .. tostring(err))
    end

    local joined = table.concat(shown, " | ")
    if joined:find("nil", 1, true) then
        error("tooltip leaked a nil value: " .. joined)
    end
    if not joined:find("!Mechanic", 1, true) then
        error("tooltip did not name the addon: " .. joined)
    end
end)

-- 7. Clicking a command-less slot opens the options panel to that addon's slot
--    with its action selected, so the slash-command picker is on screen. This
--    is the click path the in-game button's PostClick hook takes; previously
--    the button was inert and the tooltip just told the user to find the panel.
test("Addons: OpenAddonCommandPicker selects the addon's slot", function()
    assertNotNil(Wise.OpenAddonCommandPicker)

    local group = WiseDB.groups and WiseDB.groups["Addons"]
    assertNotNil(group)
    assertNotNil(group.actions)

    -- Pick any real addon slot to target.
    local targetSlot, targetAddon
    for slotIdx, states in pairs(group.actions) do
        local action = type(states) == "table" and states[1]
        if action and action.addonName then
            targetSlot, targetAddon = slotIdx, action.addonName
            break
        end
    end
    if not targetAddon then
        return -- no addon slots in this environment; nothing to assert
    end

    local savedGroup, savedSlot, savedState = Wise.selectedGroup, Wise.selectedSlot, Wise.selectedState
    Wise.selectedGroup, Wise.selectedSlot, Wise.selectedState = nil, nil, nil

    local ok, err = pcall(function()
        return Wise:OpenAddonCommandPicker(targetAddon)
    end)

    local gotGroup, gotSlot, gotState = Wise.selectedGroup, Wise.selectedSlot, Wise.selectedState
    Wise.selectedGroup, Wise.selectedSlot, Wise.selectedState = savedGroup, savedSlot, savedState

    if not ok then
        error("OpenAddonCommandPicker errored: " .. tostring(err))
    end
    assertEquals("Addons", gotGroup)
    assertEquals(targetSlot, gotSlot)
    -- State 1 is required: RenderSlotProperties has no slash-command picker,
    -- only RenderActionProperties does.
    assertEquals(1, gotState)
end)

-- 8. An unknown addon name must not leave a stale slot selected.
test("Addons: OpenAddonCommandPicker clears selection for an unknown addon", function()
    local savedGroup, savedSlot, savedState = Wise.selectedGroup, Wise.selectedSlot, Wise.selectedState
    Wise.selectedSlot, Wise.selectedState = 999, 5

    local ok, err = pcall(function()
        return Wise:OpenAddonCommandPicker("ThisAddonDoesNotExist_Probe")
    end)

    local gotSlot, gotState = Wise.selectedSlot, Wise.selectedState
    Wise.selectedGroup, Wise.selectedSlot, Wise.selectedState = savedGroup, savedSlot, savedState

    if not ok then
        error("OpenAddonCommandPicker errored on unknown addon: " .. tostring(err))
    end
    if gotSlot ~= nil or gotState ~= nil then
        error("stale selection left behind: slot=" .. tostring(gotSlot) .. " state=" .. tostring(gotState))
    end
end)

-- 9. A saved override is honored even when the scan does not re-detect it.
test("Addons: saved slash override is honored", function()
    assertNotNil(WiseDB)
    local saved = WiseDB.addonSlashOverrides
    WiseDB.addonSlashOverrides = { Wise = "/wise-override-probe" }

    local found
    for _, it in ipairs(Wise:GetAddons()) do
        if it.addonName == "Wise" then
            found = it
        end
    end

    WiseDB.addonSlashOverrides = saved

    if found then
        assertEquals("/wise-override-probe", found.value)
    end
end)
