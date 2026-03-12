# Wise Addon: Technical Constitution

## Project Goal
A high-performance World of Warcraft (Retail 11.0+) using pure LUA.  Only use libraries if they provide a significant improvement in performance or usability.

## Tech Stack
- Language: Lua (WoW-variant)
- Framework:
- IDE: Antigravity 2026
- Agent Trio: Claude Code (Logic), Jules (Background Ops), Gemini (Arch)

## Coding Standards
- **Locals First:** Always use `local` variables for functions and data to avoid global namespace pollution.
- **Naming:** Use CamelCase for global table `Wise` and functions; use camelCase for local variables.
- **Frames:** Prefer modern `Mixins` over legacy XML templates when possible.
- **Table Management:** When clearing tables, use the built-in `wipe(table)` function to safely and efficiently clear the contents without creating memory garbage collection overhead.
- **Code Organization:** To prevent bloating `Wise.lua`, large default configurations and standard loadout bars (such as the Demo bar) should be created as separate files in the `modules/` directory and dynamically hooked into `Wise.lua` for initialization and resets.
- **Optimization:** Optimize performance where possible, e.g., pre-parsing condition strings or using O(1) lookups in `modules/States.lua`.

## Verification Workflow
- **WoW API:** Assume Retail 11.0+ (The War Within/Midnight) API names.
- **Automated Tests:** Do not write custom automated tests for the addon, as executing and passing them requires the actual World of Warcraft game client to be running.
- **tests.xml Workflow:** Every bug fix, feature, or test must add a debugging/testing procedure to `tests.xml`. Before every merge, review `tests.xml` to check if existing tests are still needed, ensuring the file stays clean and unpolluted.
- **Syntax Validation:** The development/shell environment for this repository lacks a native Lua interpreter by default. To perform syntax validation for Lua files, install luajit (`sudo apt-get install -y luajit`) and run `luajit -bl <file>`.
- **Unit Testing:** Unit tests that mock core APIs via monkey-patching should be excluded from `Wise.toc` and should always restore the original functions immediately after execution to prevent side effects in the production environment.

## Textures and Media
- **TGA Format:** Custom `.tga` mask textures for WoW must be saved as uncompressed 32-bit TGA files with an 8-bit alpha channel (RGBA), where the mask shape is opaque white and the background is transparent black.
- **Media Path:** Custom textures (like alpha masks for button shapes) are stored in the `Media/` directory as `.tga` files and referenced in code as `Interface\AddOns\Wise\Media\<FileName>.tga`.
- **Texture Wrapping:** Custom alpha mask textures used with `CreateMaskTexture()` require specific texture wrapping mode arguments `"CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE"` in `SetTexture()` to apply correctly without edge bleeding.
- **Dynamic Masking:** When dynamically applying mask textures to UI elements, ensure `SetTexture(...)` is called outside of the initial `CreateMaskTexture()` creation block so that texture changes update visually at runtime.
- **Generation:** The development environment supports generating custom `.tga` media files using Python's `Pillow` library. Install via `python3 -m pip install pillow --break-system-packages` if missing.

## UI Specifics
- **Solid Backgrounds:** When creating solid backgrounds for UI frames in WoW using `BackdropTemplate`, use `Interface\Buttons\WHITE8X8` combined with `SetBackdropColor(r, g, b, a)` for a fully opaque, customizable background.
- **Secure Custom Actions:** To execute arbitrary Lua code securely for custom actions in `core/GUI.lua`, they are implemented as macros by setting `secureType = "macro"`, `secureAttr = "macrotext"`, and using a `/run` command in `secureValue`.
- **Edit Mode Positioning:** When dynamically changing a frame's anchor point during edit mode in `modules/editmode.lua`, the x/y offsets must be recalculated using `GetEffectiveScale()` relative to `UIParent`. Position calculations must use the proxy anchor's center (`f.Anchor:GetCenter()`) rather than the frame's geometric center.
- **Main Options Frame:** `WiseOptionsFrame` is explicitly excluded from `UISpecialFrames` to ensure it remains open when other standard WoW panels are opened. Elements reacting to its visibility should utilize `HookScript("OnShow")` and `HookScript("OnHide")` on the frame directly.

## Addon Specifics
- **Conditionals Validation:** `Wise:ValidateVisibilityCondition` in core/Conditionals.lua enforces security by disallowing newline (\n) and carriage return (\r) characters to prevent macro command injection.
- **Talent Visibility:** Talent visibility requirements (stored in `action.talentRequirements`) are displayed as a comma-separated list of resolved spell names using `C_Spell.GetSpellInfo(spellID)`.
- **Interface Conditionals:** Interface conditionals (e.g., `[wise:groupName]`) and Addon Loading Magic conditionals (e.g., `[aml:slotname]`) are dynamically generated and evaluated in `core/Conditionals.lua`.
- **Specializations:** Action visibility based on specializations uses the 'spec' category. The `action.specRequirements` field stores a table of required spec IDs.
- **Nesting Cycles:** `Wise:WouldCreateNestingCycle` in `modules/Nesting.lua` proactively prevents circular interface nesting by traversing the hierarchy via `Wise:GetParentInfo`.
