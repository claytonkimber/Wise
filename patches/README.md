# patches/

This directory holds [patch-package](https://www.npmjs.com/package/patch-package)
diffs that modify installed npm dependencies. They are re-applied automatically
on every `npm install` via the `postinstall` script in `package.json`.

## `codesight+1.14.0.patch` — WoW Lua support for CodeSight

**This patch file IS the source-of-truth for CodeSight's WoW addon support.**
If you went looking for the WoW/Lua logic and couldn't find it as a normal
source file, this is why: it lives inside the gitignored npm package
(`node_modules/codesight/dist/`) and is versioned here only as a diff.

What the patch adds (open it as a readable diff to see the full code):

- **`dist/scanner.js`** — teaches CodeSight that a project with a root `*.toc`
  is a `lua` project (it otherwise mislabels Wise as JavaScript), and adds
  `.lua`/`.toc` to the scanned extensions.
- **`dist/detectors/graph.js`** — the dependency graph:
  - `extractTocLoadOrder` / `extractWowXmlIncludes` — load-order edges from the
    `.toc` and `<Script/Include file=>` XML (Tier 1).
  - `extractWowSymbols` / `resolveWowSymbolGraph` — the **Tier 2** `Wise.*`
    namespace symbol graph: links files that read `Wise.Foo`/`Wise:Foo` to the
    files that define them, so `codesight_get_blast_radius` returns real
    downstream dependents instead of "no downstream deps". Hub symbols defined
    in `>= WOW_HUB_DEFINE_THRESHOLD` (4) files are skipped as shared state.

### Editing the logic

1. Edit the live files under `node_modules/codesight/dist/` and test.
2. Regenerate this patch (node must be on PATH — `patch-package` shells out to
   bare `node`; in git-bash: `export PATH="/c/Program Files/nodejs:$PATH"`):
   ```
   npx patch-package codesight
   ```
3. Commit the updated `patches/codesight+1.14.0.patch`.

If CodeSight is bumped off `1.14.0`, the filename version must match the
installed version, so re-run step 2 after the bump.

### Packaging note

CodeSight (this patch, `package.json`, `node_modules/`, `.codesight/`) is dev
tooling only. It is versioned in git but excluded from the CurseForge `.zip`
via `.pkgmeta`'s `ignore:` list, and is not referenced by `Wise.toc`, so it
never ships to players.
