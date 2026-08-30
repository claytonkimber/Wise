-- wow-ui-sim tests for Slot Configurator copy/paste nodes functionality
--
-- Covers:
--   * Copying nodes clones graph and preserves node data
--   * Filtering: only visible nodes under the active filter are copied
--   * Pasting nodes into empty slot
--   * Additive paste: pasting into a slot with existing nodes appends without clobbering
--   * Single-use clipboard behavior (empties after paste)
--   * Independence of source and pasted copies

test("Copy Paste Nodes: copy and paste clone graph into another slot", function()
    assertNotNil(Wise.CopyCurrentSlotNodes)
    assertNotNil(Wise.PasteCopiedNodes)

    WiseDB = WiseDB or {}
    WiseDB.groups = WiseDB.groups or {}
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

test("Copy Paste Nodes: additive paste preserves existing nodes in target slot", function()
    WiseDB = WiseDB or {}
    WiseDB.groups = WiseDB.groups or {}
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

test("Copy Paste Nodes: only copies visible nodes when filter is active", function()
    WiseDB = WiseDB or {}
    WiseDB.groups = WiseDB.groups or {}
    WiseDB.groups["TestGroupFilter"] = {
        name = "TestGroupFilter",
        actions = {
            [1] = {
                graph = {
                    nodes = {
                        { id = 1, action = { type = "spell", value = 116, name = "Frostbolt", addedBySpec = 64 }, condition = "" },
                        { id = 2, action = { type = "spell", value = 133, name = "Fireball", addedBySpec = 63 }, condition = "" },
                        { id = 3, action = { type = "spell", value = 30455, name = "Ice Lance", addedBySpec = 64 }, condition = "" },
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
    Wise.characterInfo = Wise.characterInfo or {}
    Wise.characterInfo.specId = 64
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

    -- Reset filter
    Wise.ActionFilter = "global"
end)
