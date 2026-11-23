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
@_spi(Advanced) import SwiftUIIntrospect

struct EpisodeDownloadsView: View {

    @Injected(\.currentUserSession)
    private var session

    @ContentBuilder
    var body: some View {
        if let session {
            DownloadsList(session: session)
        }
    }
}

private struct DownloadsList: View {

    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass

    @Weak
    private var tabController: UITabBarController?

    @State
    private var showsSidebarTitle = false

    let session: UserSession

    private var downloads: EpisodeDownloads {
        session.episodeDownloads
    }

    private struct Show: Identifiable {

        let id: String
        let title: String
        let episodes: [DownloadedEpisode]
    }

    private var shows: [Show] {
        Dictionary(grouping: downloads.episodes) { $0.item.seriesID ?? $0.id }
            .map { id, episodes in
                Show(id: id, title: episodes.first?.item.seriesName ?? L10n.unknown, episodes: episodes.sorted {
                    ($0.item.parentIndexNumber ?? 0, $0.item.indexNumber ?? 0, $0.id)
                        < ($1.item.parentIndexNumber ?? 0, $1.item.indexNumber ?? 0, $1.id)
                })
            }
            .sorted { left, right in
                let order = left.title.localizedStandardCompare(right.title)
                return order == .orderedSame ? left.id < right.id : order == .orderedAscending
            }
    }

    @ContentBuilder
    var body: some View {
        List {
            if !downloads.transfers.isEmpty {
                Section {
                    ForEach(downloads.transfers.keys.sorted(), id: \.self) { id in
                        if let transfer = downloads.transfers[id] {
                            transferRow(transfer, id: id)
                                .contextMenu { EpisodeDownloadActions(item: transfer.item) }
                        }
                    }
                }
            }

            ForEach(shows) { show in
                if let first = show.episodes.first {
                    Section {
                        ForEach(show.episodes) { episode in
                            let playback = downloads.playback(for: episode)
                            NavigationLink {
                                DownloadedEpisodeDetails(playback: playback)
                            } label: {
                                HStack(spacing: 12) {
                                    localArtwork(at: playback.thumbnailURL, width: 88, height: 50)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(episode.item.name ?? L10n.unknown)
                                            .font(.body.weight(.medium))

                                        DotHStack {
                                            if let number = episode.item.seasonEpisodeLabel {
                                                Text(number)
                                            }
                                            Text(episode.byteCount.formatted(.byteCount(style: .file)))
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .contextMenu { RemoveEpisodeDownloadButton(episode: episode, session: session) }
                            .swipeActions(allowsFullSwipe: false) {
                                RemoveEpisodeDownloadButton(episode: episode, session: session)
                            }
                        }
                    } header: {
                        HStack(spacing: 10) {
                            localArtwork(at: downloads.playback(for: first).posterURL, width: 28, height: 42)
                            Text(show.title)
                        }
                    }
                }
            }
        }
        .overlay {
            if downloads.episodes.isEmpty, downloads.transfers.isEmpty {
                ContentUnavailableView(
                    L10n.noDownloads,
                    systemImage: "rectangle.on.rectangle.slash"
                )
            }
        }
        .navigationTitle(showsSidebarTitle ? L10n.downloads : "")
        .toolbarTitleDisplayMode(showsSidebarTitle ? .inlineLarge : .inline)
        .introspect(.tabView, on: .iOS(.v18...), scope: .ancestor) { controller in
            tabController = controller
            updateSidebarTitle()
        }
        .onSizeChanged { _, _ in
            updateSidebarTitle()
        }
        .onChange(of: horizontalSizeClass) {
            updateSidebarTitle()
        }
    }

    private func updateSidebarTitle() {
        let visible = horizontalSizeClass == .regular && tabController?.sidebar.isHidden == false
        guard showsSidebarTitle != visible else { return }

        showsSidebarTitle = visible
    }

    @ContentBuilder
    private func transferRow(_ transfer: EpisodeDownloads.Transfer, id: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(transfer.item.name ?? L10n.unknown)
                    .font(.body.weight(.medium))

                DotHStack {
                    if let show = transfer.item.seriesName {
                        Text(show)
                    }
                    if let number = transfer.item.seasonEpisodeLabel {
                        Text(number)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                switch transfer.state {
                case let .downloading(fraction):
                    EpisodeDownloadProgress(fraction: fraction)

                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            switch transfer.state {
            case .downloading:
                transferButton(L10n.cancelDownload, systemImage: "xmark") { downloads.cancel(id) }

            case .failed:
                if session.userData.policy?.enableContentDownloading == true, transfer.item.canDownload != false {
                    transferButton(L10n.retryDownload, systemImage: "arrow.clockwise") {
                        downloads.download(transfer.item, session: session)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ContentBuilder
    private func transferButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .background {
                    Circle().fill(.quaternary).frame(width: 32, height: 32)
                }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
    }
}

private struct DownloadedEpisodeDetails: View {

    @PlayMedia
    private var playMedia

    let playback: DownloadedEpisode.Playback

    private var item: BaseItemDto {
        playback.episode.item
    }

    @ContentBuilder
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                localArtwork(at: playback.thumbnailURL, width: 320, height: 180)
                Text(item.name ?? L10n.unknown).font(.title.bold())

                DotHStack {
                    if let subtitle = item.seasonEpisodeLabel {
                        Text(subtitle)
                    }
                    Label(L10n.downloaded, systemImage: "checkmark.circle.fill")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Button((playback.position ?? .zero) > .zero ? L10n.resume : L10n.play, systemImage: "play.fill") {
                    playMedia(intent: PlaybackIntent(download: playback))
                }
                .buttonStyle(.borderedProminent)

                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding()
        }
        .navigationTitle(item.seriesName ?? L10n.downloads)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct EpisodeDownloadActions: View {

    @Injected(\.currentUserSession)
    private var session

    let item: BaseItemDto

    @ContentBuilder
    var body: some View {
        if let session, let id = item.id {
            let downloads = session.episodeDownloads
            if let episode = downloads.episodes.first(where: { $0.id == id }) {
                RemoveEpisodeDownloadButton(episode: episode, session: session)
            } else {
                switch downloads.transfers[id]?.state {
                case .downloading:
                    Button(L10n.cancelDownload, systemImage: "xmark.circle") { downloads.cancel(id) }

                case .failed:
                    if session.userData.policy?.enableContentDownloading == true, item.canDownload != false {
                        Button(L10n.retryDownload, systemImage: "arrow.clockwise") { downloads.download(item, session: session) }
                    }
                    Button(L10n.removeDownload, systemImage: "trash", role: .destructive) { downloads.cancel(id) }

                case nil:
                    if session.userData.policy?.enableContentDownloading == true, item.canDownload != false {
                        Button(L10n.download, systemImage: "arrow.down.circle") { downloads.download(item, session: session) }
                    }
                }
            }
        }
    }
}

@ContentBuilder
private func localArtwork(at url: URL, width: CGFloat, height: CGFloat) -> some View {
    ZStack {
        Rectangle().fill(.quaternary)
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: "film").foregroundStyle(.secondary)
        }
    }
    .frame(width: width, height: height)
    .clipShape(.rect(cornerRadius: 6))
    .accessibilityHidden(true)
}
