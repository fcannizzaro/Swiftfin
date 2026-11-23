//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

/// The saved metadata and relative filenames for one complete download.
struct DownloadedEpisode: Codable, Identifiable {

    let item: BaseItemDto
    let source: MediaSourceInfo
    let videoFilename: String
    let subtitleFilenames: [Int: String]
    let byteCount: Int

    var id: String {
        item.id ?? ""
    }

    struct Playback {

        let episode: DownloadedEpisode
        let directory: URL

        var videoURL: URL {
            directory.appending(path: episode.videoFilename)
        }

        var posterURL: URL {
            directory.appending(path: "poster")
        }

        var thumbnailURL: URL {
            directory.appending(path: "thumbnail")
        }

        private var positionURL: URL {
            directory.appending(path: "position")
        }

        var position: Duration? {
            guard let data = try? Data(contentsOf: positionURL),
                  let ticks = try? JSONDecoder().decode(Int.self, from: data) else { return nil }

            return .ticks(ticks)
        }

        func savePosition(_ position: Duration) {
            guard let data = try? JSONEncoder().encode(max(0, position.ticks)) else { return }

            try? data.write(to: positionURL, options: .atomic)
        }
    }
}
