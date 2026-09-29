# modules/ — building Sora modules

This folder is for **writing modules** (a metadata JSON + a JavaScript scraper), not for changing the app. Nothing here is compiled into the IPA, nothing here touches `project.pbxproj`, and no CI build is needed to test a change: host the `.js`, bump `version` in the metadata, and hit refresh in Settings → Modules.

## Files

| File | What it is | Trust level |
|---|---|---|
| `MODULE_CREATION.md` | The module contract, derived from this repo's Swift source with file/line refs | **Authoritative.** When anything disagrees with it, it wins. |
| `reference/SKILL.md` | Upstream devs' cheat sheet: manifest template, return schemas, JS template, `run_module.js` usage | Good starting point; has errors listed below |
| `reference/module-builder.md` | Upstream devs' agent persona (OpenCode format: `mode: primary`, `permission:`) | Rules are mostly right; see below |

Keep the two `reference/` files verbatim so they can be diffed against future upstream copies. Put corrections here, not in them.

Actual modules go in `modules/<source-name>/` (manifest + script). `modules/anikura/` is the reference implementation — a fork of MXFia19's module with the subtitle fix and its Supabase tracker removed; see `MODULE_CREATION.md` §9.10. Its `scriptUrl` points at this repo's `main` branch on raw.githubusercontent.com, so a script change goes live only after it's pushed, and `version` must be bumped every time.

## Corrections to the upstream reference docs (verified against source)

1. **`extractDetails` must return an array, not an object.** `reference/SKILL.md` §2 shows `{ description, aliases, airdate }`, but the async path casts to `[[String: Any]]` (`JSController-Details.swift:123`); a bare object logs "Failed to parse JSON of extractDetails" and shows nothing. Return `JSON.stringify([{ … }])` — the template in the same file does this correctly.
2. **Top-level `subtitle` is ignored.** The `extractStreamUrl` schema puts `"subtitle"` at the top level. Swift only reads top-level **`subtitles`** (plural) or `subtitle` *inside* a stream object (`JSController-Streams.swift:89-95`). See `MODULE_CREATION.md` §9.5.
3. **The template breaks its own `console.log` rule.** `console.log` is bound as `(String) -> Void` (`JavaScriptCore+Extensions.swift:15`), so `console.log('Fetch error:', error)` prints only `Fetch error:` and drops the error. Use `console.log('Fetch error: ' + error)`.
4. **The template's `extractEpisodes` catch returns `undefined`.** Return `JSON.stringify([])` or a placeholder, per rule 6 of `module-builder.md`.
5. **"Export four functions" means top-level globals.** There is no `export`/`import`; Swift looks functions up by name on the global object. `export function …` is a syntax error that kills the whole script.
6. **The JSON templates contain `//` comments**, which are not valid JSON. Strip them before hosting the manifest.
7. **Episode `number` as integer is only right for `asyncJS: true`.** In sync mode it must be a string (`MODULE_CREATION.md` §5.3). Since `module-builder.md` mandates async-only, the rule holds as long as you stay async.
8. **`author.url` and `downloadSupport` are not read by the app.** They matter to the community library index only. `softsub`, `multiStream`, `multiSubs` are also inert in-app.
9. **Returning a bare stream URL string works** (in every path, `JSController-Streams.swift:114,211,345`), but returning `null` makes the app try to play the literal string `"null"`. Return `""` or a placeholder on failure.
10. **`fetchv2` doesn't throw on network errors** — it resolves with `{ error }`. The `soraFetch` wrapper's `catch` won't fire for a dead host; check `res.status`.
11. **No `setTimeout`/`setInterval`** in JavaScriptCore. Neither reference doc mentions this; see `MODULE_CREATION.md` §6.
12. `module-builder.md` contains `[cite: N]` markers — leftovers from whatever tool generated it. Ignore them.

## Testing: `run_module.js` is not the real runtime

`reference/SKILL.md` §3 points at a Node VM harness downloaded from `files.catbox.moe` (an anonymous file host). Two cautions:

- **Read it before running it.** It's executable code from an unattributed URL. Save it as `modules/tools/run_module.js` only after review.
- **Passing in Node ≠ passing in Sora.** Node has `setTimeout`, a real `fetch`, and multi-arg `console.log`; the app's JavaScriptCore has none of those. Treat the harness as a fast first check, then confirm on device via Settings → Logger (filter `Debug`).

The persona in `module-builder.md` assumes a Kali Linux shell; this machine is Windows, so run the harness with `node` from Git Bash or PowerShell.
