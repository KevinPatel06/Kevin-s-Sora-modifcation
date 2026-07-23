//
//  TMDB-AirDates.swift
//  Sulfur
//
//  Created by Kevin on 23/07/26.
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

            // Fixed locale and timezone: "yyyy-MM-dd" must parse identically
            // regardless of the device's region settings.
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
