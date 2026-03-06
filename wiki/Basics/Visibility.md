# Visibility Settings

Wise gives you powerful control over when and how your interfaces appear on your screen. You can set up interfaces to always show, only show when you hold a key down, or show/hide based on specific game conditions (like being in combat or mounted).

## How to Configure Visibility
1. Open the Wise Options Panel (`/wise`).
2. Select an interface from the list on the left.
3. Click the **Settings** tab.
4. Scroll down to the **Visibility** section.

## Basic Visibility Options
The "Easy Mode" visibility checkboxes allow you to quickly set common conditions without writing Lua or macro conditionals.

*   **In Combat:** Show the interface when you are in combat.
*   **Out of Combat:** Show the interface when you are out of combat.
*   **Hold to Show:** If enabled, the interface will only be visible while you hold down its assigned Keybind. When you release the key, the interface hides and the action under your mouse is executed (if applicable).
*   **Toggle on Press:** If enabled, pressing the assigned Keybind will toggle the interface's visibility on or off.

## Advanced Visibility Options
For more complex scenarios, you can use macro conditionals. This allows you to show or hide interfaces based on things like your current form, if you are flying, or if you have a specific target.

*   **Show Conditionals:** The interface will be shown if any of these macro conditionals are met. (e.g., `[combat]`, `[mounted]`, `[form:1]`)
*   **Hide Conditionals:** The interface will be hidden if any of these macro conditionals are met, overriding the "Show" settings.

If an interface does not have any visibility settings configured (both Custom Show and Custom Hide are empty, and Hold/Toggle are unchecked), it is considered "Disabled" and will not be loaded or shown.

See [Custom Conditionals](../Advanced/Conditionals.md) for more details on writing advanced macro conditionals.
