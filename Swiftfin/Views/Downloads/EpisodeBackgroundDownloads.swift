//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import UIKit

@MainActor
final class EpisodeBackgroundDownloads: NSObject, URLSessionDownloadDelegate {

    static let shared = EpisodeBackgroundDownloads()
    static let identifier = "org.jellyfin.swiftfin.episode-downloads"

    private var stores: [String: EpisodeDownloads] = [:]
    private var completion: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    func store(serverID: String, userID: String) -> EpisodeDownloads {
        let scope = EpisodeDownloads.scope(serverID: serverID, userID: userID)
        if let store = stores[scope] {
            return store
        }

        let store = loadStore(scope: scope)
        let restoredNames = store.restoredStagingNames
        session.getAllTasks { tasks in
            Task { @MainActor in
                store.reconnect(active: tasks, restoredNames: restoredNames)
            }
        }
        return store
    }

    func start(_ request: URLRequest, scope: String, stagingName: String) {
        let task = session.downloadTask(with: request)
        task.taskDescription = scope + "/" + stagingName
        task.resume()
    }

    func cancel(scope: String, stagingName: String) {
        let reference = scope + "/" + stagingName
        session.getAllTasks { tasks in
            tasks.first { $0.taskDescription == reference }?.cancel()
        }
    }

    func removeDownloads(serverID: String, userID: String? = nil) throws {
        let scope = EpisodeDownloads.scope(serverID: serverID, userID: userID)
        do {
            try FileManager.default.removeItem(at: EpisodeDownloads.storageDirectory(scope: scope))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileNoSuchFile.rawValue {
            // The account or server may have no downloads.
        }

        for key in stores.keys.filter({ $0.hasPrefix(scope) }) {
            stores.removeValue(forKey: key)?.invalidate()
        }
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription?.hasPrefix(scope) == true {
                task.cancel()
            }
        }
    }

    func handleEvents(completion: @escaping () -> Void) {
        self.completion = completion
        _ = session
    }

    private func loadStore(scope: String) -> EpisodeDownloads {
        if let store = stores[scope] {
            return store
        }

        let store = EpisodeDownloads(scope: scope)
        stores[scope] = store
        return store
    }

    private func destination(for task: URLSessionTask) -> (EpisodeDownloads, String)? {
        guard let parts = task.taskDescription?.split(separator: "/"), parts.count == 2,
              parts[0].utf8.count == 128,
              parts[0].utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }),
              parts[1].hasPrefix("partial-"),
              UUID(uuidString: String(parts[1].dropFirst("partial-".count))) != nil else { return nil }

        return (loadStore(scope: String(parts[0])), String(parts[1]))
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The main delegate queue lets us commit the file before URLSession removes it.
        MainActor.assumeIsolated {
            guard let (store, stagingName) = destination(for: downloadTask) else { return }

            store.finish(stagingName: stagingName, file: location, response: downloadTask.response)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        MainActor.assumeIsolated {
            guard let (store, stagingName) = destination(for: downloadTask) else { return }

            store.updateProgress(stagingName: stagingName, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let error, let (store, stagingName) = destination(for: task) else { return }

            store.fail(stagingName: stagingName, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            let handler = completion
            completion = nil
            handler?()
        }
    }
}

final class EpisodeDownloadAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == EpisodeBackgroundDownloads.identifier else {
            completionHandler()
            return
        }

        EpisodeBackgroundDownloads.shared.handleEvents(completion: completionHandler)
    }
}
