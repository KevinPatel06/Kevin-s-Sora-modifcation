# modules/ — building Sora modules

This folder is for **writing modules** (a metadata JSON + a JavaScript scraper), not for changing the app. Nothing here is compiled into the IPA, nothing here touches `project.pbxproj`, and no CI build is needed to test a change: host the `.js`, bump `version` in the metadata, and hit refresh in Settings → Modules.

## Files

| File | What it is | Trust level |
|---|---|---|
| `MODULE_CREATION.md` | The module contract, derived from this repo's Swift source with file/line refs | **Authoritative.** When anything disagrees with it, it wins. |
| `reference/SKILL.md` | Upstream devs' cheat sheet: manifest template, return schemas, JS template, `run_module.js` usage | Good starting point; has errors listed below |
| `reference/module-builder.md` | Upstream devs' agent persona (OpenCode format: `mode: primary`, `permission:`) | Rules are mostly right; see below |

Keep the two `reference/` files verbatim so they can be diffed against future upstream copies. Put corrections here, not in them.

Actual modules go in `modules/<source-name>/` (manifest + script). Each manifest's `scriptUrl` points at this repo's `main` branch on raw.githubusercontent.com, so a script change goes live only after it's pushed, and `version` must be bumped every time. Hosting our own copies means upstream fixes don't arrive on their own — re-diff against upstream when a source breaks.

| Module | Upstream | What the fork changed |
|---|---|---|
| `anikura/` | MXFia19 | Subtitles attached per server; Supabase tracker removed. **The reference implementation** — `MODULE_CREATION.md` §9.10 |
| `vidrift/` | MXFia19 | Subtitle urls made absolute (upstream's relative ones were silently dropped); tracker removed |
| `aether/` | MXFia19 | Tracker removed. Subtitles already worked |
| `bingebox/` | MXFia19 | Nothing — copied as-is (no tracker). Its API is behind a Cloudflare challenge, so streams can't be tested from a desktop IP |
| `kissasian/` | xdfkenny | Tries every server and skips the "coming soon" placeholder. Subtitles are burned into the video, not a separate track |

MXFia19's modules are published both at `github.com/MXFia19/module-sora` and `git.luna-app.eu/MXFia19/sources`; the copies here came from GitHub.

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

## Testing: `tools/sora-harness.js`

Use this instead of the `run_module.js` that `reference/SKILL.md` §3 downloads from `files.catbox.moe` (an anonymous file host — unreviewed, and it runs modules with Node's timers, `fetch`, and multi-arg `console.log`, none of which the app has).

```bash
node modules/tools/sora-harness.js modules/anikura/anikura.js --all "one piece"          # search → details → episodes → stream
node modules/tools/sora-harness.js modules/vidrift/vidrift.js --all "the boys" --pick 0 --ep 3
node modules/tools/sora-harness.js modules/kissasian/kissasian.js extractStreamUrl '"https://kissasian.su/…-episode-1"' --logs
```

It gives the module only the globals `JavaScriptCore+Extensions.swift` defines (`fetchv2` resolving `{ error }` on failure, legacy `fetch(url, headers)` → string, single-arg `console.log`, `btoa`/`atob`, **no timers**), loads the script fresh per hook like the app, and reports what the app would do with the result: `extractDetails` not an array, non-integer episode numbers, `extractEpisodes` past 15 s, top-level `subtitle` (ignored), non-`http(s)` subtitle urls (dropped), and whether each subtitle url loads the way the app's loader fetches it (browser UA, no Referer). It prints every host contacted, and never sends requests to `*.supabase.co`.

It makes raw http(s) requests rather than using Node's `fetch`, because Node adds `sec-fetch-*` headers that iOS never sends — VidRift answers those with a 403 the app doesn't get. A host behind a Cloudflare challenge (BingeBox) may block a desktop IP while working on a phone; a failure there isn't proof the module is broken.

Passing here is a first check. Confirm on device via Settings → Logger (filter `Debug`).
