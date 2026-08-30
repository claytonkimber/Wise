-- wow-ui-sim tests for tooltips on slots and actions
--
-- Covers the contract for:
--   * Wise:PopulateActionTooltip populating GameTooltip for spells, items, macros, mounts, etc.
--   * Wise:ShowActionTooltip setting owner and showing tooltip
--   * slotFrame and ActionButtons having functional OnEnter/OnLeave scripts

test("Tooltips: spell action populates tooltip", function()
    local shownSpellID = nil
    local shownText = nil
    local realSetSpell = GameTooltip.SetSpellByID
    local realSetText = GameTooltip.SetText
    GameTooltip.SetSpellByID = function(self, id) shownSpellID = id end
    GameTooltip.SetText = function(self, text) shownText = text end

    local dummy = CreateFrame("Button", "WiseSpellTooltipProbe", UIParent)
    local ok = Wise:PopulateActionTooltip(GameTooltip, dummy, "spell", 133, { type = "spell", value = 133 })

    GameTooltip.SetSpellByID = realSetSpell
    GameTooltip.SetText = realSetText

    assertTrue(ok)
    assertEquals(133, shownSpellID)
end)

test("Tooltips: item action populates tooltip", function()
    local shownItemID = nil
    local realSetItem = GameTooltip.SetItemByID
    GameTooltip.SetItemByID = function(self, id) shownItemID = id end

    local dummy = CreateFrame("Button", "WiseItemTooltipProbe", UIParent)
    local ok = Wise:PopulateActionTooltip(GameTooltip, dummy, "item", 6948, { type = "item", value = 6948 })

    GameTooltip.SetItemByID = realSetItem

    assertTrue(ok)
    assertEquals(6948, shownItemID)
end)

test("Tooltips: macro action populates tooltip", function()
    local shownText = nil
    local realSetText = GameTooltip.SetText
    GameTooltip.SetText = function(self, text) shownText = text end

    local dummy = CreateFrame("Button", "WiseMacroTooltipProbe", UIParent)
    local ok = Wise:PopulateActionTooltip(GameTooltip, dummy, "macro", "/dance", { type = "macro", value = "/dance", name = "Dance Macro" })

    GameTooltip.SetText = realSetText

    assertTrue(ok)
    assertEquals("Dance Macro", shownText)
end)

test("Tooltips: empty action returns false", function()
    local dummy = CreateFrame("Button", "WiseEmptyTooltipProbe", UIParent)
    local ok = Wise:PopulateActionTooltip(GameTooltip, dummy, "empty", nil, nil)
    assertFalse(ok)
end)

test("Tooltips: slot frame OnEnter renders without error", function()
    local shownLines = {}
    local realSetText = GameTooltip.SetText
    local realAddLine = GameTooltip.AddLine
    local realSetOwner = GameTooltip.SetOwner
    local realShow = GameTooltip.Show
    GameTooltip.SetText = function(self, text) table.insert(shownLines, text) end
    GameTooltip.AddLine = function(self, text) table.insert(shownLines, text) end
    GameTooltip.SetOwner = function() end
    GameTooltip.Show = function() end

    local container = CreateFrame("Frame", "WiseTestSlotsContainer", UIParent)
    WiseDB.groups = WiseDB.groups or {}
    WiseDB.groups["TestGroup"] = {
        name = "TestGroup",
        actions = {
            [1] = {
                { type = "spell", value = 133, name = "Fireball" }
            }
        }
    }
    Wise.selectedGroup = "TestGroup"

    Wise:RefreshActionsView(container)
    local slot = container.slots and container.slots[1]
    assertNotNil(slot)

    local ok, err = pcall(function()
        local onEnter = slot:GetScript("OnEnter")
        if onEnter then onEnter(slot) end
    end)

    GameTooltip.SetText = realSetText
    GameTooltip.AddLine = realAddLine
    GameTooltip.SetOwner = realSetOwner
    GameTooltip.Show = realShow

    assertTrue(ok)
end)
