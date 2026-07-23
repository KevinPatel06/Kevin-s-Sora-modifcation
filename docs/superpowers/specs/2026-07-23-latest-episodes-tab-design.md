# Latest Episodes Tab — Design

**Date:** 2026-07-23
**Status:** Shipped and verified on device

> ## Amendment — what actually shipped
>
> The design below was superseded during implementation. It is kept for the
> reasoning trail; **the sections marked ~~struck~~ did not ship.**
>
> Two faults made the original design produce a permanently empty feed:
>
> 1. **The AniList query was invalid.** `airingAt_greater` / `airingAt_lesser`
>    are arguments of the top-level `Page.airingSchedules` query, not of the
>    nested `Media.airingSchedule` field. AniList rejected every request and
>    returned `data: null`, so no dated entry could ever be built. This
>    compiled cleanly and was invisible to CI.
> 2. **Watermark baselining silenced everything else.** Unmatched shows record
>    their episode count silently on first scan, so a first refresh emitted
>    nothing for them by design.
>
> **As shipped:**
>
> - **One row per library show, always shown** — no 7-day window, no watermark,
>   no filtering. A show appears even when no provider matched it; it simply
>   shows an episode number without a date.
> - **Watched rows dim to 45%** rather than being hidden, so the feed never
>   depends on watch state to have content.
> - **Dates** resolve via stored AniList id → the app's pre-existing
>   `custom_anilist_id_<href>` → fuzzy title search → TMDB. Shows older than
>   AniList's airing data fall back to the show's end date.
> - **Every bookmark is scraped each refresh**, not just recently-aired ones,
>   because dimming needs each episode's link. Scrapes are serialized and
>   bounded at 25s each, with incremental publishing and a progress counter.
>
> Verified on device 2026-07-23: correct episodes, correct sort order.

## Goal

Add a tab between Library and Downloads showing recently released episodes of shows already in the user's library, as a scrollable feed of thumbnail cards. An episode carries a NEW indicator until it is watched or marked as watched. The window is 7 days.

## Non-goals

- Browsing a source site's own "latest" page. The module format has no such capability (verified against the ecosystem spec `SORA_MODULES_GUIDE.md` and the 94-module index at `git.luna-app.eu/50n50/sources`, which define only `searchResults`, `extractDetails`, `extractEpisodes`, `extractStreamUrl` plus novel/manga variants). Adding a fifth hook would require forking and self-hosting every module's JavaScript, and would be overwritten by upstream module updates.
- Discovering shows the user has not bookmarked.
- Background refresh. Deferred; see "Deferred" below.
- Novel and manga chapters. Video episodes only in this iteration.

## Background: why the feed is library-derived

Modules report episodes as `{number, href}` only. No air date exists anywhere in the app — no field on `EpisodeLink`, no date in any module return shape. Release recency must therefore come from an external metadata provider, or be approximated locally.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Feed source | User's library bookmarks, across all modules | Works with all 94 existing modules with no module changes; survives upstream module updates |
| Module scoping | None — feed spans all modules | Follows from library-derived source |
| Recency, primary | AniList `airingSchedule` | Real per-episode air timestamps; best coverage for anime |
| Recency, fallback | TMDB air dates | Covers shows/movies AniList lacks |
| ~~Recency, no match~~ | ~~Local first-seen watermark~~ | **Did not ship.** Shows with no match now appear with an episode number and no date. |
| Refresh trigger | Pull-to-refresh only | No refresh on tab open; user controls when network work happens |
| ~~Refresh strategy~~ | ~~Providers first, scrape only what aired~~ | **Did not ship.** Every bookmark is scraped, because watched-dimming needs each episode link. |
| Match persistence | Side table, written at bookmark time | The ID is already resolved in `MediaInfoView`; persisting avoids repeated fuzzy title matching |
| Tap behavior | Opens `MediaInfoView` at that episode | Mirrors existing `LibraryView` interaction |
| Long-press | Play Now, Mark as Watched | Mirrors existing `LibraryView` context menu |

## Critical constraint: JS execution must be serialized

`JSController` is a singleton holding a single `JSContext`. `JSController.loadScript` discards and recreates that context on every call. Two concurrent module scrapes would clobber each other's context mid-parse and produce garbage or empty results.

All module scraping performed by this feature must therefore be serialized through an actor. This is acceptable only because the provider-first strategy reduces the number of scrapes per refresh to a handful. If the design ever reverts to scraping every bookmark, this constraint becomes a minute-long serial queue.

## Data model (see Amendment: watermarks removed, window removed)

Three new stores, all `UserDefaults`, consistent with the app's existing persistence idiom.

### Provider matches

Key: `providerMatch_<moduleId>_<showHref>`

```
{
  anilistId: Int?,
  tmdbId: Int?,
  tmdbType: "tv" | "movie",
  matchedAt: Date,
  source: "auto" | "manual"
}
```

- Written when a bookmark is created, using IDs `MediaInfoView` has already resolved for posters and tracking.
- Written with `source: "manual"` when the user picks a match in the existing `AnilistMatchView` or `TMDBMatchView`. **An automatic pass must never overwrite a `manual` entry.**
- Backfilled lazily during refresh for bookmarks predating this feature.
- Stored as a side table rather than as fields on `LibraryItem`, so the persisted collections blob is untouched and a match survives un-bookmarking and re-bookmarking.

### Feed cache

Key: `latestFeed`

```swift
struct LatestEpisodeEntry: Codable, Identifiable {
    let id: UUID
    let showTitle: String
    let imageUrl: String        // thumbnail
    let episodeNumber: Int
    let episodeHref: String     // token passed to playback
    let showHref: String        // opens MediaInfoView
    let moduleId: String
    let airDate: Date?          // nil renders as "recently"
    let discoveredAt: Date
}
```

Pruned to the 7-day window on load. The tab renders instantly and works offline from this cache.

### ~~First-seen watermarks~~ (did not ship)

Key: `latestSeen_<moduleId>_<showHref>` → highest episode number observed, plus timestamp.

Used only for shows matching neither provider. The first time a show is encountered its watermark is recorded **silently**, producing no feed entries, so a long-running series does not flood the feed with its back catalogue.

### Watched state — reuse, add nothing

The NEW indicator derives from existing keys `lastPlayedTime_<href>` and `totalTime_<href>`, hidden when the ratio is `>= 0.9` — the same threshold `LibraryView` uses. "Mark as Watched" already writes both keys to full duration, so it clears the indicator with no new code.

**Risk to verify on device:** `EpisodeCell` writes these keys using the episode href, while the players write them using `fullUrl`. These are believed to be the same string. If they are not, the NEW indicator will never clear. This must be confirmed early, as the failure is silent.

## Architecture

New files:

```
Sora/Views/LatestView/
  LatestView.swift          — tab screen, pull-to-refresh, empty and error states
  LatestFeedManager.swift   — ObservableObject; refresh orchestration, feed cache
  LatestEpisodeEntry.swift  — model
  LatestEpisodeCell.swift   — card

Sora/Tracking & Metadata/
  ProviderMatchStore.swift              — match side table; read, write, backfill
  AniList/AniListAiringSchedule.swift   — batched airing-schedule query
```

Modified:

- `Sora/Tracking & Metadata/TMDB/TMDB-FetchID.swift` — add air-date lookup
- `Sora/ContentView.swift` — insert tab at index 1; update `tabView(for:)` index mapping
- `Sora/Views/MediaInfoView/MediaInfoView.swift` — persist provider match on bookmark
- `Sora/Views/MediaInfoView/Matching/AnilistMatchView.swift`, `TMDBMatchView.swift` — persist manual matches
- `Sora/Localization/en.lproj` — `LatestTab` key
- `Sulfur.xcodeproj/project.pbxproj` — register all new files

## Refresh flow

Triggered only by pull-to-refresh.

1. Gather unique bookmarks from `LibraryManager.collections` as `(moduleId, showHref, title, imageUrl)`.
2. Partition into matched and unmatched using `ProviderMatchStore`.
3. Issue **one batched AniList GraphQL query** covering all AniList IDs, reading `airingSchedule` for the last 7 days.
4. For bookmarks with a TMDB ID but no AniList ID, query TMDB per show.
5. The result is a small set of `(show, episodeNumber, airDate)` that aired in the window.
6. **Scrape only those shows**, serially through the actor, to resolve each episode number to a real `episodeHref`.
7. **Unmatched shows** are also scraped serially, compared against their watermark; numbers above the watermark become undated entries. Watermarks are then updated.
8. Merge, sort by `airDate ?? discoveredAt` descending, persist, publish.

Provider failure degrades every show to the unmatched path rather than producing an empty tab.

### Edge cases

**Multiple episodes in the window.** A show that aired three episodes in 7 days produces **three cards**, one per episode, each with its own air date and NEW indicator. The feed is a list of episodes, not of shows.

**Provider ahead of module.** AniList frequently reports an episode as aired before the source site has uploaded it. When a matched show's scrape cannot find the reported episode number, **no card is emitted** — a card with no resolvable `episodeHref` would be untappable. The episode surfaces on a later refresh once the module lists it. The air date shown is always the provider's, so an episode that appears two days late still displays its true air date and its true position in the 7-day window.

**Episode numbering mismatch.** Provider numbering and module numbering can disagree, most commonly absolute versus per-season numbering for long-running anime. Matching is on episode number within the show, so a mismatch manifests as the previous case — no card — rather than as a wrong card. This is the intended failure direction: silence over incorrect links.

## UI

**Card:** thumbnail on the left; show title; secondary line `Episode 12 · 2 days ago`, or `Episode 4 · recently` when undated; NEW dot trailing, hidden once watched.

**Tap:** opens `MediaInfoView` for the show, at that episode.
**Long-press:** Play Now, Mark as Watched.

Both mirror `LibraryView`'s existing interaction model.

**Tab:** index 1, between Library and Downloads. Icon `sparkles`, consistent with the existing simple outline glyphs (`square.stack`, `arrow.down.circle`, `gearshape`, `magnifyingglass`).

Inserting at index 1 shifts Downloads, Settings, and Search up by one. `ContentView.tabView(for:)` switches on index and **must be updated in lockstep**, or tabs will render the wrong screens. Both the custom `TabBar` path and the iOS 26 native `TabView` path iterate the same `tabs` array and need no separate change.

A `LatestTab` localization key is added to `en.lproj`. The 19 other bundles fall back to English until translated.

## States

| State | Behavior |
|---|---|
| No bookmarks | Prompt to bookmark shows |
| Never refreshed | "Pull to refresh" |
| Refreshing | Progress indicator; cached feed stays visible |
| Provider outage | Non-blocking banner; feed still builds via the unmatched path |
| Module deleted | Entries dropped via the existing `.moduleRemoved` notification, matching how `LibraryManager` prunes bookmarks |
| Partial failure | Whatever succeeded is kept and shown |
| Empty after refresh | "No new episodes in the last 7 days" |

## Verification

There is no test target and no local compiler; development is on Windows without Xcode. Verification is CI build success plus manual device checks in LiveContainer:

1. Bookmark two currently-airing shows and one finished show. Pull to refresh. Only the airing shows appear, with plausible dates.
2. Watch one to completion. Its NEW indicator clears. **This confirms the watched-key risk above.**
3. Mark another as watched from the long-press menu. Indicator clears without playback.
4. Bookmark a show matching neither provider. It appears as "recently" after a second refresh, not on the first (watermark baseline).
5. Delete a module. Its cards disappear.
6. Airplane mode. Cached feed still renders.
7. Confirm Downloads, Settings, and Search still open their own screens after the tab index shift.

## Deferred

- **Background refresh.** `Info.plist` already declares `fetch` and `processing` background modes with a registered task identifier, so the hooks exist. Deferred because iOS grants background windows unpredictably, and LiveContainer's handling of background task registration is unverified. The provider-first strategy makes a manual refresh cheap enough that the payoff is small.
- **Novel and manga chapters.** Neither provider supplies chapter release dates; these would rely entirely on the watermark path.
- **Tab badge** showing unwatched count.
