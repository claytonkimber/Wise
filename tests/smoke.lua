-- wow-ui-sim smoke tests for Wise
--
-- Run headless (no WoW client) from the simulator repo:
--   cd ../wow-ui-sim
--   ./target/release/wow-sim --no-saved-vars run-tests Wise
--
-- The simulator loads the Wise addon (via its .toc), then executes the
-- test(...) / async_test(...) cases in this folder using its built-in
-- TestFramework (assertEquals, assertTrue, ... — see the wow-ui-sim README).
--
-- Keep these as fast, deterministic API-level checks. In-client manual QA
-- lives in tests.xml (the WiseDebug* checklist), which is a different thing.

-- 1. Sanity: the simulator's frame API is alive and the harness runs.
test("simulator: CreateFrame returns a named frame", function()
    local f = CreateFrame("Frame", "WiseSimSmokeFrame", UIParent)
    assertNotNil(f)
    assertEquals("WiseSimSmokeFrame", f:GetName())
    f:SetSize(120, 40)
    assertEquals(120, f:GetWidth())
    assertEquals(40, f:GetHeight())
end)

-- 2. Integration: the Wise addon actually loaded into the simulator.
test("Wise: global addon table is present", function()
    assertNotNil(Wise)
    assertType("table", Wise)
end)

-- 3. Integration: a stable Wise field exists after load.
test("Wise: characterInfo table is initialized", function()
    assertNotNil(Wise.characterInfo)
    assertType("table", Wise.characterInfo)
end)
