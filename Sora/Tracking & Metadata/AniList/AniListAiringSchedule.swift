//
//  AniListAiringSchedule.swift
//  Sulfur
//
//  Created by Kevin on 23/07/26.
//

import Foundation

/// The most recent episode AniList knows aired for a show.
struct AniListLatestEpisode {
    let anilistId: Int
    /// nil when the date came from the show's end date rather than a schedule.
    let episodeNumber: Int?
    let airDate: Date
}

/// AniList lookups for the Latest tab.
///
/// Note on the API shape: `airingAt_greater`/`airingAt_lesser` are arguments of
/// the top-level `Page.airingSchedules` query, NOT of the nested
/// `Media.airingSchedule` field. Putting them on `Media.airingSchedule` makes
/// AniList reject the whole request, which returns no data at all.
enum AniListAiringSchedule {
    private static let endpoint = URL(string: "https://graphql.anilist.co")!

    /// Aliases per request. Each show costs two aliases, so this stays modest
    /// to keep AniList's query-complexity limit comfortable.
    private static let chunkSize = 20

    // MARK: - Latest aired episode

    /// One request answers "what aired most recently" for many shows, using
    /// GraphQL aliases so each show gets its own precise answer. A shared
    /// `mediaId_in` page would let a long-running series crowd out the rest.
    static func latestAired(
        anilistIds: [Int],
        completion: @escaping ([Int: AniListLatestEpisode]) -> Void
    ) {
        let ids = Array(Set(anilistIds))
        guard !ids.isEmpty else {
            completion([:])
            return
        }

        let chunks = stride(from: 0, to: ids.count, by: chunkSize).map {
            Array(ids[$0..<min($0 + chunkSize, ids.count)])
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [Int: AniListLatestEpisode] = [:]

        for chunk in chunks {
            group.enter()
            fetchChunk(ids: chunk) { partial in
                lock.lock()
                collected.merge(partial) { current, _ in current }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { completion(collected) }
    }

    private static func fetchChunk(
        ids: [Int],
        completion: @escaping ([Int: AniListLatestEpisode]) -> Void
    ) {
        let now = Int(Date().timeIntervalSince1970)

        var parts: [String] = []
        for (index, id) in ids.enumerated() {
            parts.append("s\(index): Page(page: 1, perPage: 1) { airingSchedules(mediaId: \(id), airingAt_lesser: \(now), sort: TIME_DESC) { episode airingAt } }")
            // Shows older than roughly 2015 have no airingSchedule entries at
            // all, so fall back to the show's end date for those.
            parts.append("m\(index): Media(id: \(id)) { episodes endDate { year month day } }")
        }
        let query = "query { " + parts.joined(separator: " ") + " }"

        post(query) { json in
            guard let data = json?["data"] as? [String: Any] else {
                Logger.shared.log("AniList latestAired returned no data", type: "Error")
                completion([:])
                return
            }

            var result: [Int: AniListLatestEpisode] = [:]
            for (index, id) in ids.enumerated() {
                if let page = data["s\(index)"] as? [String: Any],
                   let nodes = page["airingSchedules"] as? [[String: Any]],
                   let node = nodes.first,
                   let airingAt = node["airingAt"] as? Int {
                    result[id] = AniListLatestEpisode(
                        anilistId: id,
                        episodeNumber: node["episode"] as? Int,
                        airDate: Date(timeIntervalSince1970: TimeInterval(airingAt))
                    )
                    continue
                }

                if let media = data["m\(index)"] as? [String: Any],
                   let end = media["endDate"] as? [String: Any],
                   let year = end["year"] as? Int {
                    var components = DateComponents()
                    components.year = year
                    components.month = end["month"] as? Int ?? 12
                    components.day = end["day"] as? Int ?? 28
                    components.timeZone = TimeZone(identifier: "UTC")
                    if let date = Calendar(identifier: .gregorian).date(from: components) {
                        result[id] = AniListLatestEpisode(
                            anilistId: id,
                            episodeNumber: media["episodes"] as? Int,
                            airDate: date
                        )
                    }
                }
            }

            Logger.shared.log("AniList resolved dates for \(result.count)/\(ids.count) shows", type: "Latest")
            completion(result)
        }
    }

    // MARK: - Fuzzy title match

    /// Resolves a show title to an AniList id. AniList answers HTTP 404 with a
    /// "Not Found." error body when nothing matches, which is not a failure.
    static func searchId(title: String, completion: @escaping (Int?) -> Void) {
        let cleaned = title
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            completion(nil)
            return
        }

        let query = "query { Media(search: \"\(cleaned)\", type: ANIME) { id } }"
        post(query) { json in
            guard let data = json?["data"] as? [String: Any],
                  let media = data["Media"] as? [String: Any],
                  let id = media["id"] as? Int else {
                completion(nil)
                return
            }
            completion(id)
        }
    }

    // MARK: - Transport

    private static func post(_ query: String, completion: @escaping ([String: Any]?) -> Void) {
        guard let body = try? JSONSerialization.data(withJSONObject: ["query": query]) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        URLSession.custom.dataTask(with: request) { data, _, error in
            if let error = error {
                Logger.shared.log("AniList request failed: \(error.localizedDescription)", type: "Error")
                completion(nil)
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }
            if let errors = json["errors"] as? [[String: Any]],
               let first = errors.first?["message"] as? String,
               first != "Not Found." {
                Logger.shared.log("AniList GraphQL error: \(first)", type: "Error")
            }
            completion(json)
        }.resume()
    }
}
