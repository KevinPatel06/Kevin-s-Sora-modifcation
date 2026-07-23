# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A personal fork of [cranci1/Sora](https://github.com/cranci1/Sora) (upstream also calls itself "Sulfur"): a SwiftUI media player for iOS/iPadOS 15+ and Mac Catalyst 12+, GPLv3.

The app ships **no content and no sources**. Everything playable comes from user-installed **modules** — a JSON metadata file plus a JavaScript scraper that runs in JavaScriptCore. The Swift side is a shell around that JS: search, details, episodes, streams, and novel chapters are all delegated to module-provided global functions. See `MODULE_CREATION.md` for the full module contract.

## Development environment (important)

Development happens on **Windows, without Xcode and without an Apple developer account**. You cannot compile, run, or test locally. Consequences:

- **Never claim a change compiles.** The only compiler is the GitHub Actions macOS runner.
- **There is no test target and no lint config.** There are no tests to run; do not invent commands for them.
- **New Swift files must be registered in `Sulfur.xcodeproj/project.pbxproj` by hand.** The project uses classic `objectVersion = 55` groups with 129 explicit `PBXBuildFile` entries — there are no Xcode 16 synchronized folders. A new `.swift` file needs matching entries in `PBXFileReference`, `PBXBuildFile`, the enclosing `PBXGroup` children list, and the target's `PBXSourcesBuildPhase`, or it silently will not compile.

### Commands

```bash
# Trigger a CI build (also runs automatically on push to main or dev)
gh workflow run build.yml --ref main

# Download the IPA from the latest successful run into .\dist\Sulfur.ipa
pwsh scripts/fetch-ipa.ps1            # current branch
pwsh scripts/fetch-ipa.ps1 -Wait      # wait for an in-progress run first
pwsh scripts/fetch-ipa.ps1 -Branch dev
```

The IPA is unsigned and stripped of `_CodeSignature`/`embedded.mobileprovision`; it is installed through **LiveContainer**, not sideloaded normally.

On a Mac, `./ipabuild.sh` (iOS, `-destination generic/platform=iOS`) and `./macbuild.sh` (universal Mac Catalyst, lipo'd x86_64 + arm64) are the same scripts CI runs. The Catalyst job in `.github/workflows/build.yml` is `workflow_dispatch`-only since LiveContainer doesn't need it.

### Fork identity — do not "fix" these

| Thing | Value | Why it's like that |
|---|---|---|
| Xcode target & scheme | `Sulfur` | `ipabuild.sh`/`macbuild.sh` hardcode `APPLICATION_NAME=Sulfur`; renaming breaks CI |
| Source folder | `Sora/` | Untouched from upstream so merges stay clean |
| Bundle ID | `com.kevinpatel.sulfur` | Fork-specific |
| Display name | `Sora K` | Fork-specific |
| URL scheme | `sora://` | **Locked.** It is the registered OAuth redirect for AniList and Trakt, and the scheme community module pages link to. Renaming it breaks login and module installs. |
| `Sora/Utlis & Misc/` | typo is real | Upstream spelling; keep it |

`.gitattributes` marks `*.pbxproj` as `-text merge=union` and forces LF on `*.sh` (CRLF breaks `/bin/bash` on the runner). Don't override either.

## Architecture

### Startup and shell

`SoraApp.swift` is the `@main` entry. It builds five `@StateObject`s and injects them as environment objects everywhere: `Settings`, `ModuleManager`, `LibraryManager`, `DownloadManager`, `JSController.shared`. It gates on `hideSplashScreen` (`SplashScreenView` → `ContentView`), optionally refreshes modules on launch, clears `tmp/`, and handles `onOpenURL` for `sora://module?url=…` (presents the module-install sheet) and `sora://default_page?url=…` (sets the community library URL).

`ContentView.swift` is a four-tab shell — Library, Downloads, Settings, Search — using a custom `TabBar` driven by `hideTabBar`/`showTabBar` notifications, with an iOS 26 native `TabView` path behind the `useNativeTabBar` flag.

### The module pipeline (the core of the app)

```
metadata JSON URL ──► ModuleManager.addModule
                        ├─ Documents/modules.json      (array of ScrapingModule)
                        └─ Documents/<uuid>.js         (the scraper)
                                   │
user picks a module ───────────────┤  (selectedModuleId in @AppStorage)
                                   ▼
view calls moduleManager.getModuleContent(module)
        └─► JSController.loadScript(js)   ← REPLACES self.context with a fresh JSContext
                                   ▼
        JSController.fetch*  →  context.objectForKeyedSubscript("searchResults" | …)
                                   ▼
                        Swift models (SearchItem, MediaItem, EpisodeLink, …)
```

Three things about this are load-bearing:

1. **`JSController.loadScript` discards and recreates the `JSContext`.** Every screen (SearchView, MediaInfoView, EpisodeCell, ReaderView) re-reads the `.js` from disk and re-evaluates it immediately before calling into JS. Module JS therefore has no persistent state between operations, and any Swift-side setup must go through `JSContext.setupJavaScriptEnvironment()` in `JavaScriptCore+Extensions.swift`.
2. **Each hook has a sync and an async variant, chosen by module metadata.** `asyncJS == true` → the JS function receives a **URL** and returns a Promise; otherwise Swift fetches the HTML itself and hands the JS function an **HTML string**. `streamAsyncJS == true` selects a third hybrid path (`fetchStreamUrlJSSecond`: Swift fetches the HTML, then passes it to a Promise-returning function). Call sites: `SearchView.performSearch`, `MediaInfoView.fetchDetails`, `MediaInfoView`/`EpisodeCell` stream + download paths.
3. **`JSController` is a singleton that also owns the download subsystem** (`activeDownloads`, `downloadQueue`, `savedAssets`, `AVAssetDownloadURLSession`) via the `JSController-Downloads*` extensions. Its `JSController*.swift` files are extensions on one class, not separate types.

`ModuleManager` (`@MainActor`, `ObservableObject`) owns `modules.json`, re-downloads missing `.js` files on load, and `refreshModules()` re-fetches metadata and replaces the script when `metadata.version` differs by **string inequality** (not semver ordering).

### Subsystems

- **`MediaUtils/`** — `CustomPlayer.swift` is the primary player (AVPlayer + custom controls, VTT subtitles via `VTTSubtitlesLoader`, `SubtitleSettingsManager`, PiP, SharePlay via `VideoWatchingActivity`). `NormalPlayer/VideoPlayer.swift` is the plain `AVPlayerViewController` path. `ContinueWatching*` persists playback/reading position. Player choice comes from the `externalPlayer` default: `Default` → `VideoPlayerViewController`, `Sora`/unset → `CustomMediaPlayerViewController`, and named third-party players (Infuse, VLC, OutPlayer, nPlayer, SenPlayer, IINA, TracyPlayer) hand off via URL scheme, falling back to the custom player if the scheme can't open. Schemes must also be listed in `LSApplicationQueriesSchemes` in `Info.plist`.
- **`Tracking & Metadata/`** — AniList and Trakt OAuth (tokens in Keychain, redirect through `sora://`), progress push mutations, TMDB ID/episode lookup, IntroDB intro-skip timestamps. Note the TMDB API key is hardcoded in `MediaInfoView`.
- **`Utlis & Misc/DownloadUtils/` + `JSLoader/Downloads/`** — HLS downloads via `AVAssetDownloadURLSession`, MP4 via a plain `URLSession` with KVO progress; `downloadWithStreamTypeSupport` picks between them from `module.metadata.streamType` (`hls`/`m3u8` or a `.m3u8` URL → HLS, else MP4). Concurrency capped by `maxConcurrentDownloads` (default 3).
- **`Views/LibraryView/`** — bookmarks organized into `BookmarkCollection`s; `LibraryManager` migrates a legacy flat bookmarks key and prunes bookmarks when a module is deleted (`moduleRemoved` notification).
- **`Localization/`** — 20 `.lproj` bundles driven by a custom `LocalizationManager` + `Bundle+Language`, not just the system locale. Layout is force-LTR at the root (`environment(\.layoutDirection, .leftToRight)`).

### Cross-cutting conventions

- **Persistence is `UserDefaults` + JSON files in the Documents directory.** No Core Data, no SQLite. Bookmarks, continue-watching, module settings, and nearly all preferences are `UserDefaults` keys; modules and downloads are JSON on disk. iCloud sync is signalled through `Notification.Name` constants in `Notification+Name.swift` (`iCloudSyncDidComplete`, `modulesSyncDidComplete`, `moduleRemoved`, …) — components re-read from disk when they fire.
- **Logging goes through `Logger.shared.log(_:type:)`.** The `type` string is a free-form category used by the in-app log viewer's filter: `Error`, `Warning`, `Debug`, `General`, `Info`, `Stream`, `Download`, `HTMLStrings`. `HTMLStrings` carries full scraped HTML, so it is filtered out by default.
- **Networking uses `URLSession.custom`** (`Extensions/URLSession.swift`), which pins a randomly chosen desktop/mobile User-Agent per launch. `URLSession.fetchData(allowRedirects:)` is the redirect-controllable variant used by `fetchv2`. `NSAllowsArbitraryLoads` is on — modules routinely hit plain HTTP hosts.
- **Analytics is opt-in** (`analyticsEnabled`, default off) and POSTs to a **hardcoded upstream IP** in `Analytics.swift`. It reports app version, device model, and selected module name/version. If this fork should not phone home to upstream, that file is the single place to change.
- **UI feedback** uses `DropManager.shared.showDrop(...)` (Drops package) rather than alerts, except for the action sheets used for server/subtitle selection.
- 4-space indent, standard Xcode file-header comment blocks, `Logger` over `print`.

### Dependencies (SPM, all pinned to branches, not versions)

`Drops` (toasts) · `NukeUI` (`LazyImage`, all remote images) · `MarqueeLabel` · `SoraCore` (cranci1) — used for exactly one thing: `JSContext.setupWeirdCode()`, which injects a single obfuscated `_0xB4F2()` watermark global. SoraCore ships a full parallel `JSController`/`JSContext` stack, but this app uses its own copies under `Sora/Utlis & Misc/`, not SoraCore's. The JS environment module authors see is therefore defined entirely in this repo.

## Working on this repo

- Prefer changes that don't touch `project.pbxproj`. When you must, edit it surgically and mention it — you cannot verify the result until CI runs.
- Upstream is fast-moving and this is a fork; keep fork-specific changes small and localized (identity settings, `scripts/`, `.vscode/`, `.github/workflows/build.yml`) so upstream merges stay tractable.
- After pushing, the honest verification loop is: `gh run watch`, then `scripts/fetch-ipa.ps1`, then install in LiveContainer on device.
