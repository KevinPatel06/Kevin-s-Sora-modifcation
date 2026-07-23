//
//  LatestEpisodeEntry.swift
//  Sulfur
//
//  Created by Kevin on 23/07/26.
//

import Foundation

/// One row in the Latest feed: a library show and its most recent episode.
///
/// The feed lists every bookmarked show, always. Watched entries are dimmed
/// rather than hidden, so the tab never depends on what you have or have not
/// watched to decide whether to show something.
struct LatestEpisodeEntry: Codable, Identifiable {
    let id: UUID
    let showTitle: String
    let imageUrl: String
    let episodeNumber: Int
    let episodeHref: String
    let showHref: String
    let moduleId: String
    /// Most recent air date from AniList; nil when the show could not be matched.
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

    /// Derived from the same UserDefaults keys the episode list and players
    /// already write, so "Mark as Watched" dims the row for free.
    /// Threshold matches the existing 0.9 used across LibraryView.
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

    static func load() -> [LatestEpisodeEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([LatestEpisodeEntry].self, from: data) else {
            return []
        }
        return sorted(entries)
    }

    static func save(_ entries: [LatestEpisodeEntry]) {
        guard let data = try? JSONEncoder().encode(sorted(entries)) else {
            Logger.shared.log("Failed to encode latest feed", type: "Error")
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Newest first. Shows with no resolved date sort last rather than being
    /// dropped, so an unmatched show is still reachable in the feed.
    static func sorted(_ entries: [LatestEpisodeEntry]) -> [LatestEpisodeEntry] {
        entries.sorted { lhs, rhs in
            switch (lhs.airDate, rhs.airDate) {
            case let (l?, r?): return l > r
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return lhs.showTitle.localizedCaseInsensitiveCompare(rhs.showTitle) == .orderedAscending
            }
        }
    }

    static func removeEntries(moduleId: String) {
        save(load().filter { $0.moduleId != moduleId })
    }
}
