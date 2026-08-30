-- tests/condition_picker.lua
-- Tests for condition parsing, building, and picker commit behavior

test("Conditionals: ParseConditionString parses various macro condition formats", function()
    local p = Wise.ParseConditionString
    assertNotNil(p, "Wise.ParseConditionString should be defined")

    -- Empty / nil
    local g1 = p("")
    assertEquals(1, #g1)
    assertEquals(0, #g1[1])

    -- Single bracket
    local g2 = p("[combat]")
    assertEquals(1, #g2)
    assertEquals(1, #g2[1])
    assertEquals("combat", g2[1][1].token)
    assertEquals(false, g2[1][1].negated)

    -- Negated bracket
    local g3 = p("[nocombat]")
    assertEquals(1, #g3)
    assertEquals(1, #g3[1])
    assertEquals("combat", g3[1][1].token)
    assertEquals(true, g3[1][1].negated)

    -- Multiple tokens in single bracket (AND)
    local g4 = p("[combat,harm,@target]")
    assertEquals(1, #g4)
    assertEquals(3, #g4[1])
    assertEquals("combat", g4[1][1].token)
    assertEquals("harm", g4[1][2].token)
    assertEquals("@target", g4[1][3].token)

    -- Multiple brackets (OR)
    local g5 = p("[bonusbar:1][bonusbar:3]")
    assertEquals(2, #g5)
    assertEquals(1, #g5[1])
    assertEquals("bonusbar:1", g5[1][1].token)
    assertEquals(1, #g5[2])
    assertEquals("bonusbar:3", g5[2][1].token)

    -- Bare token without brackets
    local g6 = p("stealth")
    assertEquals(1, #g6)
    assertEquals(1, #g6[1])
    assertEquals("stealth", g6[1][1].token)
end)

test("Conditionals: BuildConditionString constructs bracketed condition strings", function()
    local b = Wise.BuildConditionString
    assertNotNil(b, "Wise.BuildConditionString should be defined")

    -- Empty
    assertEquals("", b({ {} }))
    assertEquals("", b({}))

    -- Single positive
    assertEquals("[combat]", b({ { { token = "combat", negated = false } } }))

    -- Single negated
    assertEquals("[nocombat]", b({ { { token = "combat", negated = true } } }))

    -- Multiple in one group (AND)
    assertEquals("[combat,help]", b({ { { token = "combat", negated = false }, { token = "help", negated = false } } }))

    -- Multiple groups (OR)
    assertEquals("[bonusbar:1][bonusbar:3]", b({
        { { token = "bonusbar:1", negated = false } },
        { { token = "bonusbar:3", negated = false } }
    }))
end)

test("Conditionals: CommitConditionPicker updates node condition correctly", function()
    local node = { id = 1, condition = "[combat]", action = { type = "spell", value = 123 } }
    Wise._configuratorConditionNode = node
    Wise.pickingCondition = true
    Wise._conditionPickerState = {
        groups = {
            { { token = "combat", negated = false } },
            { { token = "mod:shift", negated = false } }
        },
        activeGroup = 2,
    }

    Wise.CommitConditionPicker()
    assertEquals("[combat][mod:shift]", node.condition)

    -- Modify state to negated
    Wise._conditionPickerState.groups = {
        { { token = "combat", negated = true } }
    }
    Wise.CommitConditionPicker()
    assertEquals("[nocombat]", node.condition)

    -- Cleanup
    Wise.pickingCondition = false
    Wise._conditionPickerState = nil
    Wise._configuratorConditionNode = nil
end)
