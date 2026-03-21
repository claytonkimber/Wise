# Conditionals Reference

Conditionals control when interfaces are shown and when states are active. They use the same bracket syntax as WoW macro conditionals: `[condition]` or `[condition1,condition2]` (AND) or `[cond1][cond2]` (OR).

Conditionals can be used in:
- **Interface visibility** — Custom Show / Custom Hide fields in Settings
- **Slot states** — the conditions field on any state

---

## Standard WoW conditionals

These are built into WoW and work in both secure and insecure contexts.

### Player state

| Conditional | True when... |
|---|---|
| `[combat]` | You are in combat |
| `[nocombat]` | You are not in combat |
| `[dead]` | You (or target) are dead |
| `[resting]` | You are in a rest area |
| `[flying]` | You are flying |
| `[mounted]` | You are mounted |
| `[swimming]` | You are swimming |
| `[falling]` | You are falling |
| `[indoors]` | You are indoors |
| `[outdoors]` | You are outdoors |
| `[stealth]` | You are stealthed |
| `[channeling]` | You are channeling any spell |
| `[channeling:SpellName]` | You are channeling a specific spell |

### Stance / form / bonus bar

| Conditional | True when... |
|---|---|
| `[stance:N]` | You are in stance N |
| `[form:N]` | You are in shapeshift form N |
| `[bonusbar:N]` | Bonus bar N is active (1=Bear/Skyriding, 2=Cat, etc.) |
| `[bonusbar:1/2/3/4/5]` | Any bonus bar is active (Wise special — more reliable than plain `[bonusbar]`) |
| `[extrabar]` | Extra action button bar is active |
| `[overridebar]` | Override action bar is active (vehicles, etc.) |
| `[possessbar]` | Possess bar is active (MC, mind control) |

### Specialization and talents

| Conditional | True when... |
|---|---|
| `[spec:N]` | You are in specialization N (1–4) |
| `[talent:SpellID]` | You have the talent with that spell ID selected |
| `[known:SpellID]` | You know the spell with that ID |
| `[known:SpellName]` | You know the named spell |

### Group and PvP

| Conditional | True when... |
|---|---|
| `[group]` | You are in any group |
| `[group:party]` | You are in a party |
| `[group:raid]` | You are in a raid |
| `[pvpcombat]` | You are in PvP combat |
| `[petbattle]` | You are in a pet battle |

### Equipment

| Conditional | True when... |
|---|---|
| `[equipped:Type]` | You have an item of that type equipped (e.g., `[equipped:Staff]`) |
| `[worn:Type]` | Alias for `[equipped]` |

### Target and unit conditions

| Conditional | True when... |
|---|---|
| `[@target,exists]` | You have a target |
| `[@target,help]` | Your target is friendly |
| `[@target,harm]` | Your target is hostile |
| `[@target,dead]` | Your target is dead |
| `[@focus,exists]` | You have a focus target |
| `[@mouseover,exists]` | Your mouse is over a unit |
| `[@pet,exists]` | You have a pet |
| `[@pet,dead]` | Your pet is dead |

### Modifier keys and mouse buttons

| Conditional | True when... |
|---|---|
| `[mod:shift]` | Shift key is held |
| `[mod:ctrl]` | Ctrl key is held |
| `[mod:alt]` | Alt key is held |
| `[mod:shift,ctrl]` | Both Shift and Ctrl are held |
| `[button:1]` | Left mouse button triggered the action |
| `[button:2]` | Right mouse button |
| `[button:3]` | Middle mouse button |

### Action bars

| Conditional | True when... |
|---|---|
| `[actionbar:N]` | Action bar page N is currently active |

### Vehicle / special bars

| Conditional | True when... |
|---|---|
| `[vehicleui]` | You are in a vehicle with a UI |
| `[unithasvehicleui]` | Your unit has a vehicle UI available |
| `[canexitvehicle]` | You can exit the current vehicle |

---

## Wise custom conditionals

These are evaluated by Wise's insecure ticker (every 0.2s) and can be used anywhere you'd use a standard conditional.

> **Note:** Wise custom conditionals cannot be combined with secure conditionals in the same bracket for secure frame actions. Use them in separate brackets or for visibility/state conditions only.

### UI context

| Conditional | True when... |
|---|---|
| `[bank]` | The Bank frame is open |
| `[guildbank]` | The Guild Bank frame is open |
| `[warband]` | The Warband Bank frame is open |
| `[mail]` | The Mailbox frame is open |
| `[auction]` | The Auction House frame is open |
| `[undermouse]` | The mouse cursor is over the interface or any of its buttons |
| `[zoneability]` | A zone ability (Garrison ability, Covenant ability, etc.) is currently available |

### Player attributes

| Conditional | True when... |
|---|---|
| `[mercenary]` | You have the Mercenary Contract buff (cross-faction BG queueing) |
| `[pvp]` | Your PvP flag is enabled |
| `[horde]` | You are Horde |
| `[alliance]` | You are Alliance |

---

## Combining conditionals

**AND** — multiple conditions inside one bracket:
```
[combat,mod:shift]      → in combat AND holding Shift
[spec:1,stealth]        → spec 1 AND stealthed
```

**OR** — multiple brackets in sequence:
```
[combat][stealth]       → in combat OR stealthed
[bank][auction]         → bank open OR auction house open
```

**Negation** — prefix with `no`:
```
[nocombat]              → not in combat
[nostealth]             → not stealthed
[nomod]                 → no modifier key held
```

**Fallback (no condition)** — a state or visibility rule with no conditional is always true. Use this as the last state in a priority list as your default:
```
State 1: Shadowmeld     [nightelf]
State 2: Feign Death    [hunter]
State 3: Vanish         (no conditions — always active for any other class)
```

---

## Examples

| Goal | Conditional |
|---|---|
| Show ring only at bank | `[bank]` (Custom Show) |
| Show only when hovering and out of combat | `[undermouse,nocombat]` |
| Show only in PvP | `[pvp]` |
| Use different potion in combat vs. out | State 1: `[combat]`, State 2: (no condition) |
| Hold Shift for a different action | State 1: `[mod:shift]` (place first in priority order) |
| Show only while in Balance Druid form | `[spec:1,bonusbar:1]` |
| Show only in M+ or raid | `[instance:dungeon][instance:raid]` |
