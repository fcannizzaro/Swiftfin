//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CryptoKit
import Foundation
import JellyfinAPI
import Logging
import UIKit

@MainActor
@Observable
final class EpisodeDownloads {

    private static let logger = Logger.swiftfin()

    struct Transfer {

        enum State {

            case downloading(Double?)
            case failed(String)
        }

        let item: BaseItemDto
        var state: State
    }

    private(set) var episodes: [DownloadedEpisode] = []
    private(set) var transfers: [String: Transfer] = [:]

    @ObservationIgnored
    private var tasks: [String: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var isInvalidated = false

    private struct Pending {

        let draft: DownloadedEpisode
        let directory: URL
    }

    private var pending: [String: Pending] = [:]
    private let scope: String
    private let root: URL
    private let files = FileManager.default

    static func scope(serverID: String, userID: String?) -> String {
        storageKey(serverID) + (userID.map(storageKey) ?? "")
    }

    static func storageDirectory(scope: String) -> URL {
        let server = URL.applicationSupportDirectory
            .appending(path: "EpisodeDownloads", directoryHint: .isDirectory)
            .appending(path: String(scope.prefix(64)), directoryHint: .isDirectory)
        let user = scope.dropFirst(64)
        return user.isEmpty ? server : server.appending(path: String(user), directoryHint: .isDirectory)
    }

    init(scope: String) {
        self.scope = scope
        root = Self.storageDirectory(scope: scope)

        let directories = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for directory in directories {
            if directory.lastPathComponent.hasPrefix("partial-") {
                guard let data = try? Data(contentsOf: directory.appending(path: "pending.json")),
                      let draft = try? JSONDecoder().decode(DownloadedEpisode.self, from: data) else {
                    try? files.removeItem(at: directory)
                    continue
                }

                pending[draft.id] = Pending(draft: draft, directory: directory)
                let message = try? String(contentsOf: directory.appending(path: "failure"), encoding: .utf8)
                transfers[draft.id] = Transfer(item: draft.item, state: message.map { .failed($0) } ?? .downloading(nil))
            } else if let data = try? Data(contentsOf: directory.appending(path: "episode.json")),
                      let episode = try? JSONDecoder().decode(DownloadedEpisode.self, from: data) {
                if files.fileExists(atPath: directory.appending(path: episode.videoFilename).path) {
                    episodes.append(episode)
                } else {
                    try? files.removeItem(at: directory)
                }
            }
        }
    }

    func playback(for episode: DownloadedEpisode) -> DownloadedEpisode.Playback {
        .init(episode: episode, directory: directory(for: episode.id))
    }

    func download(_ item: BaseItemDto, session: UserSession) {
        guard !isInvalidated, item.type == .episode, let id = item.id,
              session.userData.policy?.enableContentDownloading == true,
              item.canDownload != false, tasks[id] == nil,
              !episodes.contains(where: { $0.id == id }) else { return }

        if case .downloading = transfers[id]?.state {
            return
        }
        cancel(id)
        transfers[id] = Transfer(item: item, state: .downloading(nil))

        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        @MainActor
        func endBackgroundTask() {
            guard backgroundTask != .invalid else { return }

            let identifier = backgroundTask
            backgroundTask = .invalid
            UIApplication.shared.endBackgroundTask(identifier)
        }

        tasks[id] = Task {
            defer {
                tasks[id] = nil
                endBackgroundTask()
            }

            do {
                try Task.checkCancellation()
                try await prepare(id: id, session: session)
            } catch {
                if !Task.isCancelled {
                    transfers[id]?.state = .failed(error.localizedDescription)
                }
            }
        }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Prepare episode download") { [weak self] in
            self?.tasks[id]?.cancel()
            self?.transfers[id]?.state = .failed(URLError(.timedOut).localizedDescription)
            endBackgroundTask()
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        if let entry = pending.removeValue(forKey: id) {
            EpisodeBackgroundDownloads.shared.cancel(scope: scope, stagingName: entry.directory.lastPathComponent)
            try? files.removeItem(at: entry.directory)
        }
        transfers[id] = nil
    }

    func cancelAll() {
        for id in Set(tasks.keys).union(pending.keys) {
            cancel(id)
        }
    }

    func invalidate() {
        isInvalidated = true
        for task in tasks.values {
            task.cancel()
        }
        pending.removeAll()
        transfers.removeAll()
        episodes.removeAll()
    }

    var restoredStagingNames: Set<String> {
        Set(pending.values.map(\.directory.lastPathComponent))
    }

    func reconnect(active: [URLSessionTask], restoredNames: Set<String>) {
        for (id, entry) in pending {
            guard restoredNames.contains(entry.directory.lastPathComponent),
                  case .downloading = transfers[id]?.state else { continue }

            if let task = active.first(where: { $0.taskDescription?.hasSuffix("/" + entry.directory.lastPathComponent) == true }) {
                updateProgress(
                    stagingName: entry.directory.lastPathComponent,
                    received: task.countOfBytesReceived,
                    expected: task.countOfBytesExpectedToReceive
                )
            } else {
                // Keep the draft until it is retried or a queued completion arrives.
                transfers[id]?.state = .failed(URLError(.cancelled).localizedDescription)
            }
        }
    }

    func updateProgress(stagingName: String, received: Int64, expected: Int64) {
        guard expected > 0, let id = pendingID(stagingName) else { return }

        transfers[id]?.state = .downloading(min(1, Double(received) / Double(expected)))
    }

    func fail(stagingName: String, error: Error) {
        guard let id = pendingID(stagingName), let entry = pending[id] else { return }

        let message = error.localizedDescription
        try? Data(message.utf8).write(to: entry.directory.appending(path: "failure"), options: .atomic)
        transfers[id]?.state = .failed(message)
    }

    func finish(stagingName: String, file: URL, response: URLResponse?) {
        guard let id = pendingID(stagingName), let entry = pending[id] else { return }

        do {
            guard let response else { throw URLError(.badServerResponse) }

            try Self.validate(response)
            let draft = entry.draft
            let staging = entry.directory
            let fallback = Self.fileExtension(draft.source.container, fallback: "video")
            let ext = Self.fileExtension(response.suggestedFilename.map { ($0 as NSString).pathExtension }, fallback: fallback)
            let name = "episode.\(ext)"
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw URLError(.zeroByteResource) }

            let video = staging.appending(path: name)
            try files.moveItem(at: file, to: video)

            var source = draft.source
            source.size = size
            let assets = ["poster", "thumbnail"] + Array(draft.subtitleFilenames.values)
            let byteCount = assets.reduce(size) { bytes, asset in
                bytes + ((try? staging.appending(path: asset).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let episode = DownloadedEpisode(
                item: draft.item,
                source: source,
                videoFilename: name,
                subtitleFilenames: draft.subtitleFilenames,
                byteCount: byteCount
            )
            try JSONEncoder().encode(episode).write(to: staging.appending(path: "episode.json"), options: .atomic)
            let destination = directory(for: id)
            try files.moveItem(at: staging, to: destination)
            try? files.removeItem(at: destination.appending(path: "pending.json"))
            try? files.removeItem(at: destination.appending(path: "failure"))
            pending[id] = nil
            transfers[id] = nil
            episodes.append(episode)
        } catch {
            fail(stagingName: stagingName, error: error)
        }
    }

    private func pendingID(_ stagingName: String) -> String? {
        pending.first(where: { $0.value.directory.lastPathComponent == stagingName })?.key
    }

    func remove(_ episode: DownloadedEpisode) throws {
        let directory = directory(for: episode.id)
        if files.fileExists(atPath: directory.path) {
            try files.removeItem(at: directory)
        }
        episodes.removeAll { $0.id == episode.id }
    }

    private static func storageKey(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func directory(for id: String) -> URL {
        root.appending(path: Self.storageKey(id), directoryHint: .isDirectory)
    }

    private func prepare(id: String, session: UserSession) async throws {
        let client = session.client
        let item = try await client.send(Paths.getItem(itemID: id, userID: session.user.id)).value
        try Task.checkCancellation()
        guard item.canDownload == true, item.id == id,
              let sources = item.mediaSources,
              let source = sources.first(where: { $0.path != nil && $0.path == item.path })
              ?? sources.first(where: { $0.id == id }) ?? (sources.count == 1 ? sources.first : nil),
              let sourceID = source.id else { throw ErrorMessage(L10n.unableToLoadThisItem) }

        try files.createDirectory(at: root, withIntermediateDirectories: true)
        var storage = root
        var storageValues = URLResourceValues()
        storageValues.isExcludedFromBackup = true
        try storage.setResourceValues(storageValues)

        let staging = root.appending(path: "partial-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer {
            if pending[id]?.directory != staging {
                try? files.removeItem(at: staging)
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        if let token = client.accessToken {
            configuration.httpAdditionalHeaders = ["Authorization": "MediaBrowser Token=\"\(token)\""]
        }
        let transport = URLSession(configuration: configuration)
        defer { transport.finishTasksAndInvalidate() }

        try await saveArtwork(
            itemID: item.seriesID,
            types: [.primary],
            width: 540,
            to: staging.appending(path: "poster"),
            client: client,
            transport: transport
        )
        try await saveArtwork(
            itemID: id,
            types: [.thumb, .primary],
            width: 640,
            to: staging.appending(path: "thumbnail"),
            client: client,
            transport: transport
        )

        var streams: [MediaStream] = []
        var subtitles: [Int: String] = [:]
        for var stream in source.mediaStreams ?? [] {
            if stream.isExternal == true {
                guard stream.type == .subtitle, stream.isTextSubtitleStream == true,
                      let index = stream.index, index >= 0 else { continue }

                // Keep styled tracks and convert other text formats to a supported sidecar format.
                let format = switch stream.codec?.lowercased() {
                case "ass": "ass"
                case "ssa": "ssa"
                case "vtt", "webvtt": "vtt"
                default: "srt"
                }
                let route = Paths.getSubtitle(routeItemID: id, routeMediaSourceID: sourceID, routeIndex: index, routeFormat: format)
                let data: Data
                do {
                    data = try await Self.fetch(client.url(with: route), using: transport)
                } catch {
                    try Task.checkCancellation()
                    Self.logger.warning("Unable to save subtitle \(index) for episode \(id): \(error.localizedDescription)")
                    continue
                }
                try Task.checkCancellation()
                let filename = "subtitle-\(index).\(format)"
                try data.write(to: staging.appending(path: filename))
                subtitles[index] = filename
                stream.codec = format == "srt" ? SubtitleFormat.subrip.rawValue : format
                stream.deliveryMethod = .external
                stream.deliveryURL = filename
            } else {
                stream.deliveryMethod = stream.type == .subtitle ? .embed : nil
                stream.deliveryURL = nil
            }

            stream.path = nil
            streams.append(stream)
        }

        guard let url = client.url(with: Paths.getDownload(itemID: id)) else { throw URLError(.badURL) }

        let savedItem = BaseItemDto(
            id: id,
            indexNumber: item.indexNumber,
            mediaType: .video,
            name: item.name,
            overview: item.overview,
            parentIndexNumber: item.parentIndexNumber,
            runTimeTicks: item.runTimeTicks,
            seriesID: item.seriesID,
            seriesName: item.seriesName,
            type: .episode
        )

        let defaultSubtitle = source.defaultSubtitleStreamIndex.flatMap { index in
            streams.contains(where: { $0.type == .subtitle && $0.index == index }) ? index : nil
        }
        let savedSource = MediaSourceInfo(
            protocol: .file,
            bitrate: source.bitrate,
            container: source.container,
            defaultAudioStreamIndex: source.defaultAudioStreamIndex,
            defaultSubtitleStreamIndex: defaultSubtitle,
            id: sourceID,
            isSupportsDirectPlay: true,
            mediaStreams: streams,
            runTimeTicks: source.runTimeTicks
        )

        let draft = DownloadedEpisode(item: savedItem, source: savedSource, videoFilename: "", subtitleFilenames: subtitles, byteCount: 0)
        try Task.checkCancellation()
        try JSONEncoder().encode(draft).write(to: staging.appending(path: "pending.json"), options: .atomic)
        pending[id] = Pending(draft: draft, directory: staging)

        var request = URLRequest(url: url)
        if let token = client.accessToken {
            request.setValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
        }
        EpisodeBackgroundDownloads.shared.start(
            request,
            scope: scope,
            stagingName: staging.lastPathComponent
        )
    }

    private func saveArtwork(
        itemID: String?,
        types: [ImageType],
        width: Int,
        to file: URL,
        client: JellyfinClient,
        transport: URLSession
    ) async throws {
        guard let itemID else { return }

        for type in types {
            let request = Paths.getItemImage(itemID: itemID, imageType: type.rawValue, parameters: .init(maxWidth: width))
            guard let url = client.url(with: request) else { continue }

            let (data, response) = try await transport.data(from: url)

            if (response as? HTTPURLResponse)?.statusCode == 404 {
                continue
            }

            try Self.validate(response)
            guard UIImage(data: data) != nil else { throw URLError(.cannotDecodeContentData) }

            try data.write(to: file)
            return
        }
    }

    private static func fetch(_ url: URL?, using transport: URLSession) async throws -> Data {
        guard let url else { throw URLError(.badURL) }

        let (data, response) = try await transport.data(from: url)
        try validate(response)
        guard !data.isEmpty else { throw URLError(.zeroByteResource) }

        return data
    }

    private nonisolated static func validate(_ response: URLResponse) throws {
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    }

    private static func fileExtension(_ value: String?, fallback: String) -> String {
        guard let value = value?.lowercased(), !value.isEmpty, value.utf8.count <= 12,
              value.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 122).contains($0) }) else { return fallback }

        return value
    }
}
