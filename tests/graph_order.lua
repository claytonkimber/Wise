-- wow-ui-sim tests for node graph ordering in Slots and Actions
--
-- Covers the contract for:
--   * Wise:GetOrderedGraphNodes ordering nodes based on graph connections (lanes & depths)
--   * Root nodes leading their chains
--   * Branches ordering into left-to-right sequence steps

test("Graph Order: linear chain preserves sequence", function()
    assertNotNil(Wise.GetOrderedGraphNodes)

    local graph = {
        nodes = {
            { id = 3, action = { type = "spell", value = 300, name = "Step 3" } },
            { id = 1, action = { type = "spell", value = 100, name = "Step 1" } },
            { id = 2, action = { type = "spell", value = 200, name = "Step 2" } },
        },
        connections = {
            { from = 1, to = 2, type = "waterfall" },
            { from = 2, to = 3, type = "waterfall" },
        }
    }

    local ordered = Wise:GetOrderedGraphNodes(graph)
    assertEquals(3, #ordered)
    assertEquals(1, ordered[1].id)
    assertEquals(2, ordered[2].id)
    assertEquals(3, ordered[3].id)
end)

test("Graph Order: branching trees order by lane and depth", function()
    -- Root 1 branches to 2 and 3. Node 2 connects to 4.
    local graph = {
        nodes = {
            { id = 4, action = { type = "spell", value = 400, name = "Sub 1B" } },
            { id = 3, action = { type = "spell", value = 300, name = "Step 2" } },
            { id = 2, action = { type = "spell", value = 200, name = "Sub 1A" } },
            { id = 1, action = { type = "spell", value = 100, name = "Head" } },
        },
        connections = {
            { from = 1, to = 2, type = "waterfall" },
            { from = 1, to = 3, type = "waterfall" },
            { from = 2, to = 4, type = "waterfall" },
        }
    }

    local ordered = Wise:GetOrderedGraphNodes(graph)
    assertEquals(4, #ordered)
    assertEquals(1, ordered[1].id)
    assertEquals(2, ordered[2].id)
    assertEquals(4, ordered[3].id)
    assertEquals(3, ordered[4].id)
end)

test("Graph Order: multiple independent roots", function()
    local graph = {
        nodes = {
            { id = 10, action = { type = "spell", value = 10, name = "Chain B2" } },
            { id = 1, action = { type = "spell", value = 1, name = "Chain A1" } },
            { id = 2, action = { type = "spell", value = 2, name = "Chain A2" } },
            { id = 9, action = { type = "spell", value = 9, name = "Chain B1" } },
        },
        connections = {
            { from = 1, to = 2, type = "waterfall" },
            { from = 9, to = 10, type = "waterfall" },
        }
    }

    local ordered = Wise:GetOrderedGraphNodes(graph)
    assertEquals(4, #ordered)
    assertEquals(1, ordered[1].id)
    assertEquals(2, ordered[2].id)
    assertEquals(9, ordered[3].id)
    assertEquals(10, ordered[4].id)
end)
