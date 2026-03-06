# Macros

Wise allows you to create and use an unlimited number of custom macros, entirely separate from the built-in World of Warcraft macro system. This means you don't have to worry about the 18-character limit per account or character, and you don't need to copy macros between characters.

## Creating a Custom Macro

1.  Open the Wise Options Panel (`/wise`).
2.  Select the interface and slot you want to add a macro to in the **Properties** tab.
3.  Click the **Action** button on that slot to open the Action Picker.
4.  In the Action Picker, go to the **Macro** tab.
5.  Click the **New Macro** button at the bottom of the list.
6.  The **Macro Editor** will open on the right side of the Options Panel.

## Using the Macro Editor

The Macro Editor gives you a large text area to write your macro commands.

1.  **Name:** Give your macro a short name (this is mostly for your reference).
2.  **Icon:** Click the icon button to open the Icon Picker and choose an image for your macro.
3.  **Macro Text:** Enter your macro commands here.

### Syntax Highlighting

The Wise Macro Editor includes basic syntax highlighting:
*   **Blue Text:** Spell names that exist in the game.
*   **Red Text:** Typos or spell names that Wise cannot find.

## How Wise Macros Work

Wise handles custom macros slightly differently than the default game UI, allowing for more dynamic behavior:

*   **Dynamic Resolution:** Wise parses your macro text (using `SecureCmdOptionParse`) to figure out what spell or item it's trying to cast based on your current conditions (e.g., `[mod:shift] Spell A; Spell B`).
*   **Tooltips and Icons:** It prioritizes `#showtooltip` or `#show` directives. If found, it uses that specific spell/item for the icon and tooltip. If not found, it scans the macro for the first `/cast` or `/use` command to determine the appropriate icon and tooltip.
*   **Real-time Updates:** If your macro's conditions change (e.g., you change forms or targets), Wise's `conditionTicker` loop evaluates the custom macro and dynamically updates the button's icon, cooldown, and usability state in real-time.
*   **Nil Resolution:** If a custom macro resolves to `nil` (meaning its conditions are not met and it has nothing to cast), Wise explicitly resets the button icon to the default Question Mark texture and clears any stale cooldown data.
*   **Security:** Wise sanitizes inputs to `SecureCmdOptionParse` to prevent macro breakout errors, ensuring safe execution even in restricted environments. It also prevents the injection of newlines (`\n`) or carriage returns (`\r`) in conditional strings.
*   **Dynamic Conditionals Injection:** If you use an action type of `macro` that begins with a slash command (like `/click`), Wise dynamically injects conditionals into the string (e.g., converting `/click ActionButton1` into `/click [possessbar] ActionButton1`) to ensure proper evaluation within the secure state driver.

## Adding a Macro to a Slot

Once you've created and saved a macro in the Macro Editor, it will appear in the **Custom Macros** list in the Action Picker. Select it to assign it to the current slot.
