-- wow-ui-sim tests for the keybind "already bound — use anyway?" flow
-- (Wise:StartKeybindCapture in core/Bindings.lua, Wise:CheckBindingConflict and
-- the WISE_CONFIRM_BINDING_OVERWRITE popup in modules/Properties.lua).
--
-- Regression (reported 2026-09-26): binding the slot toolbar's Direct Keybind to
-- a key that was already taken showed the conflict popup, but accepting it only
-- CLEARED the old owner — the new key was never saved, so it took a second bind
-- to stick. The popup re-implemented the save from `group`/`slotIdx`, which the
-- toolbar passes as nil. It now calls the capture's own onBound instead.
--
-- Drives the real toolbar button: OnClick starts capture, OnKeyDown delivers the
-- key, and StaticPopup_Show is intercepted to grab the popup's data so
-- OnAccept/OnCancel can be invoked directly (the sim does not click popups).

local GROUP = "KeybindConflictTest"

local function setup()
	Wise:CreateGroup(GROUP, "line")
	local group = WiseDB.groups[GROUP]
	group.actions = {
		[1] = { { type = "spell", value = 1 } },
		[2] = { { type = "spell", value = 2 } },
	}
	Wise.selectedGroup, Wise.selectedSlot = GROUP, 1
	if not Wise.OptionsFrame then
		Wise:CreateOptionsFrame()
	end
	return group, Wise:CreateSlotToolbar().bindBtn
end

-- Press `key` on the toolbar bind button. Returns the overwrite popup's data
-- table if a conflict was raised, nil otherwise.
local function pressKey(btn, key)
	local captured
	local original = StaticPopup_Show
	StaticPopup_Show = function(which, text1, text2, data)
		if which == "WISE_CONFIRM_BINDING_OVERWRITE" then
			captured = data
			return
		end
		return original(which, text1, text2, data)
	end
	btn:GetScript("OnClick")(btn, "LeftButton")
	btn:GetScript("OnKeyDown")(btn, key)
	StaticPopup_Show = original
	return captured
end

local function popup()
	return StaticPopupDialogs["WISE_CONFIRM_BINDING_OVERWRITE"]
end

local function teardown()
	WiseDB.groups[GROUP] = nil
	Wise.selectedGroup, Wise.selectedSlot = nil, nil
end

test("KeybindConflict: accepting a key taken from a WoW action saves it first time", function()
	local group, btn = setup()
	SetBinding("F9", "TOGGLEBACKPACK")

	local data = pressKey(btn, "F9")
	assertNotNil(data, "a conflict popup should be raised")
	assertNil(group.actions[1].keybind, "nothing is saved until the popup is accepted")

	popup().OnAccept(nil, data)
	assertEquals("F9", group.actions[1].keybind)
	assertEquals("", GetBindingAction("F9") or "", "the WoW binding is released")
	teardown()
end)

test("KeybindConflict: re-pressing the slot's own key raises no popup", function()
	local group, btn = setup()
	group.actions[1].keybind = "F8"

	assertNil(pressKey(btn, "F8"), "a slot's own key is not a conflict")
	assertEquals("F8", group.actions[1].keybind)
	teardown()
end)

test("KeybindConflict: accepting a key from another slot moves it", function()
	local group, btn = setup()
	group.actions[1].keybind = "F7"
	group.actions[2].keybind = "F10"

	local data = pressKey(btn, "F10")
	assertNotNil(data)
	popup().OnAccept(nil, data)
	assertEquals("F10", group.actions[1].keybind)
	assertNil(group.actions[2].keybind)
	teardown()
end)

test("KeybindConflict: cancelling keeps the current key and its label", function()
	local group, btn = setup()
	group.actions[1].keybind = "F7"
	SetBinding("F11", "TOGGLEBACKPACK")

	local data = pressKey(btn, "F11")
	assertNotNil(data)
	popup().OnCancel(nil, data)
	assertEquals("F7", group.actions[1].keybind)
	assertEquals("F7", btn:GetText())
	assertEquals("TOGGLEBACKPACK", GetBindingAction("F11"))
	SetBinding("F11", nil)
	teardown()
end)
