# Latest Episodes Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Latest tab between Library and Downloads that shows recently released episodes of shows already in the user's library, as thumbnail cards with a NEW indicator that clears once watched.

**Architecture:** The feed is derived from library bookmarks, not from any module capability. A refresh asks AniList (then TMDB) which bookmarked shows aired in the last 7 days, then scrapes only those shows' modules to resolve playable episode links. Shows matching neither provider fall back to a local "highest episode number seen" watermark and display as "recently".

**Tech Stack:** SwiftUI, JavaScriptCore (via existing `JSController`), AniList GraphQL, TMDB REST, `UserDefaults` persistence, NukeUI `LazyImage`.

**Spec:** `docs/superpowers/specs/2026-07-23-latest-episodes-tab-design.md`

---

## ⚠️ Verification model — read before starting

**This project has no test target, no test framework, and no local compiler.** Development is on Windows without Xcode. You cannot build, run, or test locally. Standard TDD red-green cycles are not available.

Each task therefore ends with:

1. **Self-review against the checklist in that task** — the substitute for a compiler.
2. **A commit.**
3. **A CI build** — the only real compile check. Push and watch:
   ```bash
   git push -u origin feature/latest-episodes-tab
   gh run watch --exit-status
   ```
4. **Device checks**, batched at the end (Task 9).

Do not proceed to the next task while CI is red. A broken build compounds — three tasks of drift is far harder to diagnose than one.

Adding an XCTest target would enable real unit tests for the pure-logic pieces (date windowing, watermark diffing, response parsing) and is worth doing eventually, but hand-authoring a test target into `project.pbxproj` without Xcode is error-prone and unverifiable locally. Treated as follow-up work, not part of this plan.

## Global Constraints

- **Deployment target:** iOS 15.0. No API newer than iOS 15 without an `if #available` guard.
- **Swift version:** 5.0 (`SWIFT_VERSION = 5.0`).
- **Every new file must be registered in `Sulfur.xcodeproj/project.pbxproj`** — `PBXFileReference`, `PBXBuildFile`, the enclosing `PBXGroup` children array, and the `Sulfur` target's `PBXSourcesBuildPhase`. The project uses classic `objectVersion = 55` groups; there are no synchronized folders. **An unregistered file silently does not compile.**
- **Never rename** the `Sulfur` target/scheme, the `Sora/` folder, or the `sora://` URL scheme.
- **Module JS execution must be serialized.** `JSController` is a singleton whose `loadScript` destroys and rebuilds its single `JSContext`. Concurrent scrapes corrupt each other. All scraping in this feature goes through `ModuleEpisodeScraper` (Task 4).
- **Logging:** `Logger.shared.log(_:type:)`. Use type `"Latest"` for this feature. Never `print`.
- **Networking:** `URLSession.custom` (carries the app's rotating User-Agent). Do not use `URLSession.shared` for scraping traffic.
- **Indentation:** 4 spaces. Each file opens with the standard Xcode header comment block.
- **Branch:** `feature/latest-episodes-tab`, already created.

## File Structure

**Create:**

| Path | Responsibility |
|---|---|
| `Sora/Utlis & Misc/Models/ProviderMatchStore.swift` | Persist and read AniList/TMDB IDs per bookmark |
| `Sora/Tracking & Metadata/AniList/AniListAiringSchedule.swift` | Batched airing-schedule GraphQL query |
| `Sora/Tracking & Metadata/TMDB/TMDB-AirDates.swift` | TMDB air-date lookup fallback |
| `Sora/Views/LatestView/LatestEpisodeEntry.swift` | Feed entry model, watched derivation, feed cache |
| `Sora/Views/LatestView/ModuleEpisodeScraper.swift` | Actor serializing all module scraping |
| `Sora/Views/LatestView/LatestFeedManager.swift` | Refresh orchestration, published feed state |
| `Sora/Views/LatestView/LatestEpisodeCell.swift` | Single feed card |
| `Sora/Views/LatestView/LatestView.swift` | Tab screen, pull-to-refresh, empty/error states |

**Modify:**

| Path | Change |
|---|---|
| `Sora/Views/MediaInfoView/MediaInfoView.swift:1060` | Persist provider match on bookmark; persist manual matches |
| `Sora/ContentView.swift:29-43` | Insert tab at index 1; remap `tabView(for:)` |
| `Sora/SoraApp.swift:11-39` | Create and inject `LatestFeedManager` |
| `Sora/Localization/en.lproj/Localizable.strings:394` | Add `LatestTab` |
| `Sulfur.xcodeproj/project.pbxproj` | Register all eight new files |

---

## Task 1: Provider match store

Persists which AniList/TMDB entry a bookmark corresponds to, so refreshes never re-run fuzzy title matching.

**Files:**
- Create: `Sora/Utlis & Misc/Models/ProviderMatchStore.swift`
- Modify: `Sora/Views/MediaInfoView/MediaInfoView.swift:1060-1068`
- Modify: `Sulfur.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `TMDBFetcher.MediaType` (existing, `Sora/Tracking & Metadata/TMDB/TMDB-FetchID.swift:10`)
- Produces: `ProviderMatch` struct; `ProviderMatchStore.shared` with `match(moduleId:showHref:) -> ProviderMatch?`, `save(_:moduleId:showHref:)`, `saveIfAbsent(_:moduleId:showHref:)`

- [ ] **Step 1: Create the store**

Create `Sora/Utlis & Misc/Models/ProviderMatchStore.swift`:

```swift
//
//  ProviderMatchStore.swift
//  Sulfur
//

import Foundation

struct ProviderMatch: Codable {
    enum Source: String, Codable {
        case auto
        case manual
    }

    let anilistId: Int?
    let tmdbId: Int?
    let tmdbType: String?      // "tv" or "movie"; String for Codable stability
    let matchedAt: Date
    let source: Source

    var hasAnyProvider: Bool {
        anilistId != nil || tmdbId != nil
    }
}

/// Stores which AniList/TMDB entry a bookmarked show corresponds to.
///
/// Kept as a side table keyed by module + show href rather than as fields on
/// `LibraryItem`, so the persisted collections blob is untouched and a match
/// survives un-bookmarking and re-bookmarking.
final class ProviderMatchStore {
    static let shared = ProviderMatchStore()

    private let defaults = UserDefaults.standard

    private init() {}

    private func key(moduleId: String, showHref: String) -> String {
        "providerMatch_\(moduleId)_\(showHref)"
    }

    func match(moduleId: String, showHref: String) -> ProviderMatch? {
        guard let data = defaults.data(forKey: key(moduleId: moduleId, showHref: showHref)) else {
            return nil
        }
        return try? JSONDecoder().decode(ProviderMatch.self, from: data)
    }

    func save(_ match: ProviderMatch, moduleId: String, showHref: String) {
        guard let data = try? JSONEncoder().encode(match) else {
            Logger.shared.log("Failed to encode provider match", type: "Error")
            return
        }
        defaults.set(data, forKey: key(moduleId: moduleId, showHref: showHref))
        Logger.shared.log(
            "Saved provider match (\(match.source.rawValue)) anilist=\(match.anilistId.map(String.init) ?? "-") tmdb=\(match.tmdbId.map(String.init) ?? "-")",
            type: "Latest"
        )
    }

    /// Writes only when no match exists, or when the existing match was automatic.
    /// A manual match is never overwritten by an automatic one.
    func saveIfAbsent(_ match: ProviderMatch, moduleId: String, showHref: String) {
        if let existing = self.match(moduleId: moduleId, showHref: showHref),
           existing.source == .manual {
            return
        }
        save(match, moduleId: moduleId, showHref: showHref)
    }

    func remove(moduleId: String, showHref: String) {
        defaults.removeObject(forKey: key(moduleId: moduleId, showHref: showHref))
    }
}
```

- [ ] **Step 2: Persist the match when bookmarking**

In `Sora/Views/MediaInfoView/MediaInfoView.swift`, replace `toggleBookmark()` (currently lines 1060-1068) with:

```swift
    private func toggleBookmark() {
        let wasBookmarked = libraryManager.isBookmarked(href: href, moduleName: module.metadata.sourceName)

        libraryManager.toggleBookmark(
            title: title,
            imageUrl: imageUrl,
            href: href,
            moduleId: module.id.uuidString,
            moduleName: module.metadata.sourceName
        )

        // Capture the provider IDs this screen already resolved, so the Latest
        // tab never has to re-run fuzzy title matching for this show.
        if !wasBookmarked, itemID != nil || tmdbID != nil {
            let match = ProviderMatch(
                anilistId: itemID,
                tmdbId: tmdbID,
                tmdbType: tmdbType?.rawValue,
                matchedAt: Date(),
                source: .auto
            )
            ProviderMatchStore.shared.saveIfAbsent(
                match,
                moduleId: module.id.uuidString,
                showHref: href
            )
        }
    }
```

- [ ] **Step 3: Persist manual matches**

Find where `MediaInfoView` presents `AnilistMatchView` and `TMDBMatchView` and handles their `onSelect` closures.

`AnilistMatchView.onSelect` has signature `(Int, String, Int?) -> Void` — `(id, title, malId)`.
`TMDBMatchView.onSelect` has signature `(Int, TMDBFetcher.MediaType, String) -> Void` — `(id, mediaType, title)`.

Inside the AniList `onSelect` body, after the existing assignment to `itemID`, add:

```swift
                ProviderMatchStore.shared.save(
                    ProviderMatch(
                        anilistId: id,
                        tmdbId: tmdbID,
                        tmdbType: tmdbType?.rawValue,
                        matchedAt: Date(),
                        source: .manual
                    ),
                    moduleId: module.id.uuidString,
                    showHref: href
                )
```

Inside the TMDB `onSelect` body, after the existing assignments to `tmdbID` and `tmdbType`, add:

```swift
                ProviderMatchStore.shared.save(
                    ProviderMatch(
                        anilistId: itemID,
                        tmdbId: id,
                        tmdbType: mediaType.rawValue,
                        matchedAt: Date(),
                        source: .manual
                    ),
                    moduleId: module.id.uuidString,
                    showHref: href
                )
```

Use `save`, not `saveIfAbsent` — a manual correction must always win.

If the closure parameter names differ from `id` / `mediaType`, use whatever the existing closure binds. Do not rename existing parameters.

- [ ] **Step 4: Register the file in the Xcode project**

In `Sulfur.xcodeproj/project.pbxproj`, add four entries for `ProviderMatchStore.swift`. Copy the exact formatting of a neighbouring Swift file (e.g. `TMDB-FetchID.swift`) and generate fresh 24-character uppercase hex IDs that appear nowhere else in the file.

1. `PBXBuildFile` section: `<BUILD_ID> /* ProviderMatchStore.swift in Sources */ = {isa = PBXBuildFile; fileRef = <FILE_ID> /* ProviderMatchStore.swift */; };`
2. `PBXFileReference` section: `<FILE_ID> /* ProviderMatchStore.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProviderMatchStore.swift; sourceTree = "<group>"; };`
3. The `Models` `PBXGroup` `children` array: `<FILE_ID> /* ProviderMatchStore.swift */,`
4. The `Sulfur` target's `PBXSourcesBuildPhase` `files` array: `<BUILD_ID> /* ProviderMatchStore.swift in Sources */,`

- [ ] **Step 5: Self-review**

- `ProviderMatchStore.swift` compiles against iOS 15 APIs only — yes, `Codable`/`UserDefaults` only.
- `tmdbType` is stored as `String`, not `TMDBFetcher.MediaType`, so the enum staying non-`Codable` cannot break decoding.
- Both `onSelect` bodies still perform their original work; the store call is additive.
- All four pbxproj entries added, IDs unique.
- No `print` calls.

- [ ] **Step 6: Commit and verify CI**

```bash
git add "Sora/Utlis & Misc/Models/ProviderMatchStore.swift" \
        "Sora/Views/MediaInfoView/MediaInfoView.swift" \
        Sulfur.xcodeproj/project.pbxproj
git commit -m "Add provider match store, persisted at bookmark time"
git push -u origin feature/latest-episodes-tab
gh run watch --exit-status
```

Expected: CI green. If it fails with "cannot find ProviderMatchStore in scope", the pbxproj registration is wrong — recheck all four entries.

---

## Task 2: AniList airing schedule query

One batched GraphQL call answering "which of these AniList IDs aired an episode in the last 7 days?"

**Files:**
- Create: `Sora/Tracking & Metadata/AniList/AniListAiringSchedule.swift`
- Modify: `Sulfur.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `AiredEpisode` struct (`anilistId: Int`, `episodeNumber: Int`, `airDate: Date`); `AniListAiringSchedule.fetchRecentlyAired(anilistIds:since:completion:)`

- [ ] **Step 1: Create the query**

AniList's `Page.media` accepts `id_in` for batching, and each `Media` exposes `airingSchedule` whose nodes carry `episode` and `airingAt` (a Unix timestamp). Alias-free batching keeps the payload small and stays within AniList's rate limits.

Create `Sora/Tracking & Metadata/AniList/AniListAiringSchedule.swift`:

```swift
//
//  AniListAiringSchedule.swift
//  Sulfur
//

import Foundation

struct AiredEpisode {
    let anilistId: Int
    let episodeNumber: Int
    let airDate: Date
}

/// Batched lookup of which AniList entries aired an episode inside a time window.
enum AniListAiringSchedule {
    private static let endpoint = URL(string: "https://graphql.anilist.co")!

    /// AniList caps `perPage` at 50, so IDs are queried in chunks.
    private static let pageSize = 50

    static func fetchRecentlyAired(
        anilistIds: [Int],
        since: Date,
        completion: @escaping ([AiredEpisode]) -> Void
    ) {
        guard !anilistIds.isEmpty else {
            completion([])
            return
        }

        let chunks = stride(from: 0, to: anilistIds.count, by: pageSize).map {
            Array(anilistIds[$0..<min($0 + pageSize, anilistIds.count)])
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [AiredEpisode] = []

        for chunk in chunks {
            group.enter()
            fetchChunk(ids: chunk, since: since) { episodes in
                lock.lock()
                collected.append(contentsOf: episodes)
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(collected)
        }
    }

    private static func fetchChunk(
        ids: [Int],
        since: Date,
        completion: @escaping ([AiredEpisode]) -> Void
    ) {
        let sinceUnix = Int(since.timeIntervalSince1970)
        let nowUnix = Int(Date().timeIntervalSince1970)

        let query = """
        query ($ids: [Int], $perPage: Int, $since: Int, $until: Int) {
          Page(page: 1, perPage: $perPage) {
            media(id_in: $ids, type: ANIME) {
              id
              airingSchedule(airingAt_greater: $since, airingAt_lesser: $until) {
                nodes {
                  episode
                  airingAt
                }
              }
            }
          }
        }
        """

        let variables: [String: Any] = [
            "ids": ids,
            "perPage": ids.count,
            "since": sinceUnix,
            "until": nowUnix
        ]

        guard let body = try? JSONSerialization.data(
            withJSONObject: ["query": query, "variables": variables]
        ) else {
            Logger.shared.log("Failed to encode AniList airing query", type: "Error")
            completion([])
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        URLSession.custom.dataTask(with: request) { data, _, error in
            if let error = error {
                Logger.shared.log("AniList airing query failed: \(error.localizedDescription)", type: "Error")
                completion([])
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataDict = json["data"] as? [String: Any],
                  let page = dataDict["Page"] as? [String: Any],
                  let mediaList = page["media"] as? [[String: Any]] else {
                Logger.shared.log("Malformed AniList airing response", type: "Error")
                completion([])
                return
            }

            var results: [AiredEpisode] = []
            for media in mediaList {
                guard let mediaId = media["id"] as? Int,
                      let schedule = media["airingSchedule"] as? [String: Any],
                      let nodes = schedule["nodes"] as? [[String: Any]] else {
                    continue
                }
                for node in nodes {
                    guard let episode = node["episode"] as? Int,
                          let airingAt = node["airingAt"] as? Int else {
                        continue
                    }
                    results.append(
                        AiredEpisode(
                            anilistId: mediaId,
                            episodeNumber: episode,
                            airDate: Date(timeIntervalSince1970: TimeInterval(airingAt))
                        )
                    )
                }
            }

            Logger.shared.log("AniList reported \(results.count) aired episodes for \(ids.count) shows", type: "Latest")
            completion(results)
        }.resume()
    }
}
```

- [ ] **Step 2: Register in the Xcode project**

Add the same four pbxproj entries as Task 1 Step 4, with fresh unique IDs, placing the file reference in the AniList `PBXGroup` alongside `Anilist-Login.swift`.

- [ ] **Step 3: Self-review**

- `airingAt_greater` / `airingAt_lesser` are exclusive bounds — acceptable, a one-second edge is irrelevant for a 7-day window.
- Chunking respects AniList's 50-item `perPage` cap.
- `NSLock` guards `collected` because chunk callbacks arrive on arbitrary queues.
- Failure of one chunk yields `[]` for that chunk, not a crash — partial results still surface.
- Completion fires on `.main`.
- Uses `URLSession.custom`.

- [ ] **Step 4: Commit and verify CI**

```bash
git add "Sora/Tracking & Metadata/AniList/AniListAiringSchedule.swift" Sulfur.xcodeproj/project.pbxproj
git commit -m "Add batched AniList airing schedule query"
git push && gh run watch --exit-status
```

---

## Task 3: TMDB air-date fallback

For bookmarks with a TMDB ID but no AniList ID.

**Files:**
- Create: `Sora/Tracking & Metadata/TMDB/TMDB-AirDates.swift`
- Modify: `Sulfur.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `TMDBFetcher.apiKey` (existing, internal, `TMDB-FetchID.swift:24`)
- Produces: `TMDBAirDates.fetchRecentlyAired(tmdbId:mediaType:since:completion:)` returning `[(episodeNumber: Int, airDate: Date)]`

- [ ] **Step 1: Create the lookup**

TMDB exposes `last_episode_to_air` on a TV detail response, which covers the common case without walking every season.

Create `Sora/Tracking & Metadata/TMDB/TMDB-AirDates.swift`:

```swift
//
//  TMDB-AirDates.swift
//  Sulfur
//

import Foundation

/// Air-date lookup used as a fallback when a show has no AniList match.
enum TMDBAirDates {
    static func fetchRecentlyAired(
        tmdbId: Int,
        mediaType: String,
        since: Date,
        completion: @escaping ([(episodeNumber: Int, airDate: Date)]) -> Void
    ) {
        // Movies have no episodes.
        guard mediaType == "tv" else {
            completion([])
            return
        }

        let apiKey = TMDBFetcher().apiKey
        guard let url = URL(string: "https://api.themoviedb.org/3/tv/\(tmdbId)?api_key=\(apiKey)") else {
            completion([])
            return
        }

        URLSession.custom.dataTask(with: url) { data, _, error in
            if let error = error {
                Logger.shared.log("TMDB air-date lookup failed: \(error.localizedDescription)", type: "Error")
                completion([])
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let last = json["last_episode_to_air"] as? [String: Any],
                  let episodeNumber = last["episode_number"] as? Int,
                  let airDateString = last["air_date"] as? String else {
                completion([])
                return
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.locale = Locale(identifier: "en_US_POSIX")

            guard let airDate = formatter.date(from: airDateString), airDate >= since else {
                completion([])
                return
            }

            Logger.shared.log("TMDB reports tv/\(tmdbId) episode \(episodeNumber) aired \(airDateString)", type: "Latest")
            completion([(episodeNumber: episodeNumber, airDate: airDate)])
        }.resume()
    }
}
```

- [ ] **Step 2: Register in the Xcode project**

Four pbxproj entries, fresh IDs, in the TMDB `PBXGroup` alongside `TMDB-FetchID.swift`.

- [ ] **Step 3: Self-review**

- `en_US_POSIX` locale and fixed UTC timezone — required for `yyyy-MM-dd` parsing to be device-locale independent.
- Movies short-circuit to `[]`.
- Returns at most one episode; this is a deliberate simplification since it is only a fallback for non-anime.
- Completion is *not* forced onto `.main` here — `LatestFeedManager` (Task 6) is responsible for hopping to main before publishing.

- [ ] **Step 4: Commit and verify CI**

```bash
git add "Sora/Tracking & Metadata/TMDB/TMDB-AirDates.swift" Sulfur.xcodeproj/project.pbxproj
git commit -m "Add TMDB air-date fallback lookup"
git push && gh run watch --exit-status
```

---

## Task 4: Serialized module scraper

**The most important correctness constraint in this feature.** `JSController.loadScript` destroys and rebuilds the shared `JSContext`; concurrent scrapes corrupt each other.

**Files:**
- Create: `Sora/Views/LatestView/ModuleEpisodeScraper.swift`
- Modify: `Sulfur.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ModuleManager`, `JSController.shared`, `ScrapingModule`, `EpisodeLink` (all existing)
- Produces: `actor ModuleEpisodeScraper` with `static let shared`, and `func episodes(for module: ScrapingModule, showHref: String) async -> [EpisodeLink]`

- [ ] **Step 1: Create the actor**

```swift
//
//  ModuleEpisodeScraper.swift
//  Sulfur
//

import Foundation

/// Serializes all module scraping performed by the Latest tab.
///
/// `JSController` holds a single `JSContext` that `loadScript` destroys and
/// rebuilds on every call. Two concurrent scrapes would clobber each other's
/// context mid-parse, so every scrape in this feature funnels through here.
actor ModuleEpisodeScraper {
    static let shared = ModuleEpisodeScraper()

    private init() {}

    /// Loads the module's script and returns its episode list for a show.
    /// Returns an empty array on any failure; callers treat that as "nothing new".
    func episodes(for module: ScrapingModule, showHref: String) async -> [EpisodeLink] {
        let jsContent: String
        do {
            jsContent = try await MainActor.run {
                try ModuleManager.shared.getModuleContent(module)
            }
        } catch {
            Logger.shared.log(
                "Latest: failed to read module \(module.metadata.sourceName): \(error.localizedDescription)",
                type: "Error"
            )
            return []
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                JSController.shared.loadScript(jsContent)

                var didResume = false
                let resumeOnce: ([EpisodeLink]) -> Void = { episodes in
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: episodes)
                }

                if module.metadata.asyncJS == true {
                    JSController.shared.fetchDetailsJS(url: showHref) { _, episodes in
                        resumeOnce(episodes)
                    }
                } else {
                    JSController.shared.fetchDetails(url: showHref) { _, episodes in
                        resumeOnce(episodes)
                    }
                }
            }
        }
    }
}
```

**Why `resumeOnce`:** `fetchDetailsJS` guards against double-completion internally, but it also has a 15-second timeout path. Resuming a continuation twice is a hard crash in Swift, so the guard is mandatory defence.

**Why `ModuleManager.shared`:** `ModuleManager` is `@MainActor`, hence the `MainActor.run` hop. Do not construct `ModuleManager()` — that re-reads `modules.json` from disk on every call, a pattern that already exists in `JSController-Novel.swift` and should not be copied.

- [ ] **Step 2: Register in the Xcode project**

Four pbxproj entries. This is the first file in `Sora/Views/LatestView/`, so you must also create a **new `PBXGroup`** named `LatestView` with `path = LatestView; sourceTree = "<group>";` and add that group's ID to the `Views` group's `children` array. Copy the structure of the existing `SearchView` group exactly.

- [ ] **Step 3: Self-review**

- The actor is the only place this feature calls `loadScript`.
- Continuation resumes exactly once on every path, including timeout.
- `ModuleManager.shared` is used, not a fresh instance.
- `LatestView` group created and attached to `Views`.
- Uses existing `fetchDetails` / `fetchDetailsJS`; no new JS hook is introduced.

- [ ] **Step 4: Commit and verify CI**

```bash
git add Sora/Views/LatestView/ModuleEpisodeScraper.swift Sulfur.xcodeproj/project.pbxproj
git commit -m "Add serialized module episode scraper actor"
git push && gh run watch --exit-status
```

---

## Task 5: Feed entry model, watched state, and cache

**Files:**
- Create: `Sora/Views/LatestView/LatestEpisodeEntry.swift`
- Modify: `Sulfur.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `LatestEpisodeEntry` (`Codable`, `Identifiable`) with `isWatched`, `displayDate`; `LatestFeedCache` with `load()`, `save(_:)`; `LatestSeenStore` with `lastSeenNumber(...)`, `record(...)`

- [ ] **Step 1: Create the model and stores**

```swift
//
//  LatestEpisodeEntry.swift
//  Sulfur
//

import Foundation

struct LatestEpisodeEntry: Codable, Identifiable {
    let id: UUID
    let showTitle: String
    let imageUrl: String
    let episodeNumber: Int
    let episodeHref: String
    let showHref: String
    let moduleId: String
    let airDate: Date?
    let discoveredAt: Date

    init(
        id: UUID = UUID(),
        showTitle: String,
        imageUrl: String,
        episodeNumber: Int,
        episodeHref: String,
        showHref: String,
        moduleId: String,
        airDate: Date?,
        discoveredAt: Date = Date()
    ) {
        self.id = id
        self.showTitle = showTitle
        self.imageUrl = imageUrl
        self.episodeNumber = episodeNumber
        self.episodeHref = episodeHref
        self.showHref = showHref
        self.moduleId = moduleId
        self.airDate = airDate
        self.discoveredAt = discoveredAt
    }

    /// Used for sorting and for the 7-day window.
    var effectiveDate: Date { airDate ?? discoveredAt }

    /// Derived from the same UserDefaults keys the episode list and players
    /// already write, so "Mark as Watched" clears the NEW dot for free.
    /// Threshold matches `LibraryView`'s existing 0.9.
    var isWatched: Bool {
        let last = UserDefaults.standard.double(forKey: "lastPlayedTime_\(episodeHref)")
        let total = UserDefaults.standard.double(forKey: "totalTime_\(episodeHref)")
        guard total > 0 else { return false }
        return (last / total) >= 0.9
    }
}

/// Persists the last built feed so the tab renders instantly and works offline.
enum LatestFeedCache {
    private static let key = "latestFeed"
    static let windowDays = 7

    static func load() -> [LatestEpisodeEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([LatestEpisodeEntry].self, from: data) else {
            return []
        }
        return prune(entries)
    }

    static func save(_ entries: [LatestEpisodeEntry]) {
        let pruned = prune(entries)
        guard let data = try? JSONEncoder().encode(pruned) else {
            Logger.shared.log("Failed to encode latest feed", type: "Error")
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func prune(_ entries: [LatestEpisodeEntry]) -> [LatestEpisodeEntry] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: Date()) else {
            return entries
        }
        return entries
            .filter { $0.effectiveDate >= cutoff }
            .sorted { $0.effectiveDate > $1.effectiveDate }
    }

    static func removeEntries(moduleId: String) {
        save(load().filter { $0.moduleId != moduleId })
    }
}

/// Highest episode number seen per show. Only used for shows matching no provider.
enum LatestSeenStore {
    private static func key(moduleId: String, showHref: String) -> String {
        "latestSeen_\(moduleId)_\(showHref)"
    }

    /// `nil` means this show has never been scanned, so the caller must
    /// baseline it silently instead of emitting its whole back catalogue.
    static func lastSeenNumber(moduleId: String, showHref: String) -> Int? {
        let dict = UserDefaults.standard.dictionary(forKey: key(moduleId: moduleId, showHref: showHref))
        return dict?["lastNumber"] as? Int
    }

    static func record(moduleId: String, showHref: String, highestNumber: Int) {
        UserDefaults.standard.set(
            ["lastNumber": highestNumber, "checkedAt": Date().timeIntervalSince1970],
            forKey: key(moduleId: moduleId, showHref: showHref)
        )
    }
}
```

- [ ] **Step 2: Register in the Xcode project**

Four pbxproj entries in the `LatestView` group created in Task 4.

- [ ] **Step 3: Self-review**

- `isWatched` reads `lastPlayedTime_<episodeHref>` — the same key `MediaInfoView:1072` and `EpisodeCell:544` write.
- `prune` both filters and sorts, so callers get a canonical ordering.
- `lastSeenNumber` returns `Optional` specifically to distinguish "never scanned" from "scanned, highest was 0".
- Custom `init` with defaults is required because a memberwise initialiser is not synthesised alongside `Codable` conformance when defaults are wanted.

- [ ] **Step 4: Commit and verify CI**

```bash
git add Sora/Views/LatestView/LatestEpisodeEntry.swift Sulfur.xcodeproj/project.pbxproj
git commit -m "Add latest feed model, cache, and seen-episode watermarks"
git push && gh run watch --exit-status
```

---

## Task 6: Feed manager

Orchestrates the provider-first refresh.

**Files:**
- Create: `Sora/Views/LatestView/LatestFeedManager.swift`
- Modify: `Sulfur.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: everything from Tasks 1-5, plus `LibraryManager`, `ModuleManager`
- Produces: `@MainActor final class LatestFeedManager: ObservableObject` with `@Published var entries`, `@Published var isRefreshing`, `@Published var providerFailed`, `@Published var hasEverRefreshed`, and `func refresh() async`

- [ ] **Step 1: Create the manager**

```swift
//
//  LatestFeedManager.swift
//  Sulfur
//

import Foundation
import SwiftUI

@MainActor
final class LatestFeedManager: ObservableObject {
    @Published var entries: [LatestEpisodeEntry] = []
    @Published var isRefreshing = false
    @Published var providerFailed = false
    @Published var hasEverRefreshed = false

    private let matchStore = ProviderMatchStore.shared

    init() {
        entries = LatestFeedCache.load()
        hasEverRefreshed = UserDefaults.standard.bool(forKey: "latestHasEverRefreshed")

        NotificationCenter.default.addObserver(
            forName: .moduleRemoved,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let moduleId = note.object as? String else { return }
            Task { @MainActor in
                LatestFeedCache.removeEntries(moduleId: moduleId)
                self?.entries = LatestFeedCache.load()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private struct Bookmark {
        let moduleId: String
        let showHref: String
        let title: String
        let imageUrl: String
    }

    func refresh(libraryManager: LibraryManager, moduleManager: ModuleManager) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        providerFailed = false
        defer {
            isRefreshing = false
            hasEverRefreshed = true
            UserDefaults.standard.set(true, forKey: "latestHasEverRefreshed")
        }

        let bookmarks = uniqueBookmarks(from: libraryManager)
        guard !bookmarks.isEmpty else {
            entries = []
            LatestFeedCache.save([])
            return
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -LatestFeedCache.windowDays, to: Date()) ?? Date()

        var matched: [Bookmark] = []
        var unmatched: [Bookmark] = []
        var anilistIdToBookmark: [Int: Bookmark] = [:]

        for bookmark in bookmarks {
            guard let match = matchStore.match(moduleId: bookmark.moduleId, showHref: bookmark.showHref),
                  match.hasAnyProvider else {
                unmatched.append(bookmark)
                continue
            }
            matched.append(bookmark)
            if let anilistId = match.anilistId {
                anilistIdToBookmark[anilistId] = bookmark
            }
        }

        var pending: [(bookmark: Bookmark, episodeNumber: Int, airDate: Date)] = []

        // AniList, batched.
        if !anilistIdToBookmark.isEmpty {
            let aired = await withCheckedContinuation { continuation in
                AniListAiringSchedule.fetchRecentlyAired(
                    anilistIds: Array(anilistIdToBookmark.keys),
                    since: cutoff
                ) { continuation.resume(returning: $0) }
            }
            if aired.isEmpty && !anilistIdToBookmark.isEmpty {
                Logger.shared.log("AniList returned no aired episodes", type: "Latest")
            }
            for episode in aired {
                guard let bookmark = anilistIdToBookmark[episode.anilistId] else { continue }
                pending.append((bookmark, episode.episodeNumber, episode.airDate))
            }
        }

        // TMDB fallback for matched shows with no AniList id.
        for bookmark in matched {
            guard let match = matchStore.match(moduleId: bookmark.moduleId, showHref: bookmark.showHref),
                  match.anilistId == nil,
                  let tmdbId = match.tmdbId else { continue }
            let aired = await withCheckedContinuation { continuation in
                TMDBAirDates.fetchRecentlyAired(
                    tmdbId: tmdbId,
                    mediaType: match.tmdbType ?? "tv",
                    since: cutoff
                ) { continuation.resume(returning: $0) }
            }
            for episode in aired {
                pending.append((bookmark, episode.episodeNumber, episode.airDate))
            }
        }

        var built: [LatestEpisodeEntry] = []

        // Resolve dated episodes to playable hrefs. Serialized by the actor.
        for item in pending {
            guard let module = moduleManager.modules.first(where: { $0.id.uuidString == item.bookmark.moduleId }) else {
                continue
            }
            let episodes = await ModuleEpisodeScraper.shared.episodes(
                for: module,
                showHref: item.bookmark.showHref
            )
            // Provider is often ahead of the source site. If the module does not
            // list the episode yet, emit nothing rather than an untappable card.
            guard let episode = episodes.first(where: { $0.number == item.episodeNumber }) else {
                Logger.shared.log(
                    "Latest: \(item.bookmark.title) ep \(item.episodeNumber) aired but module has not listed it",
                    type: "Latest"
                )
                continue
            }
            built.append(
                LatestEpisodeEntry(
                    showTitle: item.bookmark.title,
                    imageUrl: item.bookmark.imageUrl,
                    episodeNumber: episode.number,
                    episodeHref: episode.href,
                    showHref: item.bookmark.showHref,
                    moduleId: item.bookmark.moduleId,
                    airDate: item.airDate
                )
            )
        }

        // Unmatched shows: watermark diffing, undated.
        for bookmark in unmatched {
            guard let module = moduleManager.modules.first(where: { $0.id.uuidString == bookmark.moduleId }) else {
                continue
            }
            let episodes = await ModuleEpisodeScraper.shared.episodes(
                for: module,
                showHref: bookmark.showHref
            )
            guard let highest = episodes.map({ $0.number }).max() else { continue }

            guard let lastSeen = LatestSeenStore.lastSeenNumber(
                moduleId: bookmark.moduleId,
                showHref: bookmark.showHref
            ) else {
                // First scan: baseline silently so back catalogues do not flood.
                LatestSeenStore.record(
                    moduleId: bookmark.moduleId,
                    showHref: bookmark.showHref,
                    highestNumber: highest
                )
                continue
            }

            if highest > lastSeen {
                for episode in episodes where episode.number > lastSeen {
                    built.append(
                        LatestEpisodeEntry(
                            showTitle: bookmark.title,
                            imageUrl: bookmark.imageUrl,
                            episodeNumber: episode.number,
                            episodeHref: episode.href,
                            showHref: bookmark.showHref,
                            moduleId: bookmark.moduleId,
                            airDate: nil
                        )
                    )
                }
                LatestSeenStore.record(
                    moduleId: bookmark.moduleId,
                    showHref: bookmark.showHref,
                    highestNumber: highest
                )
            }
        }

        // Merge with cache so previously discovered entries survive until they
        // age out, and de-duplicate on module + episode href.
        var merged = LatestFeedCache.load()
        for entry in built where !merged.contains(where: {
            $0.moduleId == entry.moduleId && $0.episodeHref == entry.episodeHref
        }) {
            merged.append(entry)
        }

        let final = LatestFeedCache.prune(merged)
        LatestFeedCache.save(final)
        entries = final

        Logger.shared.log("Latest refresh complete: \(final.count) entries", type: "Latest")
    }

    private func uniqueBookmarks(from libraryManager: LibraryManager) -> [Bookmark] {
        var seen = Set<String>()
        var result: [Bookmark] = []
        for collection in libraryManager.collections {
            for item in collection.bookmarks {
                let key = "\(item.moduleId)_\(item.href)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(
                    Bookmark(
                        moduleId: item.moduleId,
                        showHref: item.href,
                        title: item.title,
                        imageUrl: item.imageUrl
                    )
                )
            }
        }
        return result
    }
}
```

- [ ] **Step 2: Register in the Xcode project**

Four pbxproj entries in the `LatestView` group.

- [ ] **Step 3: Self-review**

- Every `await` on a callback API is wrapped in `withCheckedContinuation` and resumes exactly once.
- Scraping only ever goes through `ModuleEpisodeScraper.shared`.
- The provider-ahead-of-module case emits nothing and logs — matches the spec's edge cases.
- The unmatched first-scan case baselines silently — matches the spec.
- Bookmarks are de-duplicated across collections; a show in two collections yields one entry.
- Merging de-duplicates on `moduleId` + `episodeHref`, so repeated refreshes do not stack duplicates.
- `.moduleRemoved` posts `module.id.uuidString` as `object` (see `ModuleManager:202`), which is what the observer reads.

- [ ] **Step 4: Commit and verify CI**

```bash
git add Sora/Views/LatestView/LatestFeedManager.swift Sulfur.xcodeproj/project.pbxproj
git commit -m "Add Latest feed manager with provider-first refresh"
git push && gh run watch --exit-status
```

---

## Task 7: Feed card and screen

**Files:**
- Create: `Sora/Views/LatestView/LatestEpisodeCell.swift`
- Create: `Sora/Views/LatestView/LatestView.swift`
- Modify: `Sulfur.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `LatestEpisodeEntry`, `LatestFeedManager`, `LibraryManager`, `ModuleManager`
- Produces: `LatestEpisodeCell`, `LatestView`

- [ ] **Step 1: Create the card**

```swift
//
//  LatestEpisodeCell.swift
//  Sulfur
//

import NukeUI
import SwiftUI

struct LatestEpisodeCell: View {
    let entry: LatestEpisodeEntry
    let onMarkWatched: () -> Void

    @State private var isWatched: Bool = false

    private var subtitle: String {
        let episode = String(format: NSLocalizedString("Episode %d", comment: ""), entry.episodeNumber)
        guard let airDate = entry.airDate else {
            return "\(episode) · \(NSLocalizedString("recently", comment: ""))"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "\(episode) · \(formatter.localizedString(for: airDate, relativeTo: Date()))"
    }

    var body: some View {
        HStack(spacing: 12) {
            LazyImage(url: URL(string: entry.imageUrl)) { state in
                if let uiImage = state.imageContainer?.image {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color(.systemGray5))
                }
            }
            .frame(width: 80, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.showTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !isWatched {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel(Text(NSLocalizedString("New", comment: "")))
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: {
                onMarkWatched()
                isWatched = true
            }) {
                Label(NSLocalizedString("Mark as Watched", comment: ""), systemImage: "checkmark.circle")
            }
        }
        .onAppear { isWatched = entry.isWatched }
    }
}
```

- [ ] **Step 2: Create the screen**

```swift
//
//  LatestView.swift
//  Sulfur
//

import SwiftUI

struct LatestView: View {
    @EnvironmentObject var latestFeedManager: LatestFeedManager
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var moduleManager: ModuleManager

    var body: some View {
        NavigationView {
            Group {
                if latestFeedManager.entries.isEmpty {
                    emptyState
                } else {
                    List(latestFeedManager.entries) { entry in
                        NavigationLink(destination: destination(for: entry)) {
                            LatestEpisodeCell(entry: entry) {
                                markWatched(entry)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(NSLocalizedString("LatestTab", comment: ""))
            .refreshable {
                await latestFeedManager.refresh(
                    libraryManager: libraryManager,
                    moduleManager: moduleManager
                )
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(emptyTitle)
                .font(.headline)
            Text(emptyMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var emptyTitle: String {
        if libraryManager.collections.allSatisfy({ $0.bookmarks.isEmpty }) {
            return NSLocalizedString("No Bookmarks", comment: "")
        }
        if !latestFeedManager.hasEverRefreshed {
            return NSLocalizedString("Pull to Refresh", comment: "")
        }
        return NSLocalizedString("No New Episodes", comment: "")
    }

    private var emptyMessage: String {
        if libraryManager.collections.allSatisfy({ $0.bookmarks.isEmpty }) {
            return NSLocalizedString("Bookmark shows to see their new episodes here.", comment: "")
        }
        if !latestFeedManager.hasEverRefreshed {
            return NSLocalizedString("Pull down to check your library for new episodes.", comment: "")
        }
        return NSLocalizedString("Nothing new in the last 7 days.", comment: "")
    }

    @ViewBuilder
    private func destination(for entry: LatestEpisodeEntry) -> some View {
        if let module = moduleManager.modules.first(where: { $0.id.uuidString == entry.moduleId }) {
            MediaInfoView(
                title: entry.showTitle,
                imageUrl: entry.imageUrl,
                href: entry.showHref,
                module: module
            )
        } else {
            Text(NSLocalizedString("Module not available", comment: ""))
        }
    }

    private func markWatched(_ entry: LatestEpisodeEntry) {
        let total = UserDefaults.standard.double(forKey: "totalTime_\(entry.episodeHref)")
        let duration = total > 0 ? total : 1.0
        UserDefaults.standard.set(duration, forKey: "totalTime_\(entry.episodeHref)")
        UserDefaults.standard.set(duration, forKey: "lastPlayedTime_\(entry.episodeHref)")
        Logger.shared.log("Latest: marked \(entry.showTitle) ep \(entry.episodeNumber) watched", type: "Latest")
    }
}
```

**Before writing `destination(for:)`, confirm `MediaInfoView`'s initialiser parameter list** by reading the top of `Sora/Views/MediaInfoView/MediaInfoView.swift`. It is declared with `let title`, `let imageUrl`, `let href`, `let module` as stored properties (lines ~22-25). If it takes additional required parameters, supply them; do not change `MediaInfoView`'s signature.

- [ ] **Step 3: Register both files in the Xcode project**

Eight pbxproj entries total (four per file), in the `LatestView` group.

- [ ] **Step 4: Self-review**

- Both files compile against iOS 15 — `.refreshable` is iOS 15+, `RelativeDateTimeFormatter` is iOS 13+, `LazyImage` comes from NukeUI which is already linked.
- `.listStyle(.plain)` and `.navigationViewStyle(.stack)` shorthand exist in iOS 15.
- `markWatched` mirrors `MediaInfoView.toggleSingleEpisodeWatchStatus`'s key usage.
- No refresh is triggered on appear — pull-to-refresh only, per the spec.
- New localization keys used: `LatestTab`, `Episode %d`, `recently`, `New`, `No Bookmarks`, `Pull to Refresh`, `No New Episodes`, and the three message strings, `Module not available`. All are added in Task 8.

- [ ] **Step 5: Commit and verify CI**

```bash
git add Sora/Views/LatestView/LatestEpisodeCell.swift \
        Sora/Views/LatestView/LatestView.swift \
        Sulfur.xcodeproj/project.pbxproj
git commit -m "Add Latest feed card and screen"
git push && gh run watch --exit-status
```

---

## Task 8: Tab integration, app wiring, localization

**Files:**
- Modify: `Sora/ContentView.swift:29-43`
- Modify: `Sora/SoraApp.swift:11-39`
- Modify: `Sora/Localization/en.lproj/Localizable.strings:390-394`

**Interfaces:**
- Consumes: `LatestView`, `LatestFeedManager`

- [ ] **Step 1: Insert the tab**

In `Sora/ContentView.swift`, replace the `tabs` array and `tabView(for:)`:

```swift
    let tabs: [TabItem] = [
        TabItem(icon: "square.stack", title: NSLocalizedString("LibraryTab", comment: "")),
        TabItem(icon: "sparkles", title: NSLocalizedString("LatestTab", comment: "")),
        TabItem(icon: "arrow.down.circle", title: NSLocalizedString("DownloadsTab", comment: "")),
        TabItem(icon: "gearshape", title: NSLocalizedString("SettingsTab", comment: "")),
        TabItem(icon: "magnifyingglass", title: NSLocalizedString("SearchTab", comment: ""))
    ]

    private func tabView(for index: Int) -> some View {
        switch index {
        case 1: return AnyView(LatestView())
        case 2: return AnyView(DownloadView())
        case 3: return AnyView(SettingsView())
        case 4: return AnyView(SearchView(searchQuery: $searchQuery))
        default: return AnyView(LibraryView())
        }
    }
```

**This index remap is the single highest-risk edit in the plan.** Getting it wrong sends users to the wrong screens with no compiler error. Verify each case number matches its position in `tabs`.

- [ ] **Step 2: Wire the manager into the app**

In `Sora/SoraApp.swift`, add the state object beside the existing five:

```swift
    @StateObject private var latestFeedManager = LatestFeedManager()
```

and inject it alongside the others in the `Group`'s modifier chain:

```swift
            .environmentObject(latestFeedManager)
```

Also update `ContentView_Previews` in `ContentView.swift` to supply it, or the preview will crash:

```swift
            .environmentObject(LatestFeedManager())
```

- [ ] **Step 3: Add localization keys**

In `Sora/Localization/en.lproj/Localizable.strings`, in the `/* TabView */` block after line 394, add:

```
"LatestTab" = "Latest";
```

Then append a new block at the end of the file:

```
/* Latest */
"Episode %d" = "Episode %d";
"recently" = "recently";
"New" = "New";
"No Bookmarks" = "No Bookmarks";
"Bookmark shows to see their new episodes here." = "Bookmark shows to see their new episodes here.";
"Pull to Refresh" = "Pull to Refresh";
"Pull down to check your library for new episodes." = "Pull down to check your library for new episodes.";
"No New Episodes" = "No New Episodes";
"Nothing new in the last 7 days." = "Nothing new in the last 7 days.";
"Module not available" = "Module not available";
```

Only `en.lproj` is updated; the other 19 bundles fall back to English.

- [ ] **Step 4: Self-review**

- `tabs` has five entries; `tabView(for:)` handles cases 1-4 plus `default` for 0.
- `LatestFeedManager` is created once in `SoraApp` and injected, not constructed per view.
- `ContentView_Previews` supplies every environment object the view tree needs.
- The iOS 26 native `TabView` branch iterates the same `tabs` array and needs no change.
- `Localizable.strings` entries each end with a semicolon.

- [ ] **Step 5: Commit and verify CI**

```bash
git add Sora/ContentView.swift Sora/SoraApp.swift \
        Sora/Localization/en.lproj/Localizable.strings
git commit -m "Add Latest tab between Library and Downloads"
git push && gh run watch --exit-status
```

---

## Task 9: Device verification

CI proves it compiles, not that it works. Build the IPA and test on device in LiveContainer.

- [ ] **Step 1: Fetch the build**

```bash
pwsh scripts/fetch-ipa.ps1 -Wait
```

Install `dist/Sulfur.ipa` in LiveContainer.

- [ ] **Step 2: Run the checks**

Record pass/fail for each:

1. **Tab order** — Library, Latest, Downloads, Settings, Search. Each opens its own screen. *(Catches the Task 8 index remap.)*
2. **Empty state** — with no bookmarks, the tab prompts you to bookmark shows.
3. **Bookmark capture** — open a currently-airing anime, bookmark it, then check Settings → Logger for a "Saved provider match" line with a non-empty anilist id.
4. **Refresh** — bookmark two currently-airing shows and one finished show. Pull to refresh. Only the airing shows produce cards, with plausible relative dates.
5. **Watched clears the dot** — play one card's episode to the end, return to Latest. Its NEW dot is gone. *(Confirms the `lastPlayedTime_<href>` key assumption.)*
6. **Mark as watched** — long-press another card, Mark as Watched. Dot clears without playback.
7. **Unmatched show** — bookmark something obscure with no AniList entry. First refresh shows nothing for it (baseline). After a new episode appears, a later refresh shows it as "recently".
8. **Module deletion** — delete a module in Settings. Its cards disappear from Latest.
9. **Offline** — enable airplane mode, reopen the tab. The cached feed still renders.
10. **Serialization** — with five or more bookmarks refreshing, confirm the logger shows no interleaved module parse errors. *(Confirms the actor is doing its job.)*

- [ ] **Step 3: Record results**

Note any failures with the relevant logger output before fixing. Do not fix more than one at a time.

---

## Self-Review of this plan

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Tab between Library and Downloads with icon | 8 |
| Feed derived from library bookmarks | 6 |
| AniList primary recency | 2, 6 |
| TMDB fallback | 3, 6 |
| Unmatched shows shown as "recently" | 5, 6 |
| 7-day window | 5 (`prune`), 6 (`cutoff`) |
| NEW indicator clears on watched / marked watched | 5 (`isWatched`), 7 |
| Thumbnail cards | 7 |
| Pull-to-refresh only, no refresh on open | 6, 7 |
| Provider-first, scrape only what aired | 6 |
| Serialized JS execution | 4 |
| Match persisted at bookmark time, manual wins | 1 |
| One card per episode | 6 |
| Provider ahead of module emits nothing | 6 |
| Module deleted drops entries | 5, 6 |
| Empty / error / offline states | 7 |
| Verification | 9 |

No gaps.

**Type consistency:** `ProviderMatch.tmdbType` is `String?` throughout (Tasks 1, 3, 6). `LatestEpisodeEntry.effectiveDate` is used consistently in Tasks 5 and 6. `ModuleEpisodeScraper.episodes(for:showHref:)` is called with the same signature in both Task 6 sites. `LatestFeedManager.refresh(libraryManager:moduleManager:)` takes both managers as parameters in Tasks 6 and 7.

**Known soft spots, flagged rather than hidden:**

- `MediaInfoView`'s initialiser parameters are assumed to be `title`, `imageUrl`, `href`, `module`. Task 7 Step 2 instructs verification before writing.
- The exact `onSelect` closure bodies in Task 1 Step 3 depend on code not fully read; the step says to add to the existing body rather than replace it.
- pbxproj edits cannot be validated locally. Each task's CI check is the guard.
