# Smart Items (Requires Syndicator/Baganator)

Smart Items allow you to create dynamic interfaces that automatically populate with items from your bags based on search terms. This is incredibly useful for things like potions, flasks, hearthstones, or any category of items you want quick access to without manually dragging them to your bars.

**Important Note:** This feature requires you to have either the **Syndicator** or **Baganator** addon installed and enabled. Wise uses their search engines to find items across your account.

## How to Create a Smart Item Interface

1.  Open the Wise Options Panel (`/wise`).
2.  Create a new interface (e.g., "Potions Ring", "Hearthstones").
3.  Select the interface and go to the **Properties** tab.
4.  In the first slot, click the **Action** button to open the Action Picker.
5.  In the Action Picker, go to the **Smart Items** tab.
6.  You will see a text input box. Enter a search term here.

## Using Search Terms

The search term you enter determines what items will populate the interface. The syntax depends slightly on whether you are using Syndicator or Baganator, but generally, you can use:

*   **Simple text:** e.g., "potion", "flask", "hearthstone".
*   **Item type/subtype:** e.g., "Consumable", "Quest".
*   **Quality:** e.g., "epic", "rare".

## How Smart Items Update

Once you set a search term, Wise will automatically create buttons in that interface for every matching item currently in your bags.

*   **Auto-Update:** The interface refreshes automatically when you loot new items that match the search term, or when you use up the last of an item.
*   **Combat Restriction:** Due to Blizzard's security restrictions on action buttons, Wise **cannot** update Smart Item interfaces while you are in combat. If you loot a new potion during a boss fight, it won't appear on your ring until combat ends.
*   **Account-Wide:** Because it uses Syndicator/Baganator, it knows what items you have on all your characters. However, it will only populate the interface with items *currently in the bags of the character you are logged into*.

## Examples

*   **Search Term:** `potion`
    *   *Result:* Creates a ring (or list, box) containing every health, mana, and utility potion in your bags.
*   **Search Term:** `hearthstone`
    *   *Result:* Creates a ring with your regular Hearthstone, Garrison Hearthstone, Dalaran Hearthstone, and any teleportation toys that match the term.
