# Module Creation

Everything the app knows about creating, installing, loading, and executing modules. All statements here are derived from the Swift source in this repo — file/line references point at the code that enforces each rule.

---

## 1. What a module is

Two files hosted anywhere over HTTP(S):

1. **A metadata JSON file** — decoded into `ModuleMetadata` (`Sora/Utlis & Misc/Modules/Modules.swift`). This is the URL the user installs.
2. **A JavaScript file** — pointed at by `scriptUrl`. Plain script, no modules/imports. It defines **global functions** that the app looks up by name.

The app never bundles either. `ModuleManager.addModule` downloads both, saves the script as `Documents/<random-uuid>.js`, and appends a `ScrapingModule` record to `Documents/modules.json`.

---

## 2. Metadata schema

```jsonc
{
  "sourceName":    "Example",                       // required
  "author":        { "name": "you", "icon": "https://…/avatar.png" },  // required, both fields
  "iconUrl":       "https://…/icon.png",            // required
  "version":       "1.0.0",                         // required
  "language":      "English",                       // required
  "baseUrl":       "https://example.com",           // required
  "streamType":    "HLS",                           // required
  "quality":       "1080p",                         // required
  "searchBaseUrl": "https://example.com/search?q=%s", // required
  "scriptUrl":     "https://…/example.js",          // required

  "asyncJS":       true,   // optional
  "streamAsyncJS": false,  // optional
  "softsub":       false,  // optional
  "multiStream":   true,   // optional
  "multiSubs":     true,   // optional
  "type":          "anime",// optional
  "novel":         false   // optional
}
```

**Every non-optional field above is genuinely required** — `ModuleMetadata` is a `Codable` struct with non-optional properties, so a missing key makes the whole install fail with a decode error, including `author.name` and `author.icon`.

### What each field actually does

| Field | Effect |
|---|---|
| `sourceName` | Display name; the install sheet refuses a module whose `sourceName` already exists |
| `author.*` | Display only (install sheet, module list) |
| `iconUrl` | Module icon everywhere in the UI |
| `version` | Update trigger. `refreshModules()` re-downloads the script when the remote `version` **string differs** from the stored one — any difference, not a semver comparison. Bump it on every script change. |
| `language` | Display + module-picker grouping (`SearchView.cleanLanguageName`) |
| `baseUrl` | **Functional.** Used as the fallback `Referer` and `Origin` header for playback and downloads when a stream carries no explicit headers (`CustomPlayer.swift`, `VideoPlayer.swift`, `MediaInfoView:2395`, `EpisodeCell:767`). Skipped if empty or containing `"undefined"`. |
| `streamType` | **Functional.** `hls`/`m3u8` (case-insensitive), or a URL containing `.m3u8`, selects the HLS download path; anything else uses the MP4 path (`JSController-StreamTypeDownload.swift:45`) |
| `quality` | Display only |
| `searchBaseUrl` | **Sync mode only.** `%s` is replaced with the percent-encoded keyword and Swift fetches that URL (`JSController-Search.swift:13`). Ignored entirely when `asyncJS` is true — put your search URL construction inside the JS instead. |
| `scriptUrl` | Where the `.js` lives; also re-fetched if the local copy goes missing |
| `asyncJS` | Selects the async (Promise) variant of `searchResults`, `extractDetails`, `extractEpisodes`, and `extractStreamUrl` |
| `streamAsyncJS` | Only consulted when `asyncJS` is false: selects the hybrid stream path (Swift fetches HTML → Promise-returning `extractStreamUrl`) |
| `novel` | Switches the whole detail screen to chapters/reader mode (`extractChapters` + `extractText` instead of `extractEpisodes` + `extractStreamUrl`) |
| `type` | Display only ("Type" tile on the install sheet) |
| `softsub` | **Currently inert.** It is threaded into `fetchStreamUrl*` as a parameter but never read in any of the three implementations. |
| `multiStream`, `multiSubs` | **Currently inert.** Declared on `ModuleMetadata` and never read anywhere. Multiple streams/subtitles work regardless — the app decides from the *shape of the returned data*, not these flags. |

---

## 3. Installation and update flow

**Install entry points** (all converge on `ModuleAdditionSettingsView` → `ModuleManager.addModule`):

- `sora://module?url=<metadata-json-url>` — handled by `SoraApp.handleURL`; works from Safari, a QR code, a shortcut, anywhere iOS can open a URL.
- The in-app **Community Library** (`CommunityLib.swift`): a `WKWebView` whose navigation delegate cancels any `sora://module` link and opens the install sheet instead. The library's own page URL is set by `sora://default_page?url=…` and stored in `lastCommunityURL`.
- Pasting the metadata URL in Settings → Modules.

**Storage after install**

| Path | Contents |
|---|---|
| `Documents/modules.json` | JSON array of `ScrapingModule` = `{ id, metadata, localPath, metadataUrl, isActive }` |
| `Documents/<uuid>.js` | the scraper source (`localPath` is just the filename) |
| `UserDefaults["selectedModuleId"]` | the active module's UUID string |
| `UserDefaults["moduleSettings_<uuid>"]` | JSON dict of user setting overrides |

**Duplicate rules:** `addModule` throws if any installed module has the same `metadataUrl`; the install sheet separately greys out modules whose `sourceName` already exists.

**Updates:** `refreshModules()` (Settings, or automatically at launch when `refreshModulesOnLaunch` is on) re-fetches each `metadataUrl`, and on a `version` string change re-downloads the script over the same `localPath`, keeping the same UUID, then re-applies the user's setting overrides. `checkJSModuleFiles()` re-downloads any `.js` that vanished (e.g. after an iCloud restore).

**Deletion** removes the `.js`, drops the record, and posts `.moduleRemoved`, which makes `LibraryManager` prune that module's bookmarks.

---

## 4. Execution model

`JSController` (singleton) holds exactly one `JSContext`.

```swift
func loadScript(_ script: String) {
    context = JSContext()                    // ← previous context is thrown away
    context.setupJavaScriptEnvironment()
    context.evaluateScript(script)
}
```

Consequences you must design around:

- **No persistent state.** Every screen re-reads the `.js` from disk and calls `loadScript` immediately before invoking a hook. Globals you set during `searchResults` are gone by the time `extractDetails` runs. Cache nothing across hooks; recompute or re-fetch.
- **Top level runs on every call.** Keep top-level work to constant declarations. Anything expensive at file scope is paid once per user action.
- **Functions are found by exact global name** via `context.objectForKeyedSubscript("…")`. Use plain `function name(...) {}` declarations at top level. A missing function is logged as an error and the operation returns empty.
- **Uncaught exceptions** go to `context.exceptionHandler`, which only `print`s — check the in-app logger for your own `console.log` output instead.
- The app defines a helper `extractChaptersWithCallback` in `JSController.setupContext()`, but it is never called from Swift and is destroyed by the first `loadScript`. Ignore it.

---

## 5. The hooks

Six global functions. Which are needed depends on `novel`; which signature they get depends on `asyncJS` / `streamAsyncJS`.

| Hook | Video module | Novel module | Sync arg (`asyncJS` false) | Async arg (`asyncJS` true) |
|---|---|---|---|---|
| `searchResults` | required | required | HTML of `searchBaseUrl` with `%s` filled | the raw keyword |
| `extractDetails` | required | required | HTML of the item page | the item URL |
| `extractEpisodes` | required | — | HTML of the item page | the item URL |
| `extractStreamUrl` | required | — | HTML of the episode page | the episode URL (or HTML, under `streamAsyncJS`) |
| `extractChapters` | — | required | the item URL (always) | the item URL (always) |
| `extractText` | — | required | the chapter URL (always) | the chapter URL (always) |

**Async hooks must return a Promise** that resolves to a **JSON string**. Swift calls `result.toString()` and feeds it to `JSONSerialization`, so `return JSON.stringify(array)` — not the array itself. (`extractChapters` and `extractText` are the exceptions; see below.)

**Sync hooks must return synchronously.** If a sync hook returns a Promise, Swift sees the literal string `"[object Promise]"` and aborts the operation — this is the single most common symptom of a mismatched `asyncJS` flag.

### 5.1 `searchResults`

```js
// asyncJS: true
async function searchResults(keyword) {
    const res  = await fetchv2(`https://example.com/search?q=${encodeURIComponent(keyword)}`);
    const html = await res.text();
    const results = [];
    // …parse…
    results.push({ title: "…", image: "https://…/poster.jpg", href: "https://…/item/1" });
    return JSON.stringify(results);
}
```

Shape: `[{ title, image, href }]`. In the async path all three keys are **required** — entries missing any of them are silently dropped (`JSController-Search.swift:83`). In the sync path missing keys default to `""`, but every value must be a string (Swift casts to `[[String: String]]`).

`href` is the opaque identifier passed straight back to `extractDetails` / `extractEpisodes`. Results are de-duplicated by `href` before display, so `href` must be unique per item.

### 5.2 `extractDetails`

Shape: **an array with one object**, `[{ description, aliases, airdate }]` — all strings. The app reads `.first`.

```js
async function extractDetails(url) {
    return JSON.stringify([{
        description: "Synopsis text",
        aliases:     "Alt Title / 別題",
        airdate:     "2024-01-05"
    }]);
}
```

For `novel` modules the same three fields are used, but `aliases` is hidden and the synopsis is laid out differently (`MediaInfoView:323-394`).

### 5.3 `extractEpisodes`

The two paths disagree on types — this is a real trap:

| | sync (`asyncJS` false) | async (`asyncJS` true) |
|---|---|---|
| Cast | `[[String: String]]` | `[[String: Any]]` |
| `number` | **string**, parsed with `Int(...)`; unparseable entries are dropped | **`Int`**, defaults to `0` |
| `href` | required string | string, defaults to `""` |
| `title` | optional, honored | **ignored** — hardcoded to `""` |

```js
// asyncJS: true  →  numbers must be real numbers
return JSON.stringify([{ number: 1, href: "https://…/ep/1" }]);

// asyncJS: false →  numbers must be strings
return [{ number: "1", href: "https://…/ep/1", title: "Pilot" }];
```

`EpisodeLink.duration` exists in the model but no parser ever populates it. Episode titles and images on the detail screen come from TMDB, not from the module.

The async path has a **15-second timeout** (`JSController-Details.swift:180`); if `extractEpisodes` hasn't resolved by then the app proceeds with an empty list.

### 5.4 `extractStreamUrl`

The most permissive hook — Swift tries several shapes in order (`JSController-Streams.swift:70-117`, `MediaInfoView.streamOptions`). Return whichever fits:

```js
// 1. Single stream, no headers
return JSON.stringify({ stream: "https://…/master.m3u8" });

// 2. Single stream with headers  →  headers are applied to playback AND download
return JSON.stringify({
    stream: { url: "https://…/master.m3u8", headers: { Referer: "https://example.com/" } }
});

// 3. Multiple named servers (preferred for multi-server sources)
return JSON.stringify({
    streams: [
        { title: "Server A 1080p", streamUrl: "https://…/a.m3u8", headers: { Referer: "…" }, subtitle: "https://…/a.vtt" },
        { title: "Server B 720p",  url:       "https://…/b.mp4"  }
    ]
});

// 4. Flat alternating array: title, url, title, url…  (bare URLs also allowed)
return JSON.stringify({ streams: ["Server A", "https://…/a.m3u8", "Server B", "https://…/b.m3u8"] });

// 5. Bare string (sync mode only, when nothing parses as JSON)
return "https://…/master.m3u8";
```

Per-source object keys: `streamUrl` **or** `url` (required, first non-empty wins), `title` (falls back to `"Stream N"`), `headers` (`{String: String}`), `subtitle` (single track for that source).

**Subtitles** ride alongside, at the top level:

```js
return JSON.stringify({
    stream:    "https://…/master.m3u8",
    subtitles: "https://…/en.vtt"                                  // single
    // or: ["English", "https://…/en.vtt", "Spanish", "https://…/es.vtt"]   // title/url pairs
    // or: ["https://…/en.vtt", "https://…/es.vtt"]                          // bare → "Subtitle 1", "Subtitle 2"
});
```

When more than one stream or more than one subtitle comes back, the app shows a "Select Server" / "Select Subtitle" action sheet. Only `.vtt` is parsed by the custom player's subtitle loader.

Under `streamAsyncJS: true` (with `asyncJS` false), Swift fetches the episode page first and passes the **HTML** to your Promise-returning `extractStreamUrl` — the argument is HTML, not a URL, even though the function is async.

### 5.5 `extractChapters` (novel modules)

Always called with the **item URL**, regardless of `asyncJS`. May return either a Promise **or** a plain array, and either a real array **or** a JSON string — all four combinations are handled (`JSController-Novel.swift:61-134`).

```js
async function extractChapters(url) {
    return [{ href: "https://…/ch/1", title: "Chapter 1", number: 1 }];
}
```

Shape: `[{ href: String, title: String, number: Int }]`. All three are required to open a chapter (`MediaInfoView:1304`). Reading progress is keyed on `href`.

### 5.6 `extractText` (novel modules)

Called with the **chapter URL**. Returns the chapter body as a string (HTML or plain text) — Promise or direct value both work. Anything falsy or empty triggers a Swift-side fallback that fetches the page itself and heuristically carves out `<article>`, `.chapter-content`, `.content`, `#chapter-content`, `.chapter`, `<main>`, or `<body>`, then strips scripts/styles/nav/ads. That fallback is a safety net, not something to design around.

---

## 6. The JavaScript runtime

JavaScriptCore only — **no DOM, no `document`, no `window`, no `XMLHttpRequest`, no `require`/`import`, and no timers** (see the warning at the end of this section). The language itself is current: `class`, `async`/`await`, template literals, `Set`/`Map`, spread, `Promise.all`, `String.matchAll`, and optional chaining (`?.`) all work on iOS 15+.

Globals are injected by `JSContext.setupJavaScriptEnvironment()` (`Sora/Utlis & Misc/Extensions/JavaScriptCore+Extensions.swift:383`):

### Networking

**`fetchv2(url, headers = {}, method = "GET", body = null, redirect = true, encoding = "utf-8")`** — the one you want.

```js
const res  = await fetchv2(url, { Referer: "https://example.com/" });
const html = await res.text();
const data = await (await fetchv2(api, {}, "POST", { id: 42 })).json();
```

Resolves to `{ status, headers, text(), json() }`. Details that bite:

- A non-string `body` on a non-GET request is `JSON.stringify`'d automatically.
- A GET with a body **fails** — resolves with the string `"GET request must not have a body"`.
- `redirect: false` blocks redirects, so you can read a `Location` header off `res.headers`.
- `encoding` accepts `utf-8`, `windows-1251`/`cp1251`, `windows-1252`/`cp1252`, `iso-8859-1`/`latin1`, `ascii`, `utf-16`; unknown values fall back to UTF-8 with a warning.
- **Responses over 10 MB are rejected.**
- **Network errors resolve, they do not reject** — you get `{ error: "…" }` with no `status`/`body`. Always check `res.status` or `res.error` rather than relying on `try/catch`.

**`fetch(url, headers)`** — legacy. Resolves to the raw body **string**, rejects on error. Kept for older modules.

**`networkFetch(url, options)`** and friends — a headless `WKWebView` that loads the page, runs its JavaScript, and reports the network requests it made. This is how you defeat obfuscated players that assemble the stream URL client-side.

```js
const r = await networkFetch(url, {
    timeoutSeconds: 10,
    headers: {},
    cutoff: ".m3u8",              // resolve early when a request URL contains this
    returnHTML: true,             // include post-JS DOM HTML
    returnCookies: true,
    clickSelectors: ["#play"],    // CSS selectors to click
    waitForSelectors: ["video"],  // wait for these first
    maxWaitTime: 5
});
// → { url, requests[], html, cookies, success, error, totalRequests,
//     cutoffTriggered, cutoffUrl, htmlCaptured, cookiesCaptured, elementsClicked, waitResults }
```

Convenience wrappers: `networkFetchWithHTML(url, timeout)`, `networkFetchWithCutoff(url, cutoff, timeout)`, `networkFetchWithClicks(url, selectors, opts)`, `networkFetchWithWaitAndClick(url, waitSelectors, clickSelectors, opts)`, `networkFetchFromHTML(html, opts)`.

`networkFetchSimple(url, options)` / `networkFetchSimpleFromHTML(html, options)` are the lighter variant — request list only, `{ url, requests, success, error, totalRequests }`, 5s default timeout.

These spin up a real web view; they are slow and battery-hungry. Use `fetchv2` unless the page genuinely requires JS execution.

### Encoding and parsing helpers

`btoa(str)` / `atob(str)` — UTF-8 based; return `null` on invalid input.

Regex-based scraping helpers (`setupScrapingUtilities`) — deliberately crude, no HTML parser is available:

`getElementsByTag(html, tag)` → array of inner HTML · `getAttribute(html, tag, attr)` → first match or `null` · `getInnerText(html)` · `extractBetween(str, start, end)` · `stripHtml(html)` · `normalizeWhitespace(str)` · `urlEncode(str)` / `urlDecode(str)` · `htmlEntityDecode(str)` (only `quot`, `apos`, `amp`, `lt`, `gt`) · `transformResponse(response, fn)`.

### Logging

`console.log(msg)` → logger type `Debug` · `console.error(msg)` → type `Error` · `log(msg)` → `Debug`, prefixed `JavaScript log:`. Arguments are coerced to a single string, so `JSON.stringify` objects yourself.

### `setupWeirdCode()` — adds nothing you can use

`setupJavaScriptEnvironment()` calls `setupWeirdCode()` first, and it comes from the **SoraCore** SPM package rather than this repo. Reading the package (`Sources/Extensions/SoraCore.swift`) shows it injects exactly one global: `_0xB4F2()`, an obfuscated function returning a scrambled watermark string. It is an authorship marker, not a polyfill layer. SoraCore also ships its own parallel `JSController`/`JSContext` stack, but this app does not use it — the app's own copies in `Sora/Utlis & Misc/` are what run.

**So the list above is the complete JS environment.** There is no hidden polyfill source.

### ⚠️ No timers

`setTimeout`, `setInterval`, and `clearTimeout` **do not exist**. JavaScriptCore has no native timers, and neither this app nor SoraCore injects one. Calling `setTimeout` throws `ReferenceError`.

This trips up real modules, because the same module files are written to run in several different client apps (see §10) and some of those do have timers. The shipping AnimePahe module contains `await new Promise(resolve => setTimeout(resolve, 500))` in its episode-pagination retry path — under Sora that line throws, the retry rejects, and the whole `extractEpisodes` call falls through to its error placeholder. The happy path works, so the bug is invisible until a page fetch fails.

For "wait then retry", there is no substitute available in-context. Retry immediately, or spend the wait on a real network call.

---

## 7. Module settings

A module can expose user-editable constants. Delimit them with exact marker comments:

```js
// Settings start
const PREFERRED_QUALITY = "1080p";   // Preferred stream quality
const ENABLE_DUB = false;            // Prefer dubbed audio
const TIMEOUT_SECONDS = 15;          // Request timeout
// Settings end
```

Parsing (`ModuleSettings.swift:115`) uses the regex `^const\s+(\w+)\s*=\s*(.+?);(?:\s*//\s*(.*))?$` per line, so:

- One `const` per line, **terminated with `;`**, no `let`/`var`, no indentation before `const` inside the block.
- The trailing `//` comment becomes the field's label in the settings UI.
- **Type is inferred from the default value**: parses as `Int` → int; contains `.` and parses as `Double` → float; `true`/`false` → bool; otherwise string. Quotes are stripped for display and re-added on write.
- An `options` array (dropdown) exists in the model but the parser always emits `nil`, so every setting renders as a free-form field or toggle.

When the user saves, the overrides are stored in `UserDefaults["moduleSettings_<uuid>"]` **and written back into the `.js` file on disk** by regex substitution (`ModuleManager.writeSettingsToFile`). Two consequences:

- The substitution pattern is `^(\s*)const\s+KEY\s*=\s*.*?;(.*)$` with `.anchorsMatchLines` and is **not scoped to the settings block** — a `const` with the same name anywhere else in the file will also be rewritten. Keep setting names unique across the whole script.
- Your published script is the *default*; the on-device copy diverges. After an update, `refreshModules()` overwrites the script and then re-applies the stored overrides.

---

## 8. Debugging a module

1. **Settings → Logger** is the only console. Filter by type; `console.log` lands under `Debug`.
2. **Enable the `HTMLStrings` filter** to see the exact HTML the app fetched and handed to your sync hooks — it is logged verbatim before every sync parse.
3. **Watch for `"[object Promise]"`** in the log or as a stream URL: a sync hook returned a Promise, or `asyncJS` doesn't match your implementation.
4. **"No JavaScript function X found"** means the name isn't a top-level global — check for a syntax error earlier in the file, which aborts evaluation of everything after it.
5. **Empty results with no error** usually means a shape mismatch: a string `number` in async mode, an `Int` `number` in sync mode, or a search result missing `image`.
6. Iterating is fast: host the `.js` anywhere, bump `version` in the metadata, and hit refresh in Settings → Modules. No app rebuild is needed for module changes.

---

## 9. Patterns from shipping modules

Reviewed against three live modules by 50/50 (also the app's icon author), hosted at `git.luna-app.eu/50n50/sources`: **AnimePahe** (`animepahe.si`, 554 lines), **123Anime** (`123animehub.cc`, 165 lines), **AnimeHeaven** (`animeheaven.me`, 114 lines). All three are `asyncJS: true`; none uses a settings block. They confirm the contract above and show the conventions that have grown around it.

### 9.1 Modules are written for a whole ecosystem, not just Sora

Their metadata carries keys `ModuleMetadata` doesn't declare:

```jsonc
"languageType": ["Dubbed", "Subbed"],
"downloadSupport": true,
"supportsSora": true, "supportsLuna": true, "supportsMojuru": true,
"supportsDartotsu": true, "supportsAnymex": true, "supportsTsumi": true,
"supportsHiyoku": true, "supportsShirox": true, "supportsEclipse": true
```

`JSONDecoder` ignores unknown keys, so these are harmless — include them if you publish to the shared index. The practical consequence is the important one: **a module that "works" may have been tested in a different host app.** That is where the `setTimeout` bug in §6 comes from, and why you should verify behavior in Sora's logger rather than trusting the module's provenance.

### 9.2 The `soraFetch` wrapper

The community idiom for network calls, verbatim from AnimeHeaven:

```js
async function soraFetch(url, options = { headers: {}, method: 'GET', body: null }) {
    try {
        return await fetchv2(url, options.headers ?? {}, options.method ?? 'GET', options.body ?? null);
    } catch (e) {
        try { return await fetch(url, options); }
        catch (error) { return null; }
    }
}
```

It gives module code an options-object call style and falls back to legacy `fetch` in hosts that lack `fetchv2`. Worth copying — but remember §6: `fetchv2` **resolves** with `{ error }` on network failure rather than throwing, so this `catch` only fires on argument errors. Check `res.status` yourself.

### 9.3 `href` is an opaque token, and rarely a plain URL

- **AnimeHeaven** returns the bare DOM element id as the episode `href`, then in `extractStreamUrl` sends it back as a cookie: `fetchv2('https://animeheaven.me/gate.php', { Cookie: \`key=${id}\` })`.
- **123Anime** returns a composite token — `` `${animeId}/${episodeNum}/vidstreaming.io` `` — and feeds it to an AJAX endpoint.
- **AnimePahe** returns a real URL built from two session UUIDs.

Whatever `extractEpisodes` puts in `href` is handed straight back to `extractStreamUrl`; encode whatever state you need. Same for `searchResults.href` → `extractDetails`/`extractEpisodes`.

### 9.4 All three return shapes appear in the wild

```js
// AnimeHeaven — bare string, no JSON at all. Valid: Swift falls through
// JSON parsing and treats the whole string as the stream URL.
return streamUrl;               // and returns "" when nothing is found

// 123Anime / AnimePahe — the named-servers object
return JSON.stringify({ streams: [
    { title: "1080p • Hardsub", streamUrl: hlsUrl,
      headers: { Referer: "https://kwik.cx/", Origin: "https://kwik.cx" } }
]});
```

**Order matters** — the `streams` array order is the row order in the "Select Server" sheet. AnimePahe sorts hardsub-before-dub, then descending resolution, so the best option lands first. Do the same; there is no ranking on the Swift side.

Likewise `extractEpisodes` output is displayed in array order. AnimeHeaven scrapes the page (which lists newest-first) and calls `episodes.reverse()`; AnimePahe asks its API for `sort=episode_asc`. Return ascending.

### 9.5 `subtitle` vs `subtitles` — a live bug worth not copying

AnimePahe returns `JSON.stringify({ streams: [...], subtitle: "" })`. **Sora never reads a top-level `subtitle` key.** It reads `subtitles` (plural) at the top level, or `subtitle` (singular) *inside* an individual source object. The top-level singular is silently dropped. Get this right:

```js
{ streams: [...], subtitles: "https://…/en.vtt" }        // ✅ top level, plural
{ streams: [{ streamUrl: "…", subtitle: "https://…/en.vtt" }] }  // ✅ per source, singular
{ streams: [...], subtitle: "https://…/en.vtt" }         // ❌ ignored
```

### 9.6 Failure convention: return a placeholder, never throw

Every hook in all three modules wraps its body in `try/catch` and returns a well-formed placeholder:

```js
catch (err) { return JSON.stringify([{ description: "Error", aliases: "Error", airdate: "Error" }]); }
catch (err) { return JSON.stringify([{ title: "Please wait a bit then try again!", image: "", href: "" }]); }
catch (err) { return "https://error.org/"; }
```

This is deliberate: a thrown exception surfaces as an empty screen with nothing but a log line, while a placeholder tells the user what happened. Note the type trap — 123Anime's episode fallback returns `{ href: "Error", number: "Error" }`, and in async mode `number` is cast `as? Int`, so `"Error"` silently becomes `0`.

### 9.7 Remote helpers do what the sandbox can't

Because the JSContext has no DOM and can't execute a page's own scripts, all three lean on Cloudflare Workers:

| Job | How |
|---|---|
| Solve DDoS-Guard / JS challenges | `…/solver?url=<encoded>&cache=1h` — AnimePahe's `DdosGuardInterceptor.fetchWithBypass` is now just a wrapper around this one call |
| Batch-render many player pages | `…/solver-fast` with `POST {urls: [...]}` → `{ htmls: [...] }` |
| Proxy referer-locked streams | 123Anime rewrites `streamUrl` to `…/?url=<encoded>&referer=<encoded>` |
| Proxy/cache poster images | AnimePahe wraps `result.poster` in an image worker |

`networkFetch` (§6) is the in-app alternative to the first two and needs no external service, at the cost of spinning up a `WKWebView`. Choose deliberately: a worker is faster and battery-cheap but is a third-party dependency your module dies without.

### 9.8 Deobfuscation is your problem

AnimePahe bundles its own `unpack()` and an `Unbaser` class (~85 lines) to undo `eval(function(p,a,c,k,e,d){…})` packing, and loops `deepUnpack` up to 5 times for nested layers. Nothing like this is built in. If a host packs its player config, ship the unpacker inside your module — top-level `class` and `function` declarations coexist fine with the hooks.

### 9.9 Watch the 15-second episode timeout when paginating

AnimePahe fetches page 1, reads `last_page`, then issues the rest concurrently with `Promise.all` and merges. That concurrency isn't a style choice — `extractEpisodes` is killed at 15 s in the async path (§5.3), and a long series fetched serially will not finish. Parallelize, and keep per-request retries cheap.

---

## 10. Checklist for a new video module

- [ ] Metadata JSON with all ten required fields, `author` object included
- [ ] `streamType` set to `HLS` or `MP4` so downloads pick the right path
- [ ] `baseUrl` set — it is the Referer/Origin fallback for playback
- [ ] `asyncJS` matches the implementation of all four hooks (it is all-or-nothing across them)
- [ ] `searchBaseUrl` contains `%s` (sync) — or accept that it's unused (async)
- [ ] `searchResults`, `extractDetails`, `extractEpisodes`, `extractStreamUrl` defined as top-level globals
- [ ] Async hooks `JSON.stringify` their return value; sync hooks never return a Promise
- [ ] `number` typed correctly for the chosen mode
- [ ] Stream headers returned per-source when the host checks Referer
- [ ] Episodes returned in ascending order; streams sorted best-first (both are displayed in array order)
- [ ] Subtitles under the **`subtitles`** key at top level, or `subtitle` inside a source — not top-level `subtitle`
- [ ] No `setTimeout`/`setInterval` anywhere, including error and retry paths
- [ ] Pagination parallelized so `extractEpisodes` finishes inside 15 s
- [ ] Every hook wrapped in `try/catch` returning a well-formed placeholder
- [ ] `version` bumped on every script change

For a novel module: set `"novel": true`, and implement `searchResults`, `extractDetails`, `extractChapters`, `extractText` (no `extractEpisodes`/`extractStreamUrl`).
