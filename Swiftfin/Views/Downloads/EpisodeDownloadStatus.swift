//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import JellyfinAPI
import SwiftUI

struct EpisodeDownloadStatus: View {

    @Injected(\.currentUserSession)
    private var session

    let item: BaseItemDto

    @ContentBuilder
    var body: some View {
        if item.type == .episode, let id = item.id, let downloads = session?.episodeDownloads {
            let isDownloaded = downloads.episodes.contains(where: { $0.id == id })
            if isDownloaded {
                badge {
                    Image(systemName: "arrow.down.circle.fill")
                        .accessibilityLabel(L10n.downloaded)
                }
            } else if case let .downloading(fraction) = downloads.transfers[id]?.state {
                badge {
                    HStack(spacing: 5) {
                        if let fraction {
                            Image(systemName: "arrow.down")
                            Text(fraction, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.downloadingEpisode)
                    .accessibilityValue(fraction?.formatted(.percent.precision(.fractionLength(0))) ?? "")
                }
            }
        }
    }

    @ContentBuilder
    private func badge(@ContentBuilder content: () -> some View) -> some View {
        content()
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.75), in: .capsule)
    }
}

struct EpisodeDownloadProgress: View {

    let fraction: Double?

    @ContentBuilder
    var body: some View {
        if let fraction {
            ProgressView(value: fraction) {
                Text(L10n.downloadingEpisode)
            } currentValueLabel: {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        } else {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(L10n.downloadingEpisode)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct RemoveEpisodeDownloadButton: View {

    let episode: DownloadedEpisode
    let session: UserSession

    @ContentBuilder
    var body: some View {
        Button(L10n.removeDownload, systemImage: "trash", role: .destructive) {
            do {
                try session.episodeDownloads.remove(episode)
            } catch {
                session.itemActionErrors.send(error)
            }
        }
    }
}
