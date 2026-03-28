# Macros

Wise has its own macro system, completely separate from WoW's built-in macros. You get unlimited macros that don't count against WoW's 18-per-account / 18-per-character cap, and they're stored account-wide so they work on every character.

---

## Creating a macro

1. Open the Options Panel (`/wise`)
2. Select your interface → **Properties** tab
3. On a slot, click **Action** to open the Action Picker
4. Go to the **Macro** tab
5. Click **New Macro**
6. The Macro Editor opens on the right side of the Options Panel

---

## The Macro Editor

| Field | Description |
|---|---|
| **Name** | A label for your reference (shown in the macro list) |
| **Icon** | Click to open the Icon Picker and choose a custom icon |
| **Macro Text** | The full macro body — same syntax as WoW macros |

### Syntax highlighting

The editor highlights macro text in real time:
- **Blue** — spell or item name recognized by Wise
- **Red** — unrecognized name (possible typo)

This helps you catch misspelled spell names before you commit the macro.

---

## How Wise macros work

### Dynamic icon and tooltip resolution

Wise parses your macro text to determine the correct icon and tooltip for the button. Resolution priority:

1. `#showtooltip SpellOrItem` — uses that spell/item
2. `#show SpellOrItem` — uses that spell/item for the icon (no tooltip text)
3. First `/cast` or `/use` command found — uses the first actionable line
4. Nothing resolvable → shows the default question-mark icon

If your macro uses conditionals (`/cast [mod:shift] Spell A; Spell B`), Wise evaluates the conditionals in real time and updates the icon to match whatever would actually fire given your current game state.

### Real-time updates

Wise's background ticker (every 0.2s) re-evaluates your macro's conditionals continuously. This means:
- The icon changes when you shift-hold, go in/out of combat, change forms, etc.
- Cooldown overlays and usability state update live
- If the macro resolves to nothing (`nil`), the button resets to the question-mark icon and clears cooldown data

### Security

Wise sanitizes macro inputs before passing them to `SecureCmdOptionParse` to prevent macro breakout errors. Newlines and carriage returns are stripped from conditional strings. This means Wise macros are safe to use in restricted (secure) contexts.

### Conditional injection

For macros that begin with `/click` (e.g., `/click ActionButton1`), Wise automatically injects conditionals to ensure proper behavior in different bar states:

```
/click ActionButton1
→ becomes →
/click [possessbar] ActionButton1
```

This happens transparently; you don't need to do anything special.

---

## Writing macros

Wise macros support the full WoW macro language:

```
/cast [mod:shift] Healthstone; Fireball
/use 13
/stopmacro [dead]
/script DoSomeFunction()
```

### Common patterns

**Modifier override:**
```
/cast [mod:shift] Pyroblast; Fireball
```
Casts Pyroblast when Shift is held, Fireball otherwise.

**Combat-conditional cast:**
```
/cast [combat] Recklessness; [nocombat] Heroic Leap
```

**Conditional item use:**
```
/use [combat] 14; [nocombat] Hearthstone
```

**Macro with showtooltip:**
```
#showtooltip Fireball
/cast [mod:shift] Pyroblast; Fireball
```
Icon and tooltip always shows Fireball info regardless of which spell fires.

**Self-targeting:**
```
/cast [@player] Power Word: Shield
```

---

## Assigning a macro to a slot

Once you've created a macro, it appears in the **Custom Macros** list in the Action Picker's Macro tab. Click it to assign it to the current slot.

Macros can also be used as states — assign the same macro to multiple states with different visibility conditions.

---

## Inline macrotext (without saving)

You can also enter macro text directly in a slot's action as "inline macrotext" without saving it to the macro library. This is useful for one-off or slot-specific macros you don't need to reuse. In the Action Picker, choose **Macro** → **Inline** and type the text directly.

---

## Tips

- For spells that just need a conditional (like `[mod:shift] SpellA; SpellB`), consider using [States](States.md) instead of macros — states give you better icon resolution, per-character filtering, and don't require macro syntax knowledge.
- Use macros for things that genuinely require `/script` or multi-step `/cast` logic that states can't express.
- Unlimited macros means you can be specific: one macro per spec, one per situation, without worrying about running out.
