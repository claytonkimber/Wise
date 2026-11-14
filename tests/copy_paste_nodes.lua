-- wow-ui-sim tests for Slot Configurator copy/paste nodes functionality
--
-- Covers:
--   * Opening a slot whose stored graph has ZERO compiled steps keeps the graph
--     (it used to load an empty canvas, and Apply then saved that over the graph)
--   * Copying nodes clones graph and preserves node data
--   * Filtering: only visible nodes under the active filter are copied
--   * Pasting nodes into empty slot
--   * Additive paste: pasting into a slot with existing nodes appends without clobbering
--   * Single-use clipboard behavior (empties after paste)
--   * Independence of source and pasted copies
--
-- The fixtures store a graph with no compiled steps on purpose: that is the
-- shape ImportSlotData used to discard (see the comment in its `#items == 0`
-- branch). Paste ends in ExportToSlotData, which refreshes the options window's
-- action list, so the real options frame is created first, as in
-- keybind_conflict.lua.

-- Run fn with the configurator's inputs controlled, then always restore them:
-- close the configurator without exporting, drop the test interfaces, empty the
-- clipboard and put the action filter and character info back.
local function withConfigurator(groupNames, fn)
    if not Wise.OptionsFrame then
        Wise:CreateOptionsFrame()
    end
    WiseDB.groups = WiseDB.groups or {}
    Wise.characterInfo = Wise.characterInfo or {}

    local savedFilter = Wise.ActionFilter
    local savedSpecID = Wise.characterInfo.specID
    local savedClass = Wise.characterInfo.class
    local savedGroups = {}
    for _, name in ipairs(groupNames) do
        savedGroups[name] = WiseDB.groups[name]
    end

    local ok, err = pcall(fn)

    Wise:CloseSlotConfigurator(true)
    Wise._copiedNodesClipboard = nil
    Wise.ActionFilter = savedFilter
    Wise.characterInfo.specID = savedSpecID
    Wise.characterInfo.class = savedClass
    for _, name in ipairs(groupNames) do
        WiseDB.groups[name] = savedGroups[name]
    end

    if not ok then
        error(err, 0)
    end
end

test("Copy Paste Nodes: a slot with a graph but no compiled steps keeps its graph", function()
    withConfigurator({ "TestGroupGraphOnly" }, function()
        WiseDB.groups["TestGroupGraphOnly"] = {
            name = "TestGroupGraphOnly",
            actions = {
                [1] = {
                    graph = {
                        nodes = {
                            { id = 1, action = { type = "spell", value = 116, name = "Frostbolt" }, condition = "[combat]" },
                            { id = 2, action = { type = "spell", value = 30455, name = "Ice Lance" }, condition = "" },
                        },
                        connections = {
                            { from = 1, to = 2, type = "waterfall" },
                        },
                    },
                },
            },
        }

        Wise:OpenSlotConfigurator("TestGroupGraphOnly", 1)
        -- Save the canvas back to the slot. Every save path (Apply, closing the
        -- condition picker, paste) ends here. CloseSlotConfigurator(false) is not
        -- used: with the options frame up, the configurator only stays "open"
        -- while Wise.selectedGroup/selectedSlot point at it, so it would no-op.
        Wise:ExportSlotConfiguratorData()

        local graph = WiseDB.groups["TestGroupGraphOnly"].actions[1].graph
        assertNotNil(graph)
        assertEquals(2, #graph.nodes)
        assertEquals(116, graph.nodes[1].action.value)
        assertEquals("[combat]", graph.nodes[1].condition)
        assertEquals(1, #graph.connections)
    end)
end)

test("Copy Paste Nodes: copy and paste clone graph into another slot", function()
    assertNotNil(Wise.CopyCurrentSlotNodes)
    assertNotNil(Wise.PasteCopiedNodes)

    withConfigurator({ "TestGroup" }, function()
        WiseDB.groups["TestGroup"] = {
            name = "TestGroup",
            actions = {
                [1] = {
                    conflictStrategy = "waterfall",
                    suppressErrors = true,
                    graph = {
                        nodes = {
                            { id = 1, action = { type = "spell", value = 116, name = "Frostbolt" }, condition = "[combat]" },
                            { id = 2, action = { type = "spell", value = 30455, name = "Ice Lance" }, condition = "" },
                        },
                        connections = {
                            { from = 1, to = 2, type = "waterfall" },
                        },
                    },
                },
                [2] = {
                    conflictStrategy = "waterfall",
                    graph = {
                        nodes = {},
                        connections = {},
                    },
                },
            },
        }

        -- 1. Open slot 1 and copy (unfiltered)
        Wise.ActionFilter = "global"
        Wise:OpenSlotConfigurator("TestGroup", 1)
        Wise:CopyCurrentSlotNodes()

        assertNotNil(Wise._copiedNodesClipboard)
        assertNotNil(Wise._copiedNodesClipboard.graph)
        assertEquals(2, #Wise._copiedNodesClipboard.graph.nodes)
        assertEquals(1, #Wise._copiedNodesClipboard.graph.connections)
        assertTrue(Wise._copiedNodesClipboard.suppressErrors)

        -- 2. Open slot 2 and paste
        Wise:OpenSlotConfigurator("TestGroup", 2)
        Wise:PasteCopiedNodes()

        -- Slot 2 should now have the identical nodes and connections
        local slot2 = WiseDB.groups["TestGroup"].actions[2]
        assertNotNil(slot2.graph)
        assertEquals(2, #slot2.graph.nodes)
        assertEquals(116, slot2.graph.nodes[1].action.value)
        assertEquals("[combat]", slot2.graph.nodes[1].condition)
        assertEquals(30455, slot2.graph.nodes[2].action.value)
        assertEquals(1, #slot2.graph.connections)
        assertEquals(1, slot2.graph.connections[1].from)
        assertEquals(2, slot2.graph.connections[1].to)
        assertTrue(slot2.suppressErrors)

        -- 3. Clipboard should now be empty (one paste per copy click)
        assertNil(Wise._copiedNodesClipboard)

        -- 4. Modifying slot 1 must not affect slot 2
        WiseDB.groups["TestGroup"].actions[1].graph.nodes[1].condition = "[help]"
        assertEquals("[combat]", slot2.graph.nodes[1].condition)
    end)
end)

test("Copy Paste Nodes: additive paste preserves existing nodes in target slot", function()
    withConfigurator({ "TestGroupAdditive" }, function()
        WiseDB.groups["TestGroupAdditive"] = {
            name = "TestGroupAdditive",
            actions = {
                [1] = {
                    graph = {
                        nodes = {
                            { id = 1, action = { type = "spell", value = 116, name = "Frostbolt" }, condition = "" },
                        },
                        connections = {},
                    },
                },
                [2] = {
                    graph = {
                        nodes = {
                            { id = 1, action = { type = "spell", value = 2948, name = "Scorch" }, condition = "" },
                        },
                        connections = {},
                    },
                },
            },
        }

        -- 1. Copy from slot 1
        Wise.ActionFilter = "global"
        Wise:OpenSlotConfigurator("TestGroupAdditive", 1)
        Wise:CopyCurrentSlotNodes()

        -- 2. Paste into slot 2 (which already has Scorch)
        Wise:OpenSlotConfigurator("TestGroupAdditive", 2)
        Wise:PasteCopiedNodes()

        -- Slot 2 should now have BOTH Scorch and Frostbolt
        local slot2 = WiseDB.groups["TestGroupAdditive"].actions[2]
        assertNotNil(slot2.graph)
        assertEquals(2, #slot2.graph.nodes)
        assertEquals(2948, slot2.graph.nodes[1].action.value)
        assertEquals(116, slot2.graph.nodes[2].action.value)
        -- Node IDs should be distinct
        assertEquals(1, slot2.graph.nodes[1].id)
        assertEquals(2, slot2.graph.nodes[2].id)
    end)
end)

test("Copy Paste Nodes: only copies visible nodes when filter is active", function()
    withConfigurator({ "TestGroupFilter" }, function()
        -- The spec filter (Wise:ShouldShowAction, core/Filters.lua) reads
        -- explicit `spec:<id>` visibility tags against characterInfo.specID.
        -- Tagging the nodes keeps the result independent of the sim character's
        -- spellbook, which is what decides untagged spells.
        WiseDB.groups["TestGroupFilter"] = {
            name = "TestGroupFilter",
            actions = {
                [1] = {
                    graph = {
                        nodes = {
                            { id = 1, action = { type = "spell", value = 116, name = "Frostbolt", visibilityEnable = { "spec:64" } }, condition = "" },
                            { id = 2, action = { type = "spell", value = 133, name = "Fireball", visibilityEnable = { "spec:63" } }, condition = "" },
                            { id = 3, action = { type = "spell", value = 30455, name = "Ice Lance", visibilityEnable = { "spec:64" } }, condition = "" },
                        },
                        connections = {
                            { from = 1, to = 2, type = "waterfall" },
                            { from = 2, to = 3, type = "waterfall" },
                        },
                    },
                },
                [2] = {
                    graph = { nodes = {}, connections = {} },
                },
            },
        }

        -- Set active filter to Mage Frost spec (64)
        Wise.ActionFilter = "spec"
        Wise.characterInfo.specID = 64
        Wise.characterInfo.class = "MAGE"

        Wise:OpenSlotConfigurator("TestGroupFilter", 1)
        Wise:CopyCurrentSlotNodes()

        assertNotNil(Wise._copiedNodesClipboard)
        -- Fireball (spec 63) should be filtered out; only 2 nodes copied
        assertEquals(2, #Wise._copiedNodesClipboard.graph.nodes)
        assertEquals(116, Wise._copiedNodesClipboard.graph.nodes[1].action.value)
        assertEquals(30455, Wise._copiedNodesClipboard.graph.nodes[2].action.value)
        -- Connection should bridge from 1 directly to 3
        assertEquals(1, #Wise._copiedNodesClipboard.graph.connections)
        assertEquals(1, Wise._copiedNodesClipboard.graph.connections[1].from)
        assertEquals(3, Wise._copiedNodesClipboard.graph.connections[1].to)
    end)
end)
