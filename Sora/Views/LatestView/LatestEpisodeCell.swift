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
            // No provider match: we know it is new, not when it aired.
            return "\(episode) · \(NSLocalizedString("recently", comment: ""))"
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

            if !isWatched {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel(Text(NSLocalizedString("New", comment: "")))
            }
        }
        .padding(.vertical, 6)
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
