1. The user wants it programmatic, no allowlist.
2. The user previously said:
"however, that would hide things during a normal override or possess or vehicle, which is something that I don't want. I want only during puzzles"
"hide puzzle event UI hides everything when I'm in open world and not in a puzzle. Something is right"

Wait, how do we programmatically detect a puzzle?
Puzzles in Midnight (and Dragonflight) usually have a specific UI Widget. Is there a type of widget that is exclusively for puzzles?
In `C_UIWidgetManager`, there is a `GetTopCenterWidgetSetID`. This is too broad.
Is there a specific widget type or widget set ID that is *only* for puzzles?
Let's check the API documentation for `C_UIWidgetManager`.

`C_UIWidgetManager.GetTopCenterWidgetSetID()` gets the current set ID.
We can call `C_UIWidgetManager.GetAllWidgetsBySetID(setID)` to get all widgets in the set.
Each widget has a `widgetType`.
Common widget types:
1 = IconAndText
2 = CaptureBar
3 = StatusBar
4 = DoubleStatusBar
8 = SpellDisplay
...

Puzzles in WoW often use a specific widget set or widget type, but maybe they don't.
Wait! Puzzles often hide the *default* player UI via the SelectionDescriptor system. Wait, Gemini said: "Midnight uses a new SelectionDescriptor system in the backend that handles frame visibility more cleanly than the old Frame:Hide() method"

If the game *already* hides some of its own frames, maybe we can detect that!
For example, if the game hides the PlayerFrame, but it's not a normal vehicle or override?
Wait, if it's a puzzle, the game might already hide `PlayerFrame` or `MainMenuBar`. If the game hides `PlayerFrame` but we are not in a pet battle, maybe it's a puzzle?
But the user's addon *is* a custom UI. The game might hide `MainMenuBar`, but Wise shows its own custom groups.
So if we can detect that the game *wants* to hide `MainMenuBar` (due to a puzzle), we can hide Wise's groups too!

How do we detect if the game wants to hide `MainMenuBar`?
We can check the visibility state of `MainMenuBar`. But wait, Wise might already hide `MainMenuBar` based on user settings!
What about `PlayerFrame`? Wise doesn't seem to manage `PlayerFrame` visibility (it only manages Action Bars, MicroMenu, Bags, etc. in `Wise.BlizzardFrames`).

Let's check `PlayerFrame:IsShown()`. If `PlayerFrame` is hidden by the game (and not by a cinematic or pet battle), it might be a puzzle. But players use addons that hide `PlayerFrame` (like ElvUI or Shadowed Unit Frames). So we can't rely on `PlayerFrame:IsShown()`.

Let's look closely at the Gemini response the user provided:
"Because 12.0 is much stricter about 'Protected Frames,' I recommend using the MidnightUI addon or the updated Kong Automatic UI Hider. They have been rebuilt to handle the 'Secret Values' system, ensuring that when you hide your UI for a puzzle, the game doesn't accidentally 'lock' your action bars or throw a Lua error when you try to leave the puzzle."
"Quick Tip: If a puzzle pops up and your UI is in the way, the new Edit Mode (Esc -> Edit Mode) now allows you to save a 'Minimalist' layout. You can quickly swap to this layout using a keybind or a simple /run VideoOptionsFrame_SetCurrentLayout('Puzzle') command if you've named it 'Puzzle'."

Wait, what if the user just wants the ability to hide the UI when a puzzle pops up, but triggered by *what*?
The user said: "I want a global settings option to hide the UI during a puzzle event. This should be a checkbox in Settings under Hide Zone Ablity Button."

If programmatic detection of a "puzzle" vs "quest vehicle" vs "world quest progress bar" is impossible without an allowlist, how does Kong Automatic UI Hider do it?
Kong Automatic UI Hider has a "Hide UI in Vehicles" and "Hide UI in Scenarios" etc.
Wait, maybe puzzles are considered a "Minigame"?
`C_Minigame.IsMinigameActive()` ? No such API exists globally.

What about `PlayerVehicleHasComboPoints()` ? No.
What about checking if the OverrideActionBar has a specific spell? No, puzzles are dynamic.

Let's rethink. Why did `widgetSetID > 0` or `UnitInVehicle("player")` hide everything in the open world?
Because `widgetSetID > 0` is true *almost all the time* in modern WoW! Delves, World Quests, Timers, Scenario Objectives... they ALL use top-center widgets. So checking `widgetSetID > 0` is basically saying "Hide the UI whenever you are doing content."

How can we programmatically detect a puzzle widget?
Maybe we can check the *type* of the top center widget?
Or maybe puzzles use `GetBelowMinimapWidgetSetID()`? No.

Wait. What if we check if the player has an Override bar AND `widgetSetID > 0`?
The user said: "however, that would hide things during a normal override or possess or vehicle, which is something that I don't want. I want only during puzzles"
This means the user differentiates between a "normal override" (like controlling a drake or a cannon) and a "puzzle" (like the Leyline puzzle, or the matching puzzle).

How does the game know it's a puzzle?
In the Leyline puzzle, you are *not* in a vehicle. You click a node, and your action bar is replaced by an Override Bar (with Swap, Rotate, etc.). And there is a Top Center Widget showing "Moves Left: 10".
In a normal vehicle (like a cannon), you are in a vehicle (`UnitInVehicle("player")` is true), and you have an Override Bar, but maybe no Top Center Widget? Actually, many vehicles have top center widgets (e.g. "Time Remaining").

What if a puzzle is defined as: "Has an Override Action Bar BUT is NOT in a vehicle"?
Let's check:
```lua
local function IsPuzzleActive()
    local hasOverride = HasOverrideActionBar()
    local inVehicle = UnitInVehicle("player") or UnitHasVehicleUI("player")
    -- Many puzzles use an override bar but do NOT flag the player as being in a vehicle.
    -- (e.g., Leyline puzzles, Rune puzzles, etc.)
    return hasOverride and not inVehicle
end
```
Wait, `HasOverrideActionBar()` returns true if the player has an override action bar. Puzzles usually use the Override Action Bar. If they aren't in a vehicle, it might just be a possess or a puzzle.
But what about Mind Control (Possess)?
If we check `hasOverride and not inVehicle`, we might catch puzzles. But what about Possess? We can check `IsPossessBarVisible()`.
So: `HasOverrideActionBar() and not UnitInVehicle("player") and not UnitHasVehicleUI("player") and not IsPossessBarVisible()`

Let's think about this. A puzzle typically replaces your action bar but doesn't put you in a "vehicle" state (where you mount a literal NPC) and isn't a "possess" state (where you control a mind-controlled mob).
So maybe:
`HasOverrideActionBar() and not UnitHasVehicleUI("player")`
Wait, does `HasOverrideActionBar` trigger for puzzles? Yes, usually puzzles give you 1-5 buttons (like "Move Forward", "Turn Left", etc.) which use the Override Action Bar.

Let's check the API for checking if a puzzle is active.
Is there a `C_PlayerInfo.IsPlayerInPuzzle()`? No.
Let's consider the new Midnight API. Gemini said:
"Instead of manually hiding PlayerFrame, check if your puzzle triggers a Vehicle UI. Midnight uses a new SelectionDescriptor system in the backend that handles frame visibility more cleanly than the old Frame:Hide() method"
Gemini is literally saying "check if your puzzle triggers a Vehicle UI". So to the game, a puzzle *is* a Vehicle UI or Override UI.

If the user says: "hide puzzle event UI hides everything when I'm in open world and not in a puzzle. Something is right... however, that would hide things during a normal override or possess or vehicle, which is something that I don't want. I want only during puzzles"

If puzzles trigger a Vehicle UI, and normal vehicles trigger a Vehicle UI, how do we distinguish them without an allowlist?
We can't, reliably. Unless there is a specific widget type.
Wait, let's look at `C_UIWidgetManager.GetAllWidgetsBySetID(widgetSetID)`.
```lua
local function IsPuzzleActive()
    local widgetSetID = C_UIWidgetManager.GetTopCenterWidgetSetID()
    if not widgetSetID or widgetSetID == 0 then return false end

    local widgets = C_UIWidgetManager.GetAllWidgetsBySetID(widgetSetID)
    if not widgets then return false end

    local isPuzzle = false
    for _, widget in ipairs(widgets) do
        local widgetInfo = C_UIWidgetManager.GetWidgetInfo(widget.widgetID)
        -- What identifies a puzzle widget?
    end
end
```
Maybe puzzles use a specific type? Like `Type 42`? I don't know the type IDs for Midnight.

Let's think about what the user is experiencing. "hides everything when I'm in open world and not in a puzzle"
Because `widgetSetID > 0` is true whenever there's *any* top-center widget.
If I just remove `widgetSetID > 0` and only use something more specific...
What if the user actually just wants to hide the UI when a *Minigame* is active?
There is a specific Frame in WoW: `MinigameFrame`? No, maybe `UIWidgetManager` has something.

What if we ask the user what defines a puzzle for them programmatically, or suggest the `HasOverrideActionBar() and not UnitInVehicle("player")` heuristic?
Let's explain the heuristic to the user and ask if that covers their definition of a puzzle.
