# Keybinds

Wise supports two levels of keybinding: **interface-level** (show/hide or trigger the whole interface) and **slot-level** (fire a specific action directly).

---

## Interface-level keybinds

An interface keybind shows or hides the entire interface. This is the primary way to use rings and menus — you hold a key, the ring appears under your mouse, you click an action, and the ring hides.

**To set an interface keybind:**
1. Select your interface in the sidebar
2. Click the **Settings** tab
3. In the **Keybind** section, click the keybind input box
4. Press the key combination you want
5. The keybind is saved immediately

### Trigger modes

The trigger mode controls how the keybind interacts with visibility:

| Mode | Behavior |
|---|---|
| **Hold** | Interface is visible while the key is held down. When released, the action under your cursor fires (if any). Best for radial menus and hover-select workflows. |
| **Toggle** | First press shows the interface; second press hides it. Good for persistent bars you want to pin. |
| **Press** | Interface appears on key-down. You must manually close it by pressing again or moving away. |
| **Release** | The assigned interface action fires on key-up rather than key-down. Useful for precision timing. |
| **Release (Mouseover)** | Like Release, but only fires if your mouse is over a button at release time. Prevents accidental casts. |
| **Release + Repeat** | Fires on release, but also begins auto-repeating the action if the key is held. |

The **Hold** mode is the most popular for rings and circles — it feels like OPie's hold-ring workflow.

### Conflict detection

If the key you're assigning is already bound to something else (a WoW default binding or another addon), Wise will warn you. You can proceed or choose a different key.

---

## Slot-level keybinds

Individual slots within an interface can have their own direct keybinds. Pressing the key fires that slot's action immediately, regardless of whether the interface is visible.

**To set a slot keybind:**
1. Select your interface and go to the **Properties** tab
2. Click the **Keybind** button on the slot row
3. Press the key combination

Slot keybinds are especially useful for:
- **Button interfaces** — a single action you want to fire with a specific key
- **Line/Box interfaces** — binding individual slots like a traditional action bar
- **Frequently-used actions in rings** — bind the top 1–2 most-used actions for fast access

### Keybind display on buttons

To show keybind labels on your interface buttons:
- **Global setting:** Settings tab → uncheck/check **Show Keybinds** (also in the global Settings menu)
- **Per-interface setting:** Settings tab → Keybind section → **Show Keybind on Button** toggle

You can adjust the keybind text size and position (Bottom, Top, etc.) in the global Settings panel.

---

## Modifier keys

WoW supports modifier combinations: `Shift+key`, `Ctrl+key`, `Alt+key`, and combinations like `Ctrl+Shift+key`.

You can also use modifier conditionals in slot states to make one button do different things depending on which modifier you hold. See [Conditionals Reference](../Advanced/Conditionals.md) for `[mod:shift]`, `[mod:ctrl]`, `[mod:alt]`.

### Wise claims modifier variants of every keybind

When you bind a slot or interface to an unmodified key (e.g. `-`, `=`, `F8`), Wise **also claims `Shift-`, `Ctrl-`, and `Alt-` versions of that same key**. The press is routed to the same slot regardless of which modifier (if any) you hold, so your `[mod:shift]` / `[mod:ctrl]` / `[mod:alt]` conditionals can decide what actually happens.

**Why:** WoW's binding system swallows modified keypresses if a global binding exists for that combo — even one set to `NONE`. Without this claim, an entry like `bind SHIFT-- NONE` in your bindings cache would silently eat `Shift+-` before your slot ever saw it. Mirroring the modifier variants guarantees the slot fires and your conditionals get to evaluate.

**Implications:**
- Don't bind `Shift+X` in WoW's keybinding UI to anything else if `X` is also a Wise slot keybind — Wise will override it while the addon is loaded. Pick a different key for the WoW binding instead.
- If you *want* `Shift+X` and plain `X` to do different things on the same slot, use `[mod:shift]` inside that slot's macro or conditions, not separate keybinds.
- A keybind that's already modifier-prefixed (e.g. you bound the slot to `Shift-3` directly) is left alone — Wise won't further claim `Ctrl-Shift-3` etc.

---

## Mouse buttons

Wise supports binding middle-click (Button3), Button4, and Button5 on mouse-equipped slots. These are routed through a secure dispatcher system that intercepts the mouse input and directs it to the correct action button without taint.

---

## Tips

- Use **Hold** mode with a non-modifier key (e.g., `F`, `G`, `Z`) for ring interfaces you open with one hand while clicking with the other.
- Use **Toggle** mode for utility bars you want to pin open while managing inventory, professions, etc.
- Interface-level keybinds and slot-level keybinds can coexist — a ring can have a hold keybind for the whole ring AND individual slot bindings for the 2–3 most important actions.
