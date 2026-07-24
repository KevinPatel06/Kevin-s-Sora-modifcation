//
//  LatestFeedManager.swift
//  Sulfur
//
//  Created by Kevin on 23/07/26.
//

import Foundation
import SwiftUI

/// Builds the Latest feed from library bookmarks.
///
/// Every bookmarked show produces exactly one row showing its most recent
/// episode and when that episode aired. Nothing is filtered out: watched rows
/// are dimmed by the cell rather than hidden, so the feed never goes empty
/// because of what you have already seen.
///
/// Dates come from AniList, matched by stored id, then by the app's existing
/// manual-match id, then by fuzzy title search. Episode numbers and links come
/// from the module, which is the only thing that knows how to play them.
@MainActor
final class LatestFeedManager: ObservableObject {
    @Published var entries: [LatestEpisodeEntry] = []
    @Published var isRefreshing = false
    @Published var hasEverRefreshed = false
    @Published var progress: String?

    private let matchStore = ProviderMatchStore.shared
    private var moduleRemovedToken: NSObjectProtocol?

    init() {
        entries = LatestFeedCache.load()
        hasEverRefreshed = UserDefaults.standard.bool(forKey: "latestHasEverRefreshed")

        // Block-based observers must be removed by token, not by `self`.
        moduleRemovedToken = NotificationCenter.default.addObserver(
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
        if let token = moduleRemovedToken {
            NotificationCenter.default.removeObserver(token)
        }
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

        defer {
            isRefreshing = false
            progress = nil
            hasEverRefreshed = true
            UserDefaults.standard.set(true, forKey: "latestHasEverRefreshed")
        }

        let bookmarks = uniqueBookmarks(from: libraryManager)
        Logger.shared.log(
            "Latest: starting refresh — \(libraryManager.collections.count) collections, \(bookmarks.count) unique bookmarks, \(moduleManager.modules.count) modules installed",
            type: "Latest"
        )
        guard !bookmarks.isEmpty else {
            Logger.shared.log("Latest: no bookmarks found, nothing to build", type: "Latest")
            entries = []
            LatestFeedCache.save([])
            return
        }

        // 1. Resolve an AniList id per show. Stored match wins, then the id the
        //    app has long persisted for manual matches, then a title search.
        var idByKey: [String: Int] = [:]
        for bookmark in bookmarks {
            let key = "\(bookmark.moduleId)_\(bookmark.showHref)"
            if let stored = matchStore.match(moduleId: bookmark.moduleId, showHref: bookmark.showHref)?.anilistId {
                idByKey[key] = stored
            } else if let legacy = matchStore.legacyAniListID(showHref: bookmark.showHref) {
                idByKey[key] = legacy
            }
        }

        let unresolved = bookmarks.filter { idByKey["\($0.moduleId)_\($0.showHref)"] == nil }
        for (index, bookmark) in unresolved.enumerated() {
            progress = String(
                format: NSLocalizedString("Matching %1$d of %2$d", comment: ""),
                index + 1, unresolved.count
            )
            let found: Int? = await withCheckedContinuation { continuation in
                AniListAiringSchedule.searchId(title: bookmark.title) {
                    continuation.resume(returning: $0)
                }
            }
            guard let anilistId = found else { continue }
            idByKey["\(bookmark.moduleId)_\(bookmark.showHref)"] = anilistId
            matchStore.saveIfAbsent(
                ProviderMatch(
                    anilistId: anilistId,
                    tmdbId: nil,
                    tmdbType: nil,
                    matchedAt: Date(),
                    source: .auto
                ),
                moduleId: bookmark.moduleId,
                showHref: bookmark.showHref
            )
        }

        // 2. One batched request for every resolved id.
        let dates: [Int: AniListLatestEpisode] = await withCheckedContinuation { continuation in
            AniListAiringSchedule.latestAired(anilistIds: Array(idByKey.values)) {
                continuation.resume(returning: $0)
            }
        }

        // 2b. TMDB fallback for anything AniList could not match, which is
        //     mostly non-anime shows AniList does not carry.
        var tmdbDateByKey: [String: Date] = [:]
        for bookmark in bookmarks {
            let key = "\(bookmark.moduleId)_\(bookmark.showHref)"
            guard idByKey[key] == nil else { continue }

            let stored = matchStore.match(moduleId: bookmark.moduleId, showHref: bookmark.showHref)
            var tmdbId = stored?.tmdbId
            var tmdbType = stored?.tmdbType ?? "tv"

            if tmdbId == nil {
                let found: (Int?, TMDBFetcher.MediaType?) = await withCheckedContinuation { continuation in
                    TMDBFetcher().fetchBestMatchID(for: bookmark.title) { id, type in
                        continuation.resume(returning: (id, type))
                    }
                }
                tmdbId = found.0
                tmdbType = found.1?.rawValue ?? "tv"
                if let id = tmdbId {
                    matchStore.saveIfAbsent(
                        ProviderMatch(
                            anilistId: nil,
                            tmdbId: id,
                            tmdbType: tmdbType,
                            matchedAt: Date(),
                            source: .auto
                        ),
                        moduleId: bookmark.moduleId,
                        showHref: bookmark.showHref
                    )
                }
            }

            guard let id = tmdbId else { continue }
            let aired: (episodeNumber: Int, airDate: Date)? = await withCheckedContinuation { continuation in
                TMDBAirDates.latestAired(tmdbId: id, mediaType: tmdbType) {
                    continuation.resume(returning: $0)
                }
            }
            if let aired = aired {
                tmdbDateByKey[key] = aired.airDate
            }
        }

        // 3. Scrape each module for the latest episode number and its link.
        //    Serialized by ModuleEpisodeScraper: JSController has one JSContext.
        //    Published incrementally so rows appear as they resolve.
        var built: [LatestEpisodeEntry] = []
        for (index, bookmark) in bookmarks.enumerated() {
            progress = String(
                format: NSLocalizedString("Checking %1$d of %2$d", comment: ""),
                index + 1, bookmarks.count
            )

            guard let module = moduleManager.modules.first(
                where: { $0.id.uuidString == bookmark.moduleId }
            ) else {
                // The bookmark names a module that is no longer installed.
                Logger.shared.log(
                    "Latest: skipping \(bookmark.title) — no installed module matches id \(bookmark.moduleId)",
                    type: "Latest"
                )
                continue
            }

            let episodes = await ModuleEpisodeScraper.shared.episodes(
                for: module,
                showHref: bookmark.showHref
            )
            guard let latest = episodes.max(by: { $0.number < $1.number }) else {
                Logger.shared.log(
                    "Latest: \(bookmark.title) returned 0 episodes from \(module.metadata.sourceName)",
                    type: "Latest"
                )
                continue
            }

            let key = "\(bookmark.moduleId)_\(bookmark.showHref)"
            let airDate = idByKey[key].flatMap { dates[$0]?.airDate } ?? tmdbDateByKey[key]

            built.append(
                LatestEpisodeEntry(
                    showTitle: bookmark.title,
                    imageUrl: bookmark.imageUrl,
                    episodeNumber: latest.number,
                    episodeHref: latest.href,
                    showHref: bookmark.showHref,
                    moduleId: bookmark.moduleId,
                    airDate: airDate
                )
            )
            entries = LatestFeedCache.sorted(built)
        }

        // The feed is rebuilt wholesale: one row per bookmark, no merging.
        LatestFeedCache.save(built)
        entries = LatestFeedCache.sorted(built)

        let dated = built.filter { $0.airDate != nil }.count
        Logger.shared.log(
            "Latest refresh complete: \(built.count) shows, \(dated) with dates",
            type: "Latest"
        )
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
