-- wow-ui-sim tests for the "Menu Bar" wiser interface.
--
-- Regression guard: UpdateWiserInterfaces used to rebuild the Menu Bar from
-- scratch on every refresh (every SPELLS_CHANGED), wiping .actions, so a slot
-- the user added vanished within seconds, along with any keybind or extra
-- state on a default slot. The bar is now seeded once (wiser/MenuBar.lua):
--   * a refresh keeps the user's slots, keybinds and slot names
--   * each default is added exactly once; a bar saved by the old rebuild
--     adopts the defaults it already holds instead of duplicating them
--   * once seeded, any slot or state can be deleted, defaults included, and a
--     deleted default stays gone
--   * "Reset to Default" (Wise:ResetKeptSlots) brings every default back

local DEFAULTS = {
    "menu", "shop", "adventureguide", "collections", "groupfinder", "guild",
    "housing", "questlog", "achievements", "talents", "professions", "character",
}

local function DeepCopy(t)
    if type(t) ~= "table" then
        return t
    end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = DeepCopy(v)
    end
    return copy
end

-- Run fn, then put the Menu Bar back exactly as it was so one test's edits
-- cannot leak into the next.
local function WithMenuBar(fn)
    local saved = DeepCopy(WiseDB.groups["Menu Bar"])
    local ok, err = pcall(fn)
    WiseDB.groups["Menu Bar"] = saved
    if not ok then
        error(err, 0)
    end
end

-- A freshly seeded bar: the 12 defaults in slots 1-12 and nothing else.
local function FreshBar()
    Wise:ResetKeptSlots(WiseDB.groups["Menu Bar"])
    Wise:UpdateWiserInterfaces()
    return WiseDB.groups["Menu Bar"]
end

local function SlotCount(g)
    local n = 0
    for k in pairs(g.actions) do
        if type(k) == "number" then
            n = n + 1
        end
    end
    return n
end

local function CountPanel(g, panel)
    local n = 0
    for _, states in pairs(g.actions) do
        for _, action in ipairs(states) do
            if action.type == "uipanel" and action.value == panel then
                n = n + 1
            end
        end
    end
    return n
end

local function UserMacro(text)
    return { type = "macro", value = text, category = "global", visibilityEnable = {}, visibilityDisable = {} }
end

test("Menu Bar: seeds each default exactly once", function()
    WithMenuBar(function()
        local g = FreshBar()
        Wise:UpdateWiserInterfaces()
        Wise:UpdateWiserInterfaces()
        g = WiseDB.groups["Menu Bar"]
        assertTrue(g.keepsUserSlots)
        assertEquals(12, SlotCount(g))
        for i, panel in ipairs(DEFAULTS) do
            assertEquals(panel, g.actions[i][1].value)
            assertEquals(1, CountPanel(g, panel))
        end
    end)
end)

test("Menu Bar: a slot the user adds survives a refresh", function()
    WithMenuBar(function()
        local g = FreshBar()
        local slot = Wise:AddAction("Menu Bar", nil, "macro", "/dance")
        assertEquals(13, slot)
        g.actions[1].keybind = "CTRL-F9"
        g.slotNames = { [slot] = "Dance" }

        Wise:UpdateWiserInterfaces()

        g = WiseDB.groups["Menu Bar"]
        assertEquals(13, SlotCount(g))
        assertNotNil(g.actions[slot])
        assertEquals("/dance", g.actions[slot][1].value)
        assertEquals("CTRL-F9", g.actions[1].keybind)
        assertEquals("Dance", g.slotNames[slot])
    end)
end)

test("Menu Bar: any slot can be deleted, and a deleted default stays gone", function()
    WithMenuBar(function()
        local g = FreshBar()
        local slot = Wise:AddAction("Menu Bar", nil, "macro", "/dance")
        for i = 1, slot do
            assertFalse(Wise:IsAutoImportedSlot(g, i))
        end

        -- A default slot: "shop" goes, and the slots after it close the gap.
        Wise:RemoveSlot("Menu Bar", 2)
        assertEquals(0, CountPanel(g, "shop"))
        assertEquals("adventureguide", g.actions[2][1].value)
        assertEquals(12, SlotCount(g))

        -- A default action, and a state the user added to a default slot.
        Wise:AddAction("Menu Bar", 1, "macro", "/wave")
        assertFalse(Wise:IsAutoImportedAction(g, 1, g.actions[1][1]))
        Wise:RemoveActionFromSlot("Menu Bar", 1, 2)
        Wise:RemoveActionFromSlot("Menu Bar", 1, 1)
        assertEquals(0, #g.actions[1])

        -- A slot the user added (it moved up one when "shop" went).
        Wise:RemoveSlot("Menu Bar", slot - 1)
        assertEquals(11, SlotCount(g))

        Wise:UpdateWiserInterfaces()
        Wise:UpdateWiserInterfaces()

        g = WiseDB.groups["Menu Bar"]
        assertEquals(11, SlotCount(g))
        assertEquals(0, CountPanel(g, "shop"))
        assertEquals(0, CountPanel(g, "menu"))
    end)
end)

test("Menu Bar: a bar saved by the old rebuild adopts its defaults", function()
    WithMenuBar(function()
        -- What the old rebuild left in SavedVariables: the defaults in .buttons,
        -- .actions cleared, and no seeding record.
        local g = WiseDB.groups["Menu Bar"]
        g.actions, g.migratedToActions = nil, nil
        g.seededDefaults, g.keepsUserSlots = nil, nil
        g.buttons = {}
        for _, panel in ipairs(DEFAULTS) do
            table.insert(g.buttons, { type = "uipanel", value = panel, category = "global" })
        end

        Wise:UpdateWiserInterfaces()

        g = WiseDB.groups["Menu Bar"]
        assertEquals(12, SlotCount(g))
        for i, panel in ipairs(DEFAULTS) do
            assertEquals(panel, g.actions[i][1].value)
            assertTrue(g.seededDefaults[panel])
        end
        -- Dropped once copied, or [available] keeps counting an emptied bar.
        assertNil(g.buttons)
    end)
end)

test("Menu Bar: a default the user replaced is not put back", function()
    WithMenuBar(function()
        local g = FreshBar()
        g.actions[2] = { UserMacro("/dance") }

        Wise:UpdateWiserInterfaces()

        g = WiseDB.groups["Menu Bar"]
        assertEquals(12, SlotCount(g))
        assertEquals(0, CountPanel(g, "shop"))
        assertEquals("/dance", g.actions[2][1].value)
    end)
end)

test("Menu Bar: a default shipped later reaches an existing bar once", function()
    WithMenuBar(function()
        -- As if "character" were new in this release: never seeded, not on the bar.
        local g = FreshBar()
        g.actions[12] = nil
        g.seededDefaults.character = nil
        local slot = Wise:AddAction("Menu Bar", nil, "macro", "/dance")

        Wise:UpdateWiserInterfaces()
        Wise:UpdateWiserInterfaces()

        g = WiseDB.groups["Menu Bar"]
        assertEquals(1, CountPanel(g, "character"))
        assertEquals("/dance", g.actions[slot][1].value)
        assertEquals("character", g.actions[slot + 1][1].value)
    end)
end)

test("Menu Bar: Reset to Default brings deleted defaults back", function()
    WithMenuBar(function()
        local g = FreshBar()
        Wise:RemoveSlot("Menu Bar", 12)
        Wise:RemoveSlot("Menu Bar", 2)
        g.actions[1] = { UserMacro("/wave") }
        local slot = Wise:AddAction("Menu Bar", nil, "macro", "/dance")
        g.slotNames = { [slot] = "Dance" }
        Wise:UpdateWiserInterfaces()
        assertEquals(0, CountPanel(WiseDB.groups["Menu Bar"], "shop"))

        Wise:ResetKeptSlots(WiseDB.groups["Menu Bar"])
        Wise:UpdateWiserInterfaces()

        g = WiseDB.groups["Menu Bar"]
        assertEquals(12, SlotCount(g))
        for i, panel in ipairs(DEFAULTS) do
            assertEquals(panel, g.actions[i][1].value)
        end
        assertNil(g.slotNames)
    end)
end)

-- The delete guards in Actions.lua and Properties.lua now share one rule;
-- interfaces other than the Menu Bar must be protected exactly as before.
test("Auto-imported slot rules are unchanged for other interfaces", function()
    local rebuilt = { isWiser = true, actions = { [1] = { { type = "misc", value = "spec_1" } } } }
    assertTrue(Wise:IsAutoImportedSlot(rebuilt, 1))
    assertTrue(Wise:IsAutoImportedAction(rebuilt, 1, rebuilt.actions[1][1]))

    local cooldowns = {
        isWiser = true,
        propertyType = "CooldownWiser",
        actions = {
            [1] = { { type = "spell", value = 1, autoLoaded = true }, { type = "spell", value = 2 } },
            [1.1] = { { type = "spell", value = 3 } },
        },
    }
    assertTrue(Wise:IsAutoImportedSlot(cooldowns, 1))
    assertFalse(Wise:IsAutoImportedSlot(cooldowns, 1.1))
    assertTrue(Wise:IsAutoImportedAction(cooldowns, 1, cooldowns.actions[1][1]))
    assertFalse(Wise:IsAutoImportedAction(cooldowns, 1, cooldowns.actions[1][2]))
    assertFalse(Wise:IsAutoImportedAction(cooldowns, 1.1, cooldowns.actions[1.1][1]))

    local custom = { actions = { [1] = { { type = "spell", value = 1, autoLoaded = true } } } }
    assertFalse(Wise:IsAutoImportedSlot(custom, 1))
    assertFalse(Wise:IsAutoImportedAction(custom, 1, custom.actions[1][1]))
end)
