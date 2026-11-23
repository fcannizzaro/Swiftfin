//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI

@MainActor
struct PlaybackIntent {

    let entry: ItemEntry
    let download: DownloadedEpisode.Playback?
    var queue: any MediaPlayerQueue?
    var configuration: MediaPlaybackConfiguration

    init(download: DownloadedEpisode.Playback) {
        self.init(download: download, configuration: .init())
    }

    init(download: DownloadedEpisode.Playback, configuration: MediaPlaybackConfiguration) {
        self.entry = ItemEntry(item: ItemRecord(id: download.episode.id, presentationValue: download.episode.item))
        self.download = download
        self.configuration = configuration
    }

    var item: BaseItemDto {
        entry.snapshot
    }

    var mediaSource: MediaSourceInfo? {
        configuration.mediaSource(in: item)
    }

    init(item: BaseItemDto, queue: any MediaPlayerQueue? = nil) {
        self.init(item: item, configuration: .init(), queue: queue)
    }

    init(item: BaseItemDto, configuration: MediaPlaybackConfiguration, queue: any MediaPlayerQueue? = nil) {
        self.entry = SharedBaseItem(wrappedValue: item).entry
        self.download = nil
        self.queue = queue
        self.configuration = configuration
    }
}
