-- wow-ui-sim tests for Addon Loading Magic slot state.
--
-- The cycle is: ENABLE the union of every active slot, RELOAD, then immediately
-- UN-CHECK whatever was enabled. Checkbox state and loaded state are independent
-- in WoW, so once the excursion is running the client is ALREADY back to system
-- state for the next reload. A manual /reload therefore lands on system addons
-- with no detection and no clean-up pass — nothing was left checked.
--
-- The active set is stored separately (Wise.addonMagicActive, handed across the
-- reload in WiseDB.addonMagicPending) precisely because the checkboxes no longer
-- record it. That stored set is what lets a later press rebuild the union of all
-- active slots and stack them.
--
-- Addons the user enabled themselves are never un-checked, so a slot sharing an
-- addon with the normal addon list cannot erode that list.

local function resetState()
    WiseDB.addonMagicSlots = {}
    WiseDB.addonMagicPending = nil
    WiseDB.addonMagicUncheck = nil
    WiseDB.addonMagicNextID = 0
    Wise.addonMagicActive = {}
end

-- Installs `slots` (array of addon-name arrays) as slots 1..N and runs fn.
local function withSlots(slots, fn)
    local saved = {
        slots = WiseDB.addonMagicSlots,
        pending = WiseDB.addonMagicPending,
        uncheck = WiseDB.addonMagicUncheck,
        nextID = WiseDB.addonMagicNextID,
        active = Wise.addonMagicActive,
    }
    resetState()
    for i, addons in ipairs(slots) do
        WiseDB.addonMagicSlots[i] = {
            id = Wise:NextAddonMagicSlotID(),
            name = "Probe" .. i,
            addons = addons,
        }
    end

    local ok, err = pcall(fn)

    WiseDB.addonMagicSlots = saved.slots
    WiseDB.addonMagicPending = saved.pending
    WiseDB.addonMagicUncheck = saved.uncheck
    WiseDB.addonMagicNextID = saved.nextID
    Wise.addonMagicActive = saved.active

    if not ok then
        error(err)
    end
end

-- Runs fn with ReloadUI/Enable/Disable stubbed; returns what was touched.
--
-- Deliberately does NOT stub the global `print`: the sim's runner reports test
-- failures through print, so silencing it here would swallow the failure output
-- of every later test file and make a red suite look green.
local function captureToggles(fn)
    local enabled, disabled, reloaded = {}, {}, false
    local realReload = ReloadUI
    local realEnable, realDisable = C_AddOns.EnableAddOn, C_AddOns.DisableAddOn

    ReloadUI = function() reloaded = true end
    C_AddOns.EnableAddOn = function(n) table.insert(enabled, n) end
    C_AddOns.DisableAddOn = function(n) table.insert(disabled, n) end

    local ok, err = pcall(fn)

    ReloadUI = realReload
    C_AddOns.EnableAddOn, C_AddOns.DisableAddOn = realEnable, realDisable

    if not ok then
        error(err)
    end
    return enabled, disabled, reloaded
end

local function contains(list, value)
    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end

test("AddonMagic: state helpers exist", function()
    assertNotNil(Wise.GetAddonMagicSlotState)
    assertNotNil(Wise.IsAddonInstalled)
    assertNotNil(Wise.IsAddonMagicSlotActive)
end)

test("AddonMagic: Wise is installed, a made-up name is not", function()
    assertTrue(Wise:IsAddonInstalled("Wise"))
    assertFalse(Wise:IsAddonInstalled("ThisAddonDoesNotExist_Probe"))
    assertFalse(Wise:IsAddonInstalled(""))
    assertFalse(Wise:IsAddonInstalled(nil))
end)

test("AddonMagic: empty slot reports 'empty'", function()
    withSlots({ {} }, function()
        assertEquals("empty", Wise:GetAddonMagicSlotState(1))
    end)
end)

-- "loaded" must mean PRESSED, not "its addons happen to be loaded". Wise itself
-- is always loaded, but an unpressed slot containing it is not active.
test("AddonMagic: a slot is 'unloaded' until pressed, even if its addons are loaded", function()
    withSlots({ { "Wise" } }, function()
        assertEquals("unloaded", Wise:GetAddonMagicSlotState(1))
        assertFalse(Wise:IsAddonMagicSlotActive(1))
    end)
end)

test("AddonMagic: pressing a slot makes it active and enables its addons", function()
    withSlots({ { "Wise" } }, function()
        local enabled, _, reloaded = captureToggles(function()
            Wise:ExecuteAddonMagic(1)
        end)
        assertTrue(reloaded)
        assertTrue(contains(enabled, "Wise"))
        assertEquals("loaded", Wise:GetAddonMagicSlotState(1))
    end)
end)

test("AddonMagic: an uninstalled addon reports 'missing' and names it", function()
    withSlots({ { "ThisAddonDoesNotExist_Probe" } }, function()
        local state, missing = Wise:GetAddonMagicSlotState(1)
        assertEquals("missing", state)
        assertEquals(1, #missing)
        assertEquals("ThisAddonDoesNotExist_Probe", missing[1])
    end)
end)

test("AddonMagic: every missing addon is reported, not just the first", function()
    withSlots({ { "NoSuchAddon_A_Probe", "Wise", "NoSuchAddon_B_Probe" } }, function()
        local state, missing = Wise:GetAddonMagicSlotState(1)
        assertEquals("missing", state)
        assertEquals(2, #missing)
    end)
end)

test("AddonMagic: an unknown slot index does not error", function()
    assertEquals("empty", Wise:GetAddonMagicSlotState(9999))
end)

test("AddonMagic: pressing a slot with missing addons does not reload", function()
    withSlots({ { "ThisAddonDoesNotExist_Probe" } }, function()
        local _, _, reloaded = captureToggles(function()
            Wise:ExecuteAddonMagic(1)
        end)
        if reloaded then
            error("reloaded into a slot that can never load whole")
        end
        assertFalse(Wise:IsAddonMagicSlotActive(1))
    end)
end)

-- An addon can be uninstalled DURING an excursion. The slot is then active and
-- broken at once, and the unload press must still go through — otherwise it is
-- stuck highlighted until a manual reload.
test("AddonMagic: an active slot that goes missing can still be pressed off", function()
    withSlots({ { "Wise" } }, function()
        captureToggles(function() Wise:ExecuteAddonMagic(1) end)
        assertEquals("loaded", Wise:GetAddonMagicSlotState(1))

        -- Simulate one of its addons being uninstalled mid-excursion.
        WiseDB.addonMagicSlots[1].addons = { "Wise", "VanishedMidExcursion_Probe" }

        local state, missing = Wise:GetAddonMagicSlotState(1)
        assertEquals("loaded", state) -- still active, so still pressable
        assertNotNil(missing) -- but the breakage is still reported
        assertTrue(contains(missing, "VanishedMidExcursion_Probe"))

        local _, _, reloaded = captureToggles(function()
            Wise:ExecuteAddonMagic(1)
        end)
        assertTrue(reloaded)
        assertFalse(Wise:IsAddonMagicSlotActive(1))
    end)
end)

-- ── The enable / reload / un-check cycle ────────────────────────────────────
--
-- A press checks the union of every active slot, reloads, then un-checks what it
-- added. Checkbox state and loaded state are independent, so after the un-check
-- the client is already back to system state for the NEXT reload while the
-- excursion runs in this one. No detection, no clean-up pass, no second reload.

-- Simulates the reload boundary: the press already ran, this is the new session.
local function landReload()
    Wise.RestoreAddonMagic()
end

test("AddonMagic: a press queues an un-check for what it enabled", function()
    withSlots({ { "Wise" } }, function()
        local enabled = captureToggles(function() Wise:ExecuteAddonMagic(1) end)
        assertTrue(contains(enabled, "Wise"))
        -- Wise is already enabled at system level here, so it is NOT ours to
        -- un-check — that would erode the user's own addon list.
        if WiseDB.addonMagicUncheck then
            assertFalse(contains(WiseDB.addonMagicUncheck, "Wise"))
        end
    end)
end)

test("AddonMagic: an addon the user has NOT enabled is un-checked after loading", function()
    withSlots({ { "Wise" } }, function()
        -- Report it as not-enabled so it counts as one the press turned on.
        local realState = C_AddOns.GetAddOnEnableState
        C_AddOns.GetAddOnEnableState = function() return 0 end
        captureToggles(function() Wise:ExecuteAddonMagic(1) end)
        C_AddOns.GetAddOnEnableState = realState

        assertNotNil(WiseDB.addonMagicUncheck)
        assertTrue(contains(WiseDB.addonMagicUncheck, "Wise"))
    end)
end)

-- Enable-state must be read BEFORE EnableAddOn. On a real client, reading it
-- afterwards reports every addon as enabled, so nothing is ever recognised as
-- "ours", the un-check list comes out empty, and the addons stay checked — a
-- manual /reload would then keep loading them. The sim's EnableAddOn does not
-- flip the state a stub reads, so the order has to be asserted directly.
test("AddonMagic: enable state is sampled before the addon is enabled", function()
    withSlots({ { "Wise" } }, function()
        -- Stubs that behave like the real API: EnableAddOn flips the state that
        -- GetAddOnEnableState reports. A stub returning a constant cannot detect
        -- this ordering at all — it would report "not enabled" either way.
        local enabledYet = {}

        local realState, realEnable, realReload =
            C_AddOns.GetAddOnEnableState, C_AddOns.EnableAddOn, ReloadUI
        C_AddOns.EnableAddOn = function(n) enabledYet[n] = true end
        C_AddOns.GetAddOnEnableState = function(name)
            return enabledYet[name] and 2 or 0
        end
        ReloadUI = function() end

        Wise:ExecuteAddonMagic(1)

        C_AddOns.GetAddOnEnableState, C_AddOns.EnableAddOn, ReloadUI =
            realState, realEnable, realReload

        -- Sampled first, "Wise" reads as disabled and is queued. Sampled after
        -- EnableAddOn it reads as enabled, nothing is queued, and the addons stay
        -- checked — so a manual /reload would keep loading them.
        assertNotNil(WiseDB.addonMagicUncheck)
        assertTrue(contains(WiseDB.addonMagicUncheck, "Wise"))
    end)
end)

test("AddonMagic: the un-check runs and then clears", function()
    withSlots({ { "Wise" } }, function()
        WiseDB.addonMagicUncheck = { "Wise" }

        local disabled = {}
        local realDisable = C_AddOns.DisableAddOn
        C_AddOns.DisableAddOn = function(n) table.insert(disabled, n) end
        Wise.ApplyPendingAddonMagicUncheck()
        C_AddOns.DisableAddOn = realDisable

        assertTrue(contains(disabled, "Wise"))
        assertNil(WiseDB.addonMagicUncheck)
    end)
end)

-- Other addons inspect their dependencies' ENABLE state during their own
-- startup (TSM warns "AppHelper is installed but not enabled"). Wise loads
-- early, so un-checking during the restore pass — which runs on Wise's own
-- ADDON_LOADED — pulls that state away before they ever look.
test("AddonMagic: the restore pass does not un-check (too early for other addons)", function()
    withSlots({ { "Wise" } }, function()
        WiseDB.addonMagicUncheck = { "Wise" }

        local disabled = {}
        local realDisable = C_AddOns.DisableAddOn
        C_AddOns.DisableAddOn = function(n) table.insert(disabled, n) end
        landReload()
        C_AddOns.DisableAddOn = realDisable

        if contains(disabled, "Wise") then
            error("un-checked during ADDON_LOADED; dependents would see it disabled")
        end
        -- Still queued: the late pass is what actually performs it.
        assertNotNil(WiseDB.addonMagicUncheck)
    end)
end)

-- A press before the deferred un-check has run must flush it first. Otherwise
-- those addons sample as "already enabled", are never re-queued, and stay
-- checked permanently — a temporary load silently becoming a permanent one.
test("AddonMagic: a press flushes an un-check that has not run yet", function()
    withSlots({ { "Wise" } }, function()
        -- Pending from a previous press that has not reached its late pass.
        WiseDB.addonMagicUncheck = { "Wise" }

        local enabledYet = { Wise = true } -- still checked, as it would be
        local realState, realEnable, realDisable, realReload =
            C_AddOns.GetAddOnEnableState, C_AddOns.EnableAddOn,
            C_AddOns.DisableAddOn, ReloadUI
        C_AddOns.GetAddOnEnableState = function(n) return enabledYet[n] and 2 or 0 end
        C_AddOns.EnableAddOn = function(n) enabledYet[n] = true end
        C_AddOns.DisableAddOn = function(n) enabledYet[n] = nil end
        ReloadUI = function() end

        Wise:ExecuteAddonMagic(1)

        C_AddOns.GetAddOnEnableState, C_AddOns.EnableAddOn = realState, realEnable
        C_AddOns.DisableAddOn, ReloadUI = realDisable, realReload

        -- Flushed first, so it sampled as disabled and got re-queued.
        assertNotNil(WiseDB.addonMagicUncheck)
        assertTrue(contains(WiseDB.addonMagicUncheck, "Wise"))
    end)
end)

-- Wise must NEVER call ReloadUI outside a click: it is protected, so calling it
-- from an event handler raises ADDON_ACTION_BLOCKED. The whole point of
-- un-checking proactively is that no follow-up reload is ever needed.
test("AddonMagic: the login pass never reloads", function()
    withSlots({ { "Wise" } }, function()
        WiseDB.addonMagicUncheck = { "Wise" }

        local reloads, timers = 0, 0
        local realReload, realAfter = ReloadUI, C_Timer.After
        local realDisable = C_AddOns.DisableAddOn
        ReloadUI = function() reloads = reloads + 1 end
        C_Timer.After = function() timers = timers + 1 end
        C_AddOns.DisableAddOn = function() end

        landReload()

        ReloadUI, C_Timer.After = realReload, realAfter
        C_AddOns.DisableAddOn = realDisable

        assertEquals(0, reloads)
        assertEquals(0, timers)
    end)
end)

-- ── Stored state is what makes stacking work ────────────────────────────────
-- The press un-checks its addons, so the checkboxes say nothing about what is
-- active. The active SET is stored separately and survives the reload — without
-- it, a later press could not know to re-include the already-active slots.

test("AddonMagic: a press-reload restores the active set (highlight survives)", function()
    withSlots({ { "Wise" } }, function()
        local id = WiseDB.addonMagicSlots[1].id
        WiseDB.addonMagicPending = { id }
        Wise.addonMagicActive = {}

        landReload()

        assertTrue(Wise.addonMagicActive[id] == true)
        assertTrue(Wise:IsAddonMagicSlotActive(1))
        assertEquals("loaded", Wise:GetAddonMagicSlotState(1))
        assertNil(WiseDB.addonMagicPending)
    end)
end)

test("AddonMagic: a reload with no press leaves nothing active", function()
    withSlots({ { "Wise" } }, function()
        WiseDB.addonMagicPending = nil
        Wise.addonMagicActive = { [WiseDB.addonMagicSlots[1].id] = true }

        landReload()

        assertFalse(Wise:IsAddonMagicSlotActive(1))
        assertEquals("unloaded", Wise:GetAddonMagicSlotState(1))
    end)
end)

test("AddonMagic: pressing a second slot enables the UNION, not just the new one", function()
    withSlots({ { "Wise" }, { "TestFramework" } }, function()
        -- Slot 1 is already active and its addons have been un-checked, exactly
        -- as they would be after its own press-reload landed.
        Wise.addonMagicActive = { [WiseDB.addonMagicSlots[1].id] = true }

        local enabled = captureToggles(function() Wise:ExecuteAddonMagic(2) end)

        -- Both must be re-checked: a reload rebuilds the loaded set from the
        -- checkboxes, so omitting slot 1 here would drop it on the way through.
        assertTrue(contains(enabled, "Wise"))
        assertTrue(contains(enabled, "TestFramework"))
        assertTrue(Wise:IsAddonMagicSlotActive(1))
        assertTrue(Wise:IsAddonMagicSlotActive(2))
    end)
end)

test("AddonMagic: unloading one slot keeps an addon a still-active slot needs", function()
    -- Both slots claim "Wise"; only slot 1 claims "TestFramework".
    withSlots({ { "Wise", "TestFramework" }, { "Wise" } }, function()
        Wise.addonMagicActive = {
            [WiseDB.addonMagicSlots[1].id] = true,
            [WiseDB.addonMagicSlots[2].id] = true,
        }

        local enabled = captureToggles(function()
            Wise:ExecuteAddonMagic(1) -- press slot 1 off; slot 2 stays on
        end)

        -- The refcount falls out of rebuilding the union: Wise is still claimed
        -- by slot 2 so it stays checked, TestFramework is not so it drops.
        assertTrue(contains(enabled, "Wise"))
        assertFalse(contains(enabled, "TestFramework"))
        assertEquals("loaded", Wise:GetAddonMagicSlotState(2))
        assertEquals("unloaded", Wise:GetAddonMagicSlotState(1))
    end)
end)

test("AddonMagic: unloading the last claimant stops re-enabling the shared addon", function()
    withSlots({ { "Wise" }, { "Wise" } }, function()
        Wise.addonMagicActive = {
            [WiseDB.addonMagicSlots[1].id] = true,
            [WiseDB.addonMagicSlots[2].id] = true,
        }
        captureToggles(function() Wise:ExecuteAddonMagic(1) end)

        local enabled = captureToggles(function()
            Wise:ExecuteAddonMagic(2) -- last claimant off
        end)
        assertFalse(contains(enabled, "Wise"))
    end)
end)

test("AddonMagic: an unload press does not hand off a stale active set", function()
    withSlots({ { "Wise" } }, function()
        captureToggles(function() Wise:ExecuteAddonMagic(1) end)
        captureToggles(function() Wise:ExecuteAddonMagic(1) end) -- off again
        if WiseDB.addonMagicPending and #WiseDB.addonMagicPending > 0 then
            error("unload handed a stale active set to the next session")
        end
    end)
end)

-- An uninstalled addon must never be passed to EnableAddOn.
test("AddonMagic: the union skips uninstalled addons", function()
    withSlots({ { "Wise", "NoSuchAddon_Probe" } }, function()
        Wise.addonMagicActive = { [WiseDB.addonMagicSlots[1].id] = true }
        local enabled = captureToggles(function() Wise:ExecuteAddonMagic(1) end)
        assertFalse(contains(enabled, "NoSuchAddon_Probe"))
    end)
end)

-- ── Stable ids ──────────────────────────────────────────────────────────────

test("AddonMagic: deleting an earlier slot does not re-point the active set", function()
    withSlots({ { "Wise" }, { "TestFramework" } }, function()
        captureToggles(function() Wise:ExecuteAddonMagic(2) end)
        local activeID = WiseDB.addonMagicSlots[2].id
        assertTrue(Wise:IsAddonMagicSlotActive(2))

        -- Delete slot 1; the active slot shifts from index 2 to index 1.
        table.remove(WiseDB.addonMagicSlots, 1)

        assertEquals(activeID, WiseDB.addonMagicSlots[1].id)
        assertTrue(Wise:IsAddonMagicSlotActive(1))
        assertEquals("loaded", Wise:GetAddonMagicSlotState(1))
    end)
end)

test("AddonMagic: slot ids are unique", function()
    withSlots({ { "A" }, { "B" }, { "C" } }, function()
        local seen = {}
        for _, slot in ipairs(WiseDB.addonMagicSlots) do
            assertNotNil(slot.id)
            if seen[slot.id] then
                error("duplicate slot id: " .. tostring(slot.id))
            end
            seen[slot.id] = true
        end
    end)
end)
