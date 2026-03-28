# Action Types

Every slot in a Wise interface needs an action — what happens when you press or click that button. The Action Picker (opened by clicking the **Action** button on any slot) lets you choose from the following types.

---

## Spell

Cast a spell from your spellbook. Enter the spell name or ID to find it.

Wise automatically handles **override spells** — if a talent replaces a spell with an upgraded version (e.g., Paladin's Wake of Ashes → Hammer of Light), the button updates its icon and casting target automatically. You don't need a separate state for the upgraded version.

Button display includes: cooldown overlay, cooldown countdown text, charge count, proc glow when the spell is active/ready.

---

## Item

Use an item from your inventory. Enter an item name or ID.

The button shows the item's cooldown and is grayed out if you don't have the item in your bags.

---

## Toy

Use a toy from your Toy Box. Enter the toy name or ID.

---

## Mount

Summon a mount from your Mount Journal. Enter a mount name or ID.

---

## Battle Pet

Summon a battle pet companion. Enter the pet name.

---

## Macro

Execute a custom Wise macro. These are separate from WoW's built-in macro system — you have unlimited macros and they don't count against the 18-macro-per-account limit.

Wise macros support full `/cast`, `/use`, `/run` syntax and are parsed in real time to keep the button icon and tooltip accurate. See [Macros](../Advanced/Macros.md) for full details.

---

## Equipment Set

Equip a saved gear set from WoW's Equipment Manager. Enter the set name exactly as it appears in your Equipment Manager.

The button is grayed out if the set doesn't exist for this character.

---

## Action Bar

Reference a slot on one of WoW's standard action bars (slots 1–180). The button mirrors whatever is on that action bar slot — icon, cooldown, usability. This is useful for exposing Blizzard action bar buttons in a Wise layout without duplicating assignments.

---

## UI Panel

Open a game panel directly. Supported panels:

- Character Info
- Spellbook / Abilities
- Talents
- Professions
- Collections
- Guild
- Group Finder
- Achievement
- Quest Log
- Adventure Guide
- Shop
- Housing
- Main Menu

---

## Zone Ability

Bind the current zone's special ability button (Garrison abilities, Covenant abilities, etc.). The button shows whatever zone ability is currently available and updates when you move between zones.

Use the `[zoneability]` conditional to only show this slot when a zone ability is actually available.

---

## Interface (Nesting)

Open, represent, or embed another Wise interface. This is how you build sub-menus and layered layouts.

When you pick an interface as the action type, you also choose a **nesting mode**:

- **Jump (Open)** — clicking opens the child interface next to the parent slot
- **Button** — the parent slot acts as if it _is_ the child interface (cycle, random, or priority sub-modes)
- **Embedded** — child actions are merged directly into the parent's slot list

See [Nested Interfaces](../Advanced/Nesting.md) for full details on each mode.

---

## Spec / Equipment Change

Trigger a simultaneous switch of spec + talent loadout + equipment set. See [Spec & Equipment Changer](../Advanced/SpecAndEquip.md).

---

## Addon Magic

Toggle an addon's enabled/disabled state and reload. Useful for turning on situational addons (e.g., a raid addon) without going into the addon list manually.

---

## Misc

A catch-all category covering:
- Shapeshift/stance forms directly
- Specific spec switches
- Mount Journal entries via macro
- Any other utility action not covered by the main categories

---

## Smart Items

Dynamically populate slots from your bags based on a search term. Requires the **Syndicator** or **Baganator** addon. See [Smart Items](../Advanced/SmartItems.md).

---

## Tips

- Any action type that resolves to "nothing" for the current character (spell not known, item not in bags, etc.) will either gray out the button or hide the slot entirely, depending on your **Hide Empty Slots** setting.
- Wise handles talent-override spell resolution for Spell actions automatically — you don't need states for baseline vs. talent-upgraded versions of the same spell.
- Use [States](../Advanced/States.md) when you need genuinely different actions on the same slot for different characters, specs, or conditions.
