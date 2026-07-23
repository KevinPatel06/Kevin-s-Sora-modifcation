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
/// Strategy is provider-first: one batched AniList query (plus TMDB for
/// anything AniList lacks) answers "which bookmarked shows aired this week",
/// and only those shows get their module scraped to resolve a playable link.
/// Scraping every bookmark would be far slower and, because module scraping
/// must be serialized, would take minutes for a large library.
@MainActor
final class LatestFeedManager: ObservableObject {
    @Published var entries: [LatestEpisodeEntry] = []
    @Published var isRefreshing = false
    @Published var providerFailed = false
    @Published var hasEverRefreshed = false

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
                Logger.shared.log("Latest: dropped entries for removed module \(moduleId)", type: "Latest")
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

        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -LatestFeedCache.windowDays,
            to: Date()
        ) ?? Date()

        var unmatched: [Bookmark] = []
        var tmdbOnly: [(bookmark: Bookmark, tmdbId: Int, tmdbType: String)] = []
        var anilistIdToBookmark: [Int: Bookmark] = [:]

        for bookmark in bookmarks {
            let stored = matchStore.match(moduleId: bookmark.moduleId, showHref: bookmark.showHref)

            if let anilistId = stored?.anilistId {
                anilistIdToBookmark[anilistId] = bookmark
            } else if let legacyId = matchStore.legacyAniListID(showHref: bookmark.showHref) {
                // The app has persisted manual AniList matches as
                // custom_anilist_id_<href> since before this store existed.
                // Adopt it so already-matched shows work on the first refresh.
                anilistIdToBookmark[legacyId] = bookmark
                matchStore.saveIfAbsent(
                    ProviderMatch(
                        anilistId: legacyId,
                        tmdbId: stored?.tmdbId,
                        tmdbType: stored?.tmdbType,
                        matchedAt: Date(),
                        source: .manual
                    ),
                    moduleId: bookmark.moduleId,
                    showHref: bookmark.showHref
                )
            } else if let tmdbId = stored?.tmdbId {
                tmdbOnly.append((bookmark, tmdbId, stored?.tmdbType ?? "tv"))
            } else {
                unmatched.append(bookmark)
            }
        }

        var pending: [(bookmark: Bookmark, episodeNumber: Int, airDate: Date)] = []

        if !anilistIdToBookmark.isEmpty {
            let aired: [AiredEpisode] = await withCheckedContinuation { continuation in
                AniListAiringSchedule.fetchRecentlyAired(
                    anilistIds: Array(anilistIdToBookmark.keys),
                    since: cutoff
                ) { continuation.resume(returning: $0) }
            }
            for episode in aired {
                guard let bookmark = anilistIdToBookmark[episode.anilistId] else { continue }
                pending.append((bookmark, episode.episodeNumber, episode.airDate))
            }
        }

        for entry in tmdbOnly {
            let aired: [(episodeNumber: Int, airDate: Date)] = await withCheckedContinuation { continuation in
                TMDBAirDates.fetchRecentlyAired(
                    tmdbId: entry.tmdbId,
                    mediaType: entry.tmdbType,
                    since: cutoff
                ) { continuation.resume(returning: $0) }
            }
            for episode in aired {
                pending.append((entry.bookmark, episode.episodeNumber, episode.airDate))
            }
        }

        var built: [LatestEpisodeEntry] = []

        // Dated episodes: scrape to turn an episode number into a playable href.
        for item in pending {
            guard let module = moduleManager.modules.first(
                where: { $0.id.uuidString == item.bookmark.moduleId }
            ) else { continue }

            let episodes = await ModuleEpisodeScraper.shared.episodes(
                for: module,
                showHref: item.bookmark.showHref
            )

            // Providers frequently report an episode as aired before the source
            // site has uploaded it. Emit nothing rather than an untappable card;
            // it will appear on a later refresh once the module lists it.
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

        // Unmatched shows: undated, detected by watermark diffing.
        for bookmark in unmatched {
            guard let module = moduleManager.modules.first(
                where: { $0.id.uuidString == bookmark.moduleId }
            ) else { continue }

            let episodes = await ModuleEpisodeScraper.shared.episodes(
                for: module,
                showHref: bookmark.showHref
            )
            guard let highest = episodes.map({ $0.number }).max() else { continue }

            guard let lastSeen = LatestSeenStore.lastSeenNumber(
                moduleId: bookmark.moduleId,
                showHref: bookmark.showHref
            ) else {
                // First ever scan: baseline silently, or a long-running series
                // would dump its entire back catalogue into the feed.
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

        // Merge with the cache so earlier discoveries survive until they age
        // out. De-duplicated on module + episode href.
        var merged = LatestFeedCache.load()
        for entry in built where !merged.contains(where: {
            $0.moduleId == entry.moduleId && $0.episodeHref == entry.episodeHref
        }) {
            merged.append(entry)
        }

        let final = LatestFeedCache.prune(merged)
        LatestFeedCache.save(final)
        entries = final

        Logger.shared.log(
            "Latest refresh complete: \(final.count) entries (\(built.count) new)",
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
