//
//  ModuleEpisodeScraper.swift
//  Sulfur
//
//  Created by Kevin on 23/07/26.
//

import Foundation

/// Serializes all module scraping performed by the Latest tab.
///
/// `JSController` holds a single `JSContext` that `loadScript` destroys and
/// rebuilds on every call. Two concurrent scrapes would clobber each other's
/// context mid-parse, so every scrape in this feature funnels through here.
///
/// This is only affordable because the Latest refresh asks the metadata
/// providers first and scrapes only the handful of shows that actually aired.
/// Scraping every bookmark serially would be far too slow.
actor ModuleEpisodeScraper {
    static let shared = ModuleEpisodeScraper()

    private init() {}

    /// Loads the module's script and returns its episode list for a show.
    /// Returns an empty array on any failure; callers treat that as "nothing new".
    func episodes(for module: ScrapingModule, showHref: String) async -> [EpisodeLink] {
        let jsContent: String
        do {
            jsContent = try await MainActor.run {
                try ModuleManager.shared.getModuleContent(module)
            }
        } catch {
            Logger.shared.log(
                "Latest: failed to read module \(module.metadata.sourceName): \(error.localizedDescription)",
                type: "Error"
            )
            return []
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                JSController.shared.loadScript(jsContent)

                // Resuming a continuation twice is a hard crash, and there are
                // three racing paths here: then, catch, and our own timeout.
                let lock = NSLock()
                var didResume = false
                let resumeOnce: (String, [EpisodeLink]) -> Void = { reason, episodes in
                    lock.lock()
                    let alreadyResumed = didResume
                    didResume = true
                    lock.unlock()
                    guard !alreadyResumed else { return }
                    if reason == "timeout" {
                        Logger.shared.log(
                            "Latest: scrape timed out for \(module.metadata.sourceName) — \(showHref)",
                            type: "Latest"
                        )
                    }
                    continuation.resume(returning: episodes)
                }

                // JSController.fetchDetailsJS waits on a DispatchGroup covering
                // both extractDetails and extractEpisodes, but only the episodes
                // half has a timeout. A module whose extractDetails promise
                // never settles would hang this loop forever, so we impose our
                // own ceiling and move on to the next show.
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                    resumeOnce("timeout", [])
                }

                if module.metadata.asyncJS == true {
                    JSController.shared.fetchDetailsJS(url: showHref) { _, episodes in
                        resumeOnce("done", episodes)
                    }
                } else {
                    JSController.shared.fetchDetails(url: showHref) { _, episodes in
                        resumeOnce("done", episodes)
                    }
                }
            }
        }
    }
}
