# Spec & Equipment Changer

The Spec & Equipment Changer is a Wiser Interface that lets you switch your specialization, talent loadout, and equipment set all at once with a single button press.

This is especially useful for:
- Quickly swapping between your Healer and DPS sets at the start of a raid
- Switching from a Mythic+ setup to open-world farming
- Toggling between two talent builds without navigating the Talents panel

---

## How it works

Each slot in the Spec & Equipment Changer represents one "loadout preset" — a combination of:

- **Spec** — which specialization to switch to (optional)
- **Talent Loadout** — the saved talent configuration name to activate (optional)
- **Equipment Set** — the gear set from WoW's Equipment Manager to equip (optional)

You can configure any combination. If you only want to swap gear without changing spec, just set the Equipment Set and leave the others blank.

---

## Setting up the Spec & Equipment Changer

1. Open the Options Panel (`/wise`)
2. Find **Spec & Equipment Changer** in the left sidebar (under Wiser Interfaces)
3. The interface already has pre-created slots. Click a slot to configure it.
4. In the slot's properties, set:
   - **Spec**: choose a specialization from the dropdown, or leave blank to keep your current spec
   - **Talent Loadout**: type the exact name of your saved talent loadout, or leave blank
   - **Equipment Set**: type the exact name of your equipment set from WoW's Equipment Manager, or leave blank
5. Repeat for each preset you want

---

## Execution order

Wise handles swaps in this order to avoid errors:

1. **Equipment swap first** — gear changes happen before the spec/talent change
2. **Spec change** — specialization switches asynchronously via Blizzard's API
3. **Talent loadout** — activated after the spec change completes

This order matters because WoW's talent and equipment systems interact — equipping the wrong gear before a spec swap can cause issues. Wise handles it safely.

---

## Appearance and layout

The Spec & Equipment Changer uses the same layout options as any other interface:
- Change the layout type in the Settings tab (Circle, Box, List, etc.)
- Set visibility rules (e.g., always show, or only show out of combat)
- Assign a keybind to show/hide it

Slot icons display the spec icon for the configured specialization, or a generic gear icon if no spec is set.

---

## Tips

- Give each slot a descriptive name (e.g., "Raid Heal", "M+ Tank", "World Quests") so you can tell them apart at a glance.
- Use **List** layout to see names alongside icons, which makes it easier to identify presets quickly.
- Set visibility to **Out of Combat** to prevent accidental swaps mid-fight.
- Talent loadout names are case-sensitive and must match exactly what you saved in the Talents panel.
- Equipment set names must match exactly what you named them in WoW's Equipment Manager (`/equipmentsets`).
