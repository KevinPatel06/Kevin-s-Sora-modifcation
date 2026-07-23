//
//  ProviderMatchStore.swift
//  Sulfur
//
//  Created by Kevin on 23/07/26.
//

import Foundation

struct ProviderMatch: Codable {
    enum Source: String, Codable {
        case auto
        case manual
    }

    let anilistId: Int?
    let tmdbId: Int?
    let tmdbType: String?      // "tv" or "movie"; String keeps this Codable-stable
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

    /// Falls back to the AniList id the app has been persisting for manual
    /// matches since before this store existed (`handleAniListMatch`).
    /// Lets already-matched shows work on first refresh with no re-matching.
    func legacyAniListID(showHref: String) -> Int? {
        let value = defaults.integer(forKey: "custom_anilist_id_\(showHref)")
        return value > 0 ? value : nil
    }
}
