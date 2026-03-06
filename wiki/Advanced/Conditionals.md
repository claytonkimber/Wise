# Custom Conditionals

In addition to standard World of Warcraft macro conditionals (like `[combat]`, `[stealth]`, `[mod:shift]`), Wise provides several custom conditionals to give you even more control over when your interfaces and slots are visible or active.

## How to Use Custom Conditionals

You can use these conditionals anywhere you would normally enter a macro conditional string in Wise, such as:

*   **Visibility Settings:** In the "Custom Show" or "Custom Hide" fields in the Settings tab of an interface.
*   **Context-Sensitive Slots (States):** In the macro conditional field for a specific state on a slot (see [Context-Sensitive Slots](States.md)).

Simply type the conditional, enclosed in brackets, exactly as you would a standard macro conditional.

## Available Custom Conditionals

Wise registers these custom conditionals, which evaluate to true based on specific game states or UI interactions:

*   **`[undermouse]`**: Returns true if your mouse cursor is currently hovering over the interface or any of its buttons. This is particularly useful for creating menus that only appear when you mouse over a specific area or a parent button.
*   **`[bank]`**: Returns true when you have the Bank window open.
*   **`[guildbank]`**: Returns true when you have the Guild Bank window open.
*   **`[auction]`**: Returns true when you have the Auction House window open.
*   **`[mail]`**: Returns true when you have the Mailbox window open.
*   **`[mercenary]`**: Returns true if you currently have the Mercenary Contract buff (allowing you to queue for battlegrounds as the opposing faction).
*   **`[pvp]`**: Returns true if your PvP flag is enabled.
*   **`[warband]`**: Returns true if you are interacting with your Warband Bank.

## Built-in Conditionals

Wise also defines a few specific, reliable built-in conditionals that standard WoW macros might struggle with consistently:

*   **`[bonusbar:1/2/3/4/5]`**: Evaluates to true for "Any Bonus Bar". This encompasses forms like Moonkin and Skyriding, providing a more robust check than the generic `[bonusbar]` conditional in the modern client.
*   **`[extrabar]`**: Evaluates natively via the Extra Action Button state. Wise ensures UI updates reflect this without modifying the built-in conditional list.
*   **`[overridebar]`**: Evaluates natively for the Override Action Bar.
*   **`[possessbar]`**: Evaluates natively for the Possess Bar.

## Examples

*   **Show only at the bank:** `[bank]`
*   **Show only when hovering, unless in combat:** `[undermouse, nocombat]`
*   **Use an item only at the Auction House:** Add a state with the conditional `[auction]`
