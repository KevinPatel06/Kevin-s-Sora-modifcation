# Export downloaded shows to the Files app

**Date:** 2026-07-24
**Status:** Implemented, pending on-device verification

## Goal

From Downloads → Downloaded, select one or more shows and copy their downloaded
episodes out of the app sandbox into a browsable folder in the Files app, with one
subfolder per show:

```
<user-picked folder>/
  Sora/
    Code Geass/
      S01E01 - The Day a New Demon Was Born.mp4
      S01E01 - The Day a New Demon Was Born.vtt
      S01E02 - The White Knight Awakens.mp4
```

## Constraints that shaped the design

1. **iOS apps cannot create a folder at the top level of the device.** There is no way
   to make `On My iPhone/Sora` appear without either the user granting access to a
   location, or exposing the app's own container through `UIFileSharingEnabled`. The
   latter is unreliable here because the app runs under LiveContainer, where the
   container Files sees belongs to LiveContainer, not to this app. So: the user picks
   a destination once through the Files folder picker, and the app creates `Sora/`
   inside it.

2. **HLS downloads are stored as `.movpkg` bundles**, which are directories, not video
   files. Copying one out produces something no player outside the app can open. These
   are counted and reported as skipped rather than copied. MP4 downloads copy cleanly.

## Design

### `Sora/Utlis & Misc/DownloadUtils/DownloadExporter.swift` (new)

`@MainActor final class DownloadExporter: ObservableObject`.

Supporting types (`ExportProgress`, `ExportSummary`, `ExportJob`, `ExportJobResult`,
`ExportError`) live at file scope, **not** nested in the class — a type nested inside a
`@MainActor` type inherits that isolation, which conflicts with the nonisolated
requirements of `Equatable`, `Sendable` and `LocalizedError`.

**Destination.** The picked folder is stored as a security-scoped bookmark under the
`exportDestinationBookmark` `UserDefaults` key. `.withSecurityScope` is applied only
under `targetEnvironment(macCatalyst)`; on iOS a plain bookmark of a security-scoped URL
is correct. Stale bookmarks are refreshed on resolve; unresolvable ones are cleared so
the UI re-prompts.

**Export.** `export(shows:)` resolves the bookmark, brackets the whole run in
`startAccessingSecurityScopedResource()`, creates `<destination>/Sora`, then flattens
the selection into `ExportJob` values up front so the copy loop touches no models. Each
copy runs in a detached task and awaits back on the main actor, which publishes
`ExportProgress` between files.

Per-episode outcome is one of: `exported`, `alreadyExists` (skipped — re-export behaves
as a sync), `notExportable` (a `.movpkg` bundle or directory), or `failed`. A failure on
one episode is logged and counted; the run continues to the next.

**Naming.** `S%02dE%02d - <episode title>`, falling back to the asset's stored name when
season/episode metadata is absent. `sanitize` strips `/ \ : ? % * | " < >` and newlines,
collapses whitespace runs, trims trailing dots and spaces, and caps length at 120 chars.

**Subtitles.** `localSubtitleURL`, when present, is copied next to the video with the
same base name.

### `Sora/Views/DownloadView.swift`

- An upload-arrow menu appears in the header on the Downloaded tab with
  *Export Shows…* and *Choose/Change Export Folder…*.
- *Export Shows…* enters selection mode: a bar under the header offers
  Select All / Deselect All, Cancel, and `Export (N)`; show cards render a
  checkmark circle, highlight their border when selected, and tap to select instead
  of navigating (`EnhancedDownloadGroupCard` now branches between a `Button` and a
  `NavigationLink` over shared `cardContent`).
- If no destination is stored, tapping Export opens the folder picker and resumes the
  export once a folder is chosen.
- A modal overlay shows `current / total` while copying.
- On completion: a `DropManager` toast plus an alert breaking down copied / already
  present / not exportable / failed.

### Other files

- `Sulfur.xcodeproj/project.pbxproj` — four entries registering `DownloadExporter.swift`
  (`PBXFileReference`, `PBXBuildFile`, the `DownloadUtils` group, the target's
  `PBXSourcesBuildPhase`).
- `Sora/Localization/en.lproj/Localizable.strings` — 17 new keys.

## Verification

No local compiler on this machine. Verification is CI (`gh run watch`), then
`scripts/fetch-ipa.ps1`, then installing in LiveContainer and exporting a show.
