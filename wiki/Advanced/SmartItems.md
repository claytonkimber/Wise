# Smart Items

Smart Items let you create interfaces that automatically populate with items from your bags based on a search term. Instead of dragging potions onto buttons manually, you set "potion" as the search term and Wise fills in whatever potions you currently have.

**Requires:** [Syndicator](https://www.curseforge.com/wow/addons/syndicator) or [Baganator](https://www.curseforge.com/wow/addons/baganator) addon installed and enabled.

---

## What Smart Items are good for

- **Consumables ring** — all your potions, flasks, and food in one ring
- **Hearthstone collection** — all your hearthstones and teleportation toys
- **Quest items** — all current quest items in one place
- **Reagents** — crafting materials you use frequently
- **Anything you carry that changes** — the interface updates as your inventory changes

---

## Creating a Smart Item interface

1. Open the Options Panel (`/wise`)
2. Create a new interface (name it something like "Potions", "Consumables", etc.)
3. Select the interface → **Properties** tab
4. Click **Action** on a slot to open the Action Picker
5. Go to the **Smart Items** tab
6. In the search field, enter your search term
7. Click **Set** (or press Enter)

Wise immediately queries Syndicator/Baganator for matching items in your bags and populates the interface with item buttons.

---

## Search syntax

The search term is passed to Syndicator/Baganator's search engine. Most natural terms work:

| Term | What it finds |
|---|---|
| `potion` | Any item with "potion" in the name |
| `flask` | Any flask |
| `hearthstone` | Hearthstone, Dalaran Hearthstone, Garrison Hearthstone, etc. |
| `food` | Food items |
| `consumable` | Any item in the Consumable category |
| `epic` | Epic-quality items |

The exact syntax depends on which addon you have installed (Syndicator vs. Baganator). Both support simple text search; Syndicator supports richer filtering by item type, quality, and expansion.

---

## How Smart Items update

- **On loot:** The interface refreshes automatically when you pick up a matching item.
- **On use:** The interface refreshes when you consume or lose a matching item.
- **Out of combat:** Smart Items **cannot update during combat** due to WoW's secure action restrictions. If you loot a potion during a boss fight, it won't appear on the interface until combat ends.
- **On login:** The interface rebuilds from your current bag contents when you log in.

---

## Multiple Smart Item slots

You can have multiple Smart Item search terms in the same interface — just add more slots and set different search terms on each. This lets you build a single "Consumables" ring that has separate sections for potions, flasks, and food from different search terms.

---

## Account-wide awareness

Because Wise uses Syndicator/Baganator, it has access to item data scanned from all your characters. However, Smart Item interfaces only populate buttons for items **currently in the bags of the character you are logged into**. Items on alts don't appear until you log into that character.

---

## Limitations

- Requires Syndicator or Baganator — Wise cannot search bags without one of these addons
- Cannot update in combat
- Very broad search terms (e.g., just `e`) may return too many results and affect performance
- Items not currently in your bags don't generate buttons, even if they're in your bank or on an alt
