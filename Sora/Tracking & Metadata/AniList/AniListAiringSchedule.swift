//
//  AniListAiringSchedule.swift
//  Sulfur
//
//  Created by Kevin on 23/07/26.
//

import Foundation

struct AiredEpisode {
    let anilistId: Int
    let episodeNumber: Int
    let airDate: Date
}

/// Batched lookup of which AniList entries aired an episode inside a time window.
///
/// One request answers the question for every bookmarked show at once, which is
/// what keeps a Latest refresh cheap: only the handful of shows that actually
/// aired need their module scraped afterwards.
enum AniListAiringSchedule {
    private static let endpoint = URL(string: "https://graphql.anilist.co")!

    /// AniList caps `perPage` at 50, so ids are queried in chunks.
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
