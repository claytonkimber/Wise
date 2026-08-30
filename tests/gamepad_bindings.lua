-- wow-ui-sim tests for gamepad/controller keybind support (core/Bindings.lua).
--
-- Covers the pure string-handling pieces plus the capture helper's non-
-- gamepad wiring. Note: this build of wow-ui-sim doesn't recognize
-- "OnGamePadButtonDown" as a valid script handler on Button/Frame widgets
-- (see wow-ui-sim src/lua_api/frame/methods/text_attribute_event/events.rs,
-- is_widget_agnostic_script_handler/is_widget_specific_script_handler — real
-- WoW and ConsolePort both rely on this script existing on any frame, but the
-- simulator's allowlist doesn't model it). Wise:StartKeybindCapture wraps
-- that SetScript call in pcall for exactly this reason, so it silently no-ops
-- here instead of throwing; the keyboard/mouse coverage below exercises the
-- same FinishCapture code path the gamepad handler would call. The gamepad
-- line itself is exercised in-client per the manual QA checklist.
--
-- Run headless (no WoW client) from the simulator repo:
--   cd ../wow-ui-sim
--   ./target/release/wow-sim --no-saved-vars run-tests Wise

test("FormatKeybindText: face buttons keep numeric PAD form", function()
    assertEquals("Pad1", Wise:FormatKeybindText("PAD1"))
    assertEquals("Pad2", Wise:FormatKeybindText("PAD2"))
end)

test("FormatKeybindText: D-pad directions get short labels", function()
    assertEquals("D+U", Wise:FormatKeybindText("PADDUP"))
    assertEquals("D+D", Wise:FormatKeybindText("PADDDOWN"))
    assertEquals("D+L", Wise:FormatKeybindText("PADDLEFT"))
    assertEquals("D+R", Wise:FormatKeybindText("PADDRIGHT"))
end)

test("FormatKeybindText: shoulders, triggers, sticks get short labels", function()
    assertEquals("LB", Wise:FormatKeybindText("PADLSHOULDER"))
    assertEquals("RB", Wise:FormatKeybindText("PADRSHOULDER"))
    assertEquals("LT", Wise:FormatKeybindText("PADLTRIGGER"))
    assertEquals("RT", Wise:FormatKeybindText("PADRTRIGGER"))
    assertEquals("L3", Wise:FormatKeybindText("PADLSTICK"))
    assertEquals("R3", Wise:FormatKeybindText("PADRSTICK"))
end)

test("FormatKeybindText: gamepad tokens survive modifier prefixes", function()
    -- Modifier abbreviation (rule 3) runs before the PAD* rules (rule 4), so a
    -- modified gamepad binding should still come out readable.
    assertEquals("S-Pad1", Wise:FormatKeybindText("SHIFT-PAD1"))
end)

test("GetGamepadIcon: nil key returns nil", function()
    local icon, isAtlas = Wise:GetGamepadIcon(nil)
    assertNil(icon)
    assertNil(isAtlas)
end)

test("GetGamepadIcon: non-PAD key returns nil even if ConsolePort flag is set", function()
    local saved = Wise.HasConsolePort
    Wise.HasConsolePort = true
    local icon = Wise:GetGamepadIcon("SHIFT-F1")
    Wise.HasConsolePort = saved
    assertNil(icon)
end)

test("GetGamepadIcon: PAD key returns nil when ConsolePort is not loaded", function()
    local saved = Wise.HasConsolePort
    Wise.HasConsolePort = false
    local icon = Wise:GetGamepadIcon("PAD1")
    Wise.HasConsolePort = saved
    assertNil(icon)
end)

test("RegisterConsolePortFrame: no-op and no error when ConsolePort isn't loaded", function()
    local widget = CreateFrame("Frame", "WiseSimConsolePortFrameTest", UIParent)
    local ok = pcall(function()
        Wise:RegisterConsolePortFrame(widget)
    end)
    assertTrue(ok)
end)

test("StartKeybindCapture: wires keyboard/mouse capture and binds on keypress", function()
    assertType("function", Wise.StartKeybindCapture)

    local widget = CreateFrame("Button", "WiseSimGamepadCaptureTestBtn", UIParent, "GameMenuButtonTemplate")
    local bound = nil

    Wise:StartKeybindCapture(widget, {
        getCurrentText = function()
            return "None"
        end,
        allowMouseWheel = false,
        group = nil,
        slotIdx = nil,
        isSlotBinding = false,
        onBound = function(fullKey)
            bound = fullKey
        end,
    })

    assertNotNil(widget:GetScript("OnKeyDown"))
    assertNotNil(widget:GetScript("OnMouseDown"))

    -- Simulate a raw keydown the way Blizzard's frame script would.
    local handler = widget:GetScript("OnKeyDown")
    handler(widget, "F1")

    assertEquals("F1", bound)
    -- Capture should be torn down after a successful bind.
    assertNil(widget:GetScript("OnKeyDown"))
end)

test("StartKeybindCapture: ESCAPE cancels without binding", function()
    local widget = CreateFrame("Button", "WiseSimGamepadCaptureCancelTestBtn", UIParent, "GameMenuButtonTemplate")
    local bound = nil
    local cancelled = false

    Wise:StartKeybindCapture(widget, {
        getCurrentText = function()
            return "None"
        end,
        allowMouseWheel = false,
        group = nil,
        slotIdx = nil,
        isSlotBinding = false,
        onCancelled = function()
            cancelled = true
        end,
        onBound = function(fullKey)
            bound = fullKey
        end,
    })

    local handler = widget:GetScript("OnKeyDown")
    handler(widget, "ESCAPE")

    assertNil(bound)
    assertTrue(cancelled)
    assertNil(widget:GetScript("OnKeyDown"))
end)
