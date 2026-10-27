# Running Sora modules in Shirox

Shirox (xibrox, `Shirox/` — extracted from `Shirox-latest.zip`, v1.0.6) loads the same module format as Sora:
a manifest plus a JS file with `searchResults` / `extractDetails` / `extractEpisodes` / `extractStreamUrl`.
But its JavaScriptCore bridge is its own implementation, not Sora's, and it differs in ways that break
modules written and tested against Sora. Everything below was checked against the Shirox source and then
reproduced with `tools/shirox-harness.js` (2026-10-26).

## How Shirox runs a module

- `Shirox/Services/JSEngine.swift` (the shared engine) and `ModuleJSRunner.swift` (short-lived per-module
  runners for downloads, sequel lookups, the module picker) each build a `JSContext` with: `console`,
  `btoa`/`atob`, `fetchv2`, `soraFetch`, `fetch`, `sendLog`, `_0xB4F2`, `setTimeout`/`setInterval`, the
  `getElementsByTag`/`getAttribute` helpers, and `networkFetch`/`networkFetchSimple` (WKWebView, same
  options as Sora's).
- The script is evaluated **once per module load**. Unlike Sora, globals persist between hooks.
- Every hook is called as `fn(arg)` and awaited if it returns a thenable (120 s timeout). The result is
  `JSValue.toString()`, then parsed as JSON (`JSEngine+Search/Details/Streams.swift`).
- `fetchv2` requests: Shirox UA (`Chrome/120` macOS) unless the module sets one, a cookie store, an
  adult-host blocklist (`Resources/adult_hosts.txt`), automatic Cloudflare Turnstile retry with cookies
  solved in a WebView, and optional DNS-over-HTTPS (Settings › Advanced Network › Secure DNS).
- Stremio/Nuvio/Vega/SkyStream/Mana/Seanime modules get an extra runtime (`ExtensionRuntime.js`,
  `SeanimeRuntime.js`) with Node-like shims. **Sora-format modules don't get it.**

## Where Shirox differs from Sora (the actual breakage)

| # | Area | Sora | Shirox | Effect on Sora modules |
|---|---|---|---|---|
| 1 | `asyncJS: false` / `streamAsyncJS: true` | Swift fetches the page and passes **HTML** | Ignored. Every hook gets the URL/keyword | Sync and hybrid modules get a URL where they expect HTML. In the xdfkenny library this hits only the Russian `streamAsyncJS` modules (anidub, aniliberty, onwave, yummyanime, sameband, shizaproject) |
| 2 | Per-stream subtitles `streams: [{streamUrl, subtitle}]` | Used | **Ignored** | Subtitles silently lost. Our `anikura` loses all 6 tracks |
| 3 | `subtitles: [url, …]` (array) | Used | **Ignored** (only a string `subtitle`/`subtitles` is read) | Lost. hydrahd drops 16 this way |
| 4 | `allSubtitles: [{url, label}]` | Ignored | The **only** multi-track path | Modules that emit it get many more tracks in Shirox (aether 1 → 138, animex 1 → 33) |
| 5 | `streams: ["Title", "url", …]` pairs | Pairs | Every string read as a URL | Titles become bogus "streams" |
| 6 | Top-level JSON array of URLs | Played | Parse error | No sources |
| 7 | `atob` | Strict, UTF-8, returns `null` on failure | Strict, UTF-8, returns **`""`** on failure | Binary payloads (ciphertext) decode to `""` with no exception, so a module's lenient fallback never runs. **This breaks `anikoto`** |
| 8 | `fetch(url, headers)` | Resolves to the **body string**. 2nd arg = headers | Resolves to a **response object**. Headers read from `options.headers` | Old-style `const html = await fetch(url, {Referer})` gets an object and loses the Referer |
| 9 | `res.text()` / `res.json()` | Return Promises | Return plain values. `json()` gives `undefined` on bad JSON | `await res.text()` works in both. `res.text().then(…)` throws in Shirox |
| 10 | `fetchv2` network error | Resolves `{ error }` | **Rejects** | Unguarded `await fetchv2()` throws in Shirox |
| 11 | `fetchv2` 5th arg | `redirect` flag | `impersonate`. `true` switches on a Safari profile (`Sec-Fetch-*`, `Accept: text/html`) | 14 library modules pass `true`. API calls get browser-navigation headers |
| 12 | `fetchv2` object body | `JSON.stringify`'d | `String(body)` = `"[object Object]"` | POSTs with object bodies break |
| 13 | Headers with a non-string value | Kept | **All headers dropped** (`as? [String: String]` fails) | Referer/UA silently gone |
| 14 | Default subtitle | First track | Top-level `subtitle`/`subtitles` string. Otherwise the **first** `allSubtitles` track, whatever its language | With many tracks and no top-level English string, the first track (often not English) is the one shown |
| 15 | `subtitlesHeaders` (plural) | n/a | Only `subtitleHeaders` is read | Default track loads without Referer, unless its URL is also in `allSubtitles` (then that track's headers win) |

Two more, found while fixing modules (2026-10-27):

- **Shirox's default User-Agent is `Chrome/120`**, and Cloudflare walls that exact UA on some sites (otakutsu answered 403 "Just a moment" to Chrome/120 and JSON to Chrome/124 or iOS Safari). A module should always send its own, current UA.
- **Stream tokens bound to the requesting User-Agent** (aether's Lul worker, likely Dailymotion): resolving a redirect in the module and handing the player the final URL gives a 403, because the player uses another UA. Hand the player the original URL, or pin the same `User-Agent` in the stream's `headers`.

Things that are **not** problems: `networkFetch` options match Sora's. The subtitle loader handles VTT,
SRT and ASS. MKV plays through the MPV engine. `_0xB4F2` exists. `setTimeout` exists (Sora has none).

## Results: English video modules from sora-modules.xdfke.me (52 run, sample query from the index)

Run from a home desktop. TLS fingerprints and Cloudflare scoring differ from an iPhone, so a site-side
failure here can still work on device, and the reverse.

**Works in Shirox (search → episodes → a stream that answers with HLS/MP4):**
anidb, 123anime, anikotosub, anikotodub, kisskh (EN .srt), onetouch (.vtt), animegg, imdb (EN .srt),
animex / animexdub (7 / 4 EN tracks via `allSubtitles`), animenosub, animeheaven, allmanga and
allmanga-shirox (intermittent: keygen rotates, rate limits), filmo, toontales, onepace, the fan-edit
modules (blackCloverPace, borucut, concentratedBleach, dbzRecut, narucannon, onigashima,
rebuildOfNaruto, yuYuHakushoPace).

**Works, but only with Secure DNS on:** hydrahd / hydrahd-shirox. `hydrahd.ws` is DNS-poisoned on this
network (system DNS → a dead IP, DoH → the real server). With DoH: 15 results, 558 eps, three 1080p HLS
streams, 9 subtitle tracks (8 EN) reaching the player.

**Broken only in Shirox:** anikoto (#7). Also our `anikura`: it plays, but every subtitle is lost (#2).
**Fixed 2026-10-27** in this repo's copies: anikoto, anikura, aether, animegg, vidrift (see `CLAUDE.md`).

**Broken in both apps (site or module, not Shirox):**

| Module | Why |
|---|---|
| ~~vidrift (ours)~~ | Fixed 2026-10-27: moved to VidRift's `orionStreams` |
| kissasian (ours) | kissasian.su is a bare API placeholder now; its player host dramavideo.se carries Indian TV only. Parked. Use KissKH |
| allmangasub, allmangadub | `fetchCreds` / encrypted episode query fails (allanime keygen moved). Use upstream `allmanga-shirox`: its sub stream works; its dub query right after gets rate-limited and the fallback host answers `AA_CRYPTO_WRONG_REFERER` |
| animedefenders, anibd | `eng.animeapps.top` says "the website has been stopped" |
| anineko | Origin down (Cloudflare 522) |
| animepahesub, animepahedub | Cloudflare "Just a moment". Shirox's Turnstile bypass *may* clear it on device |
| miruro | API 403 (Cloudflare). Also contacts a `supabase.co` tracker |
| videasy | API changed (`seed` undefined) |
| catflix | "HOSTER NOT FOUND" |
| anihq | Site wiped (fresh WordPress, "Hello world") |
| otakutsu | IDs changed (`al-21`), Chrome/120 is walled, and streams now need a bootstrap token + session cookie + a server action whose id changes per deploy, behind a browser "integrity check". IP-blocked after a dozen probes. Not worth chasing |
| otaku-streamers | Site up, module returns nothing. Module out of date |
| onepacedub | Crashes in `extractEpisodes`. Superseded by `onepace`, which handles Sub/Dub/CC itself |

**Unclear (stream URL answered 403 or an HTML page to the probe):** aether (subs fine), lmanime,
luciferdonghua, peachify, vidcore, xpass, vidfast, animeland (server sends an incomplete TLS chain, which
iOS may tolerate). Check these on device.

## Fixing it

### In a module (works in both apps)

- Emit subtitles three ways: a top-level English **string** `subtitles` (default track in both apps),
  `allSubtitles: [{url, title, headers}]` (Shirox's track menu), and per-stream `subtitle` (Sora).
- Always `await res.text()` / `await res.json()`. Never `.then` on them, and never treat `fetch()` as
  returning a string. Wrap responses like allmanga-shirox's `toResponseLike()`.
- `try/catch` around `fetchv2`, and check `res.status`. Pass header values as strings only.
  `JSON.stringify` bodies yourself. Don't pass a 5th arg to `fetchv2` unless you mean "impersonate"
  in Shirox.
- Don't use `atob` for binary data. Use a JS base64 → bytes decoder (anikoto already has one: call it
  directly).
- Return a JSON **object** from `extractStreamUrl`, with `streams` as objects (`{title, streamUrl, headers}`).

### In Shirox (if building it)

All in `Shirox/Services/JSEngine+Streams.swift` `parseStreamResults` and the two `setupBase64`s:

1. Read per-stream `subtitle`/`subtitles` (string or array) and top-level `subtitles` arrays (strings or
   objects) into `allSubtitles`. Accept `subtitlesHeaders` as an alias.
2. Pair up `streams: ["Title", "url", …]` the way Sora's `parseStreamInfo` does. Accept a top-level array.
3. `atob`: return the decoded bytes as a Latin-1 string (browser behaviour), not UTF-8 or `""`.
4. `PlayerView.loadSubtitles` fallback: prefer an English-looking `allSubtitles` track over `.first`.

## Re-running

```bash
node modules/tools/shirox-harness.js <module.js> --all "<query>"               # Shirox semantics
node modules/tools/shirox-harness.js <module.js> --all "<query>" --env sora    # Sora semantics, for comparison
```

It reports `ignoredSubs` (per-stream subtitles Shirox drops), `ignoredSubsArray`, `bogus` sources, and
flags for blocked hosts, dropped headers, object bodies and `atob` failures.
