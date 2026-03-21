# Importing and Exporting

Wise lets you export any interface as a shareable string and import strings from others. This is useful for:
- Sharing setups with friends or guildmates
- Backing up your configuration before making big changes
- Distributing community-made interface templates

---

## Exporting an interface

1. Open the Options Panel (`/wise`)
2. Select the interface you want to export in the left sidebar
3. Click the **Export** button (near the interface name or in the Settings tab)
4. A text box appears with a long Base64-encoded string
5. Copy the string (`Ctrl+C`)

The exported string contains all of your interface's configuration: layout type, every slot and its states, all conditions, appearance settings, position, and visibility rules.

---

## Importing an interface

1. Open the Options Panel (`/wise`)
2. Click the **Import** button (in the Settings tab or near the "New Interface" area)
3. Paste the string into the text box (`Ctrl+V`)
4. Click **Import**

Wise decodes and validates the string, then adds the interface to your list. If the import string contains multiple interfaces (a bundle), they're all imported.

---

## Handling naming conflicts

If an imported interface has the same name as one you already have, Wise pauses and asks what to do:

1. A rename dialog appears showing the conflicting name
2. You can either:
   - **Rename** — type a new name and click Import to add it with the new name
   - **Skip** — ignore this interface (if importing a bundle, the rest continue)

This prevents accidental overwrites of interfaces you've already customized.

---

## What's included in the export

The export string is a complete snapshot of the interface at the time of export:

- Interface name, type (Circle/Box/Line/List/Button)
- Every slot and all its states, including conditions and conflict strategies
- All action types and values (spell IDs, item IDs, macro text, etc.)
- Appearance settings (icon size, padding, font, colors)
- Visibility and keybind settings
- Position (anchor, X/Y offset)

It does **not** include account-specific data like character names used in character-specific state filters (those are stored by name and will still work if the same character exists on the importing account).

---

## Importing from OPie

If you have a ring configured in OPie and want to bring it into Wise, you cannot use OPie's default export format (strings beginning with `oetohH7` are compressed and incompatible with Wise's importer).

**Workaround:**
1. In OPie, open the ring you want to migrate
2. Use **Snapshot → Copy as Lua** to generate an uncompressed representation
3. This format can be parsed by Wise on import

---

## Sharing community configs

When sharing a Wise export string:
- Post it in a pastebin, Discord message, or wherever you share WoW addon configs
- Recipients paste the string into their Wise Import dialog
- All states, conditions, and layout settings come through intact

Spells and items resolve by ID, so they work regardless of game locale. Custom macros are exported as text and come through verbatim.
