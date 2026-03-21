# Setting Up Your First Interface

This guide walks you through creating an interface, adding actions, configuring its appearance, and getting it on your screen.

## Opening the Options Panel

Type `/wise` in chat, or click the **Wise** button on your minimap. The Options Panel is your central hub for everything.

## The Options Panel layout

- **Left sidebar** — list of all your interfaces (yours + built-in Wiser interfaces)
- **Middle panel** — slots/actions for the selected interface
- **Right panel** — properties for the selected slot or state
- **Top tabs** — Editor · Settings · Conditionals · Info

## Creating an interface

1. At the top of the left sidebar, type a name in the input box (e.g. "Cooldowns").
2. Pick a layout type from the dropdown:
   - **Circle** — radial ring of buttons, great for hover menus
   - **Box** — grid (configure rows and columns in Settings)
   - **Line** — single horizontal or vertical bar
   - **List** — vertical text list with clickable labels
   - **Button** — a single standalone button
3. Click **+** to create it.

Your new interface appears in the sidebar. Click it to open its configuration.

## Adding actions to slots

1. In the middle panel, click **+ Add Slot** (or the **+** at the bottom of the slot list).
2. Click the **Action** button on the new slot to open the Action Picker.
3. Search or browse by category — Spells, Items, Mounts, Macros, Equipment Sets, Interfaces, and more.
4. Select an action to assign it to the slot.

The slot icon updates immediately. Repeat for each slot you want.

**Tip:** You can drag spells or items directly from your spellbook or bags onto any slot in the Options Panel. Dragging onto an empty slot sets its action; dragging onto the **+** button on an existing slot adds it as a new [state](../Advanced/States.md).

## Reordering slots

Drag the grip handle (the dotted area) on the left side of any slot row up or down to reorder.

## Configuring appearance

Select your interface and click the **Settings** tab. Key options:

| Setting | What it controls |
|---|---|
| Icon Size | Size of action icons in pixels |
| Padding | Space between buttons |
| Columns / Radius | Grid columns (Box) or ring radius (Circle) |
| Font / Text Size | Label text below icons |
| Show Keybinds | Overlay hotkey text on buttons |
| Hide Empty Slots | Don't show unfilled or condition-failed slots |
| Show Countdown Text | Cooldown timer numbers on buttons |
| Show Charge Text | Charge count display position |

## Enabling the interface

An interface only appears in-game when it has at least one **Visibility** setting configured. In the Settings tab, scroll to the **Visibility** section and choose one of:

- **Always Show** — visible whenever the interface is loaded
- **In Combat / Out of Combat** — quick checkboxes
- **Hold to Show** — appears only while holding the assigned keybind
- **Custom Show conditionals** — macro-style conditions (e.g. `[combat]`)

See [Visibility Settings](Visibility.md) for the full reference.

## Assigning a keybind

You can assign a hotkey to the whole interface (to show/hide or trigger it) or to individual slots.

**Interface-level keybind:** Settings tab → Keybind section → click the keybind box and press a key.

**Slot-level keybind:** In the Properties tab, click the **Keybind** button on a slot row and press a key.

See [Keybinds](Keybinds.md) for trigger modes and advanced options.

## Positioning the interface

Use **Edit Mode** (button in the top-right of the Options Panel) to drag interfaces around your screen visually, or use the X/Y nudgers in the Settings tab for pixel-perfect placement.

See [Moving Interfaces](EditMode.md).

## Quick-start example: a combat cooldown ring

1. Create interface "Combat CDs", type **Circle**
2. Add slots: your major offensive cooldowns as Spell actions
3. Settings tab → Visibility → check **In Combat**
4. Settings tab → Keybind → bind to a key with trigger mode **Hold**
5. Exit Edit Mode after positioning it on screen

Now the ring only appears when you're in combat, and holding your key shows the full ring under your mouse for quick clicking.
