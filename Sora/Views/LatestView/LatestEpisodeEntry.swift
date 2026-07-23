//
//  LatestEpisodeEntry.swift
//  Sulfur
//
//  Created by Kevin on 23/07/26.
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

    /// Used for sorting and for the 7-day window. Entries with no provider
    /// match fall back to when this app first noticed them.
    var effectiveDate: Date { airDate ?? discoveredAt }

    /// Derived from the same UserDefaults keys the episode list and players
    /// already write, so "Mark as Watched" clears the NEW dot for free.
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

    /// Drops anything outside the window and returns newest first.
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

    /// `nil` means this show has never been scanned, so the caller must baseline
    /// it silently instead of emitting its entire back catalogue as "new".
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

    static func clear(moduleId: String, showHref: String) {
        UserDefaults.standard.removeObject(forKey: key(moduleId: moduleId, showHref: showHref))
    }
}
