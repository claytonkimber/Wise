-- Regression tests for Wise:GetActiveRotationSpells and the picker usage dots.
--
-- Slots authored in the slot configurator compile every graph node into
-- misc/custom_macro states, so the spells only exist on slotStates.graph.nodes.
-- GetActiveRotationSpells must walk those nodes: a spell placed on a node is
-- directly used (picker shows NO dot), not merely macro-referenced (yellow dot).

test("GetActiveRotationSpells: plain spell states register as bound", function()
    local saved = WiseDB
    WiseDB = {
        groups = {
            TestPlain = {
                dynamic = false,
                actions = {
                    [1] = {
                        { type = "spell", value = 8936 }, -- Regrowth
                    },
                },
            },
        },
    }

    local _, boundSpellIDs = Wise:GetActiveRotationSpells()
    WiseDB = saved

    assertTrue(boundSpellIDs[8936])
end)

test("GetActiveRotationSpells: graph node spells register as bound", function()
    local saved = WiseDB
    WiseDB = {
        groups = {
            TestGraph = {
                dynamic = false,
                actions = {
                    [1] = {
                        -- Compiled step, as the slot configurator stores it: the
                        -- spell only appears inside macroText, not as a spell state.
                        {
                            type = "misc",
                            value = "custom_macro",
                            macroText = "#showtooltip\n/cast [combat] Ascendance",
                        },
                        graph = {
                            nodes = {
                                { id = 1, action = { type = "spell", value = 114050 }, condition = "[combat]" },
                            },
                            connections = {},
                        },
                    },
                },
            },
        },
    }

    local boundSpells, boundSpellIDs, activeMacroTexts = Wise:GetActiveRotationSpells()
    WiseDB = saved

    -- The node's spell must be bound by ID (this is what hides the picker dot).
    assertTrue(boundSpellIDs[114050])
    -- The compiled step's macro text is still collected for the yellow-dot check.
    assertEquals(1, #activeMacroTexts)
end)
