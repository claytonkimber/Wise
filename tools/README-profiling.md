# Profiling Wise with Perfy (in place, no copies)

`perfy-profile.ps1` instruments the **real** addon at its real path. `AddOns\Wise`
keeps pointing where it always points, so what you profile is exactly what you run.
No copies, no junction swapping, no separate instrumented tree.

Run everything from the addon root (`_dev_\Wise`).

## The loop

```powershell
.\tools\perfy-profile.ps1 -Status        # where things stand
.\tools\perfy-profile.ps1 -Instrument    # rewrite files in place
```

Then in game:

```
/reload
/perfy start 30      (or /perfy start ... /perfy stop)
/reload              <- REQUIRED: this is what writes the capture to disk
```

Back in PowerShell:

```powershell
.\tools\perfy-profile.ps1 -Analyze -OutDir .\..\..\profiles\run-01
.\tools\perfy-profile.ps1 -Restore       # back to normal
```

`-Restore` is safe to run at any time, including after a failed or interrupted
run. It is idempotent.

## Setup

Requires [lua-language-server](https://github.com/LuaLS/lua-language-server) (does
the instrumentation) and a standalone Lua interpreter (runs the analyzer), plus a
Perfy checkout at `_dev_\Perfy`.

Paths are discovered automatically: the WTF account folder is found by looking for
an existing Perfy capture (falling back to the most recently used account), and
`lua.exe` is taken from `PATH`. Override any of them if your install differs:

```powershell
$env:PERFY_WOW_ACCOUNT = "MYACCOUNT"      # WTF\Account\<this>\SavedVariables
$env:PERFY_LUALS       = "C:\path\to\lua-language-server"
$env:PERFY_LUA         = "C:\path\to\lua.exe"
```

## How your work is protected

Perfy rewrites `.lua` and `.toc` files in place, so "restore" means git. Every
`.lua`/`.toc` file in this repo is tracked, so git can restore them exactly.

* **Uncommitted tracked changes block `-Instrument`.** Pass `-Force` to
  auto-stash them; `-Restore` pops that exact stash back (found by commit sha,
  so it works even if you stashed other things in between).
* **Untracked files are never touched or stashed** - including this script.
* `-Restore` only checks out tracked `.lua`/`.toc` paths. It deliberately does
  *not* run `git checkout -- .`, which would delete untracked files.
* A `.perfy-instrumented` marker records state between runs so `-Restore` knows
  what to undo even across separate shell sessions.

If `-Restore` ever fails to pop the stash, your work is still safe:

```powershell
git stash list
git stash pop <the stash listed in .perfy-instrumented>
```

## How long can a capture be?

Measured on this UI: **~72,000 trace entries/sec**, **~5.2 MB/s** of SavedVariables.
Rates scale with how many buttons are visible and how busy the fight is, so treat
these as the right order of magnitude rather than exact.

| Capture | Entries | File | RAM to analyze | Verdict |
|---|---|---|---|---|
| 30s | ~2.2M | ~156 MB | ~0.8 GB | **recommended** |
| 60s | ~4.3M | ~313 MB | ~1.6 GB | comfortable |
| 120s | ~8.7M | ~626 MB | ~3.2 GB | slow but fine |
| 180s | ~13.0M | ~938 MB | ~4.9 GB | near the limit |
| 240s+ | ~17M+ | ~1.2 GB+ | ~6.5 GB+ | analyzer will likely OOM |

Three separate ceilings, in the order you'll hit them:

1. **The analyzer** is the real limit. It reads the entire file into one string,
   then builds a ~400-byte table per entry (measured: 401 B). A 60s capture needs
   ~1.6 GB; 240s needs ~6.5 GB and tends to die. Note it also fails on a *second*
   full load of a large file in the same process - analyze once per run.
2. **The game client** grows ~1 GB/min while tracing, because Perfy disables the
   GC to keep measurements clean. A 5-minute capture adds ~5 GB to WoW's memory.
3. **Upstream guidance** is 10-20M entries max, which lines up with ~140-280s here.

**Longer is not better.** 30 seconds of the exact combat you care about beats
5 minutes of mixed content - a long capture averages away the thing you're
hunting, and every extra second makes the trace harder to work with. Use
`/perfy start 30` so the duration is identical every time.

## Getting comparable numbers

Perfy's own instrumentation adds overhead, so absolute numbers are inflated in
every run. Only compare runs to each other, and only if the conditions match.

Captures are **not** comparable unless you control:

* **Duration** - normalise per second, or always capture the same length.
  `/perfy start 30` enforces this automatically.
* **Visible button count** - the dominant scaling factor. A run with 180 buttons
  visible costs ~11% more than one with 162 for the same code. Check
  `UpdateButtonCooldown calls / UpdateAllCooldowns calls` to get buttons-per-sweep.
* **Activity level** - more abilities used means more genuine cooldown events
  and more sweeps. Same rotation, same pull type.
* **The post-`/reload` rebuild** - `ForceRefreshAllDisplays` and `UpdateBindings`
  run once and can add 300ms+ to the trace. Wait a few seconds after `/reload`
  before `/perfy start`.

For an apples-to-apples A/B, capture both runs in the same spot, same spec, same
UI layout, same duration, doing the same thing.
