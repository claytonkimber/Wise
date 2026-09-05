-- wow-ui-sim tests for clicking a node in Slots and Actions.
--
-- Clicking a node used to select the state, which rendered a Right-panel view
-- holding only that node's condition plus an "Open Slot Configurator" button.
-- It now routes through Wise:OpenSlotConfiguratorAtNode so the configurator
-- opens with that node's Properties overlay already showing.
--
-- Scope note: these assert the state OpenSlotConfiguratorAtNode sets, not the
-- rendering. Wise.OptionsFrame is nil under the sim, so RefreshPropertiesPanel
-- returns at its own guard and no frames are built here.
--
-- Covers the contract for:
--   * resolving nodeId against the configurator's own imported graph copy
--   * pinning editingNodePropertiesNode to that imported node, not the caller's
--   * leaving the plain canvas open when the id does not resolve

local function MakeGraphGroup()
    WiseDB = WiseDB or {}
    WiseDB.groups = WiseDB.groups or {}
    WiseDB.groups["RoutingTest"] = {
        type = "line",
        -- anchor is required: MaybeEnterEmbeddedConfigurator runs ValidateGroup and
        -- tears the configurator back down for a group without one.
        anchor = { point = "CENTER", x = 0, y = 0 },
        actions = {
            [1] = {
                { type = "spell", value = 100, conditions = "" },
                { type = "spell", value = 200, conditions = "[combat]" },
                graph = {
                    nodes = {
                        { id = 11, action = { type = "spell", value = 100 }, condition = "" },
                        { id = 22, action = { type = "spell", value = 200 }, condition = "[combat]" },
                    },
                    connections = {
                        { from = 11, to = 22, type = "waterfall" },
                    },
                },
            },
        },
    }
    Wise.selectedGroup = "RoutingTest"
    Wise.selectedSlot = 1
    Wise.selectedState = nil
end

local function ClearConfigurator()
    Wise.configuringSlot = false
    Wise.editingNodeProperties = false
    Wise.editingNodePropertiesNode = nil
end

test("Node routing: opens Properties pinned to the clicked node", function()
    assertNotNil(Wise.OpenSlotConfiguratorAtNode)
    MakeGraphGroup()
    ClearConfigurator()

    Wise:OpenSlotConfiguratorAtNode("RoutingTest", 1, 22)

    assertTrue(Wise.configuringSlot)
    assertTrue(Wise.editingNodeProperties)
    assertNotNil(Wise.editingNodePropertiesNode)
    assertEquals(22, Wise.editingNodePropertiesNode.id)
    -- The pinned node carries the imported condition, so the Properties panel
    -- opens on this node's real data rather than a blank or wrong node.
    assertEquals("[combat]", Wise.editingNodePropertiesNode.condition)

    ClearConfigurator()
end)

test("Node routing: the first node resolves as well as the last", function()
    MakeGraphGroup()
    ClearConfigurator()

    Wise:OpenSlotConfiguratorAtNode("RoutingTest", 1, 11)

    assertTrue(Wise.editingNodeProperties)
    assertEquals(11, Wise.editingNodePropertiesNode.id)
    assertEquals("", Wise.editingNodePropertiesNode.condition)

    ClearConfigurator()
end)

test("Node routing: pinned node is the imported copy, not the saved table", function()
    MakeGraphGroup()
    ClearConfigurator()

    local saved = WiseDB.groups["RoutingTest"].actions[1].graph.nodes[2]
    Wise:OpenSlotConfiguratorAtNode("RoutingTest", 1, 22)

    assertEquals(22, Wise.editingNodePropertiesNode.id)
    -- Properties edits its node in place; it must not write straight into saved
    -- data ahead of ExportSlotConfiguratorData.
    assertFalse(saved == Wise.editingNodePropertiesNode)

    ClearConfigurator()
end)

test("Node routing: unresolvable id leaves the canvas open without Properties", function()
    MakeGraphGroup()
    ClearConfigurator()

    Wise:OpenSlotConfiguratorAtNode("RoutingTest", 1, 9999)

    assertTrue(Wise.configuringSlot)
    assertFalse(Wise.editingNodeProperties)
    assertNil(Wise.editingNodePropertiesNode)

    ClearConfigurator()
end)

test("Node routing: nil id leaves the canvas open without Properties", function()
    MakeGraphGroup()
    ClearConfigurator()

    Wise:OpenSlotConfiguratorAtNode("RoutingTest", 1, nil)

    assertTrue(Wise.configuringSlot)
    assertFalse(Wise.editingNodeProperties)

    ClearConfigurator()
end)
