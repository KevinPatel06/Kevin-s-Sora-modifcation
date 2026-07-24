//
//  TMDB-AirDates.swift
//  Sulfur
//
//  Created by Kevin on 23/07/26.
//

import Foundation

/// Air-date lookup used as a fallback when a show has no AniList match,
/// which is mainly non-anime shows AniList does not carry.
enum TMDBAirDates {
    /// The most recently aired episode of a TV show, or nil for movies and
    /// anything TMDB has no air date for.
    static func latestAired(
        tmdbId: Int,
        mediaType: String,
        completion: @escaping ((episodeNumber: Int, airDate: Date)?) -> Void
    ) {
        // Movies have no episodes.
        guard mediaType == "tv" else {
            completion(nil)
            return
        }

        let apiKey = TMDBFetcher().apiKey
        guard let url = URL(string: "https://api.themoviedb.org/3/tv/\(tmdbId)?api_key=\(apiKey)") else {
            completion(nil)
            return
        }

        URLSession.custom.dataTask(with: url) { data, _, error in
            if let error = error {
                Logger.shared.log("TMDB air-date lookup failed: \(error.localizedDescription)", type: "Error")
                completion(nil)
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let last = json["last_episode_to_air"] as? [String: Any],
                  let episodeNumber = last["episode_number"] as? Int,
                  let airDateString = last["air_date"] as? String else {
                completion(nil)
                return
            }

            // Fixed locale and timezone: "yyyy-MM-dd" must parse identically
            // regardless of the device's region settings.
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.locale = Locale(identifier: "en_US_POSIX")

            guard let airDate = formatter.date(from: airDateString) else {
                completion(nil)
                return
            }

            Logger.shared.log("TMDB tv/\(tmdbId) latest episode \(episodeNumber) aired \(airDateString)", type: "Latest")
            completion((episodeNumber: episodeNumber, airDate: airDate))
        }.resume()
    }
}
