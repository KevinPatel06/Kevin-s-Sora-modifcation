//
//  LatestEpisodeCell.swift
//  Sulfur
//
//  Created by Kevin on 23/07/26.
//

import NukeUI
import SwiftUI

struct LatestEpisodeCell: View {
    let entry: LatestEpisodeEntry
    let onMarkWatched: () -> Void

    @State private var isWatched: Bool = false

    private var subtitle: String {
        let episode = String(
            format: NSLocalizedString("Episode %d", comment: ""),
            entry.episodeNumber
        )
        guard let airDate = entry.airDate else {
            // No AniList match, so the episode is known but its date is not.
            return episode
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "\(episode) · \(formatter.localizedString(for: airDate, relativeTo: Date()))"
    }

    var body: some View {
        HStack(spacing: 12) {
            LazyImage(url: URL(string: entry.imageUrl)) { state in
                if let uiImage = state.imageContainer?.image {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color(.systemGray5))
                }
            }
            .frame(width: 80, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.showTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 6)
        // Watched rows stay in the list but recede, so the feed always shows
        // every library show while unwatched ones read as the live ones.
        .opacity(isWatched ? 0.45 : 1)
        .contentShape(Rectangle())
        .contextMenu {
            if !isWatched {
                Button(action: {
                    onMarkWatched()
                    isWatched = true
                }) {
                    Label(
                        NSLocalizedString("Mark as Watched", comment: ""),
                        systemImage: "checkmark.circle"
                    )
                }
            }
        }
        .onAppear { isWatched = entry.isWatched }
    }
}
