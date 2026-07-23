//
//  LatestView.swift
//  Sulfur
//
//  Created by Kevin on 23/07/26.
//

import SwiftUI

struct LatestView: View {
    @EnvironmentObject var latestFeedManager: LatestFeedManager
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var moduleManager: ModuleManager

    private var hasNoBookmarks: Bool {
        libraryManager.collections.allSatisfy { $0.bookmarks.isEmpty }
    }

    var body: some View {
        NavigationView {
            Group {
                if latestFeedManager.entries.isEmpty {
                    // ScrollView keeps pull-to-refresh reachable when empty.
                    ScrollView {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    }
                } else {
                    List(latestFeedManager.entries) { entry in
                        ZStack {
                            NavigationLink(destination: destination(for: entry)) {
                                EmptyView()
                            }
                            .opacity(0)

                            LatestEpisodeCell(entry: entry) {
                                markWatched(entry)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(NSLocalizedString("LatestTab", comment: ""))
            .refreshable {
                await latestFeedManager.refresh(
                    libraryManager: libraryManager,
                    moduleManager: moduleManager
                )
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(emptyTitle)
                .font(.headline)
            Text(emptyMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var emptyTitle: String {
        if hasNoBookmarks {
            return NSLocalizedString("No Bookmarks", comment: "")
        }
        if !latestFeedManager.hasEverRefreshed {
            return NSLocalizedString("Pull to Refresh", comment: "")
        }
        return NSLocalizedString("No New Episodes", comment: "")
    }

    private var emptyMessage: String {
        if hasNoBookmarks {
            return NSLocalizedString("Bookmark shows to see their new episodes here.", comment: "")
        }
        if !latestFeedManager.hasEverRefreshed {
            return NSLocalizedString("Pull down to check your library for new episodes.", comment: "")
        }
        return NSLocalizedString("Nothing new in the last 7 days.", comment: "")
    }

    @ViewBuilder
    private func destination(for entry: LatestEpisodeEntry) -> some View {
        if let module = moduleManager.modules.first(where: { $0.id.uuidString == entry.moduleId }) {
            MediaInfoView(
                title: entry.showTitle,
                imageUrl: entry.imageUrl,
                href: entry.showHref,
                module: module
            )
        } else {
            Text(NSLocalizedString("Module not available", comment: ""))
        }
    }

    /// Mirrors how MediaInfoView marks a single episode watched, writing the
    /// same keys the players use so the NEW dot clears everywhere at once.
    private func markWatched(_ entry: LatestEpisodeEntry) {
        let total = UserDefaults.standard.double(forKey: "totalTime_\(entry.episodeHref)")
        let duration = total > 0 ? total : 1.0
        UserDefaults.standard.set(duration, forKey: "totalTime_\(entry.episodeHref)")
        UserDefaults.standard.set(duration, forKey: "lastPlayedTime_\(entry.episodeHref)")
        Logger.shared.log(
            "Latest: marked \(entry.showTitle) ep \(entry.episodeNumber) watched",
            type: "Latest"
        )
    }
}
