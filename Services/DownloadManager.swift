import Foundation
import AVFoundation

actor OfflineDownloadManager {
    typealias ProgressHandler = @Sendable (Double) -> Void

    private let session: URLSession
    private let fm = FileManager.default

    init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    func downloadAndMerge(
        playlistURL: URL,
        headers: [String: String],
        outputURL: URL,
        progress: ProgressHandler?
    ) async throws -> URL {
        let playlistData = try await fetchData(url: playlistURL, headers: headers)
        let resolved = try await resolveSegments(from: playlistData, baseURL: playlistURL, headers: headers)
        let segmentURLs = resolved.segments
        let finalOutputURL = resolved.isFmp4
            ? outputURL.deletingPathExtension().appendingPathExtension("mp4")
            : outputURL
        guard !segmentURLs.isEmpty else {
            throw URLError(.cannotParseResponse)
        }

        let tempFolder = fm.temporaryDirectory.appendingPathComponent("hls-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tempFolder, withIntermediateDirectories: true)

        let total = max(segmentURLs.count, 1)
        var completed = 0

        try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            for (index, segmentURL) in segmentURLs.enumerated() {
                group.addTask {
                    let data = try await self.fetchData(url: segmentURL, headers: headers)
                    let localURL = tempFolder.appendingPathComponent(String(format: "seg_%05d.ts", index))
                    try data.write(to: localURL, options: .atomic)
                    return (index, localURL)
                }
            }

            for try await _ in group {
                completed += 1
                let value = Double(completed) / Double(total)
                progress?(value)
            }
        }

        try? fm.removeItem(at: finalOutputURL)
        fm.createFile(atPath: finalOutputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: finalOutputURL)
        defer { try? handle.close() }

        for index in 0..<segmentURLs.count {
            let localURL = tempFolder.appendingPathComponent(String(format: "seg_%05d.ts", index))
            if let data = try? Data(contentsOf: localURL) {
                try handle.write(contentsOf: data)
            }
        }

        try? fm.removeItem(at: tempFolder)
        return finalOutputURL
    }

    private func fetchData(url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func resolveSegments(from data: Data, baseURL: URL, headers: [String: String]) async throws -> (segments: [URL], isFmp4: Bool) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let mediaLines = lines.filter { !$0.hasPrefix("#") && !$0.isEmpty }
        let mapLine = lines.first { $0.hasPrefix("#EXT-X-MAP:") }
        let mapURL: URL? = {
            guard let mapLine else { return nil }
            let parts = mapLine.split(separator: "URI=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            var uri = parts[1]
            if uri.hasPrefix("\"") { uri = uri.dropFirst() }
            if uri.hasSuffix("\"") { uri = uri.dropLast() }
            return URL(string: String(uri), relativeTo: baseURL)?.absoluteURL
        }()

        if let variantLine = mediaLines.first(where: { $0.hasSuffix(".m3u8") }) {
            let variantURL = URL(string: String(variantLine), relativeTo: baseURL)?.absoluteURL
            if let variantURL {
                let variantData = try await fetchData(url: variantURL, headers: headers)
                return try await resolveSegments(from: variantData, baseURL: variantURL, headers: headers)
            }
        }

        let segments = mediaLines.compactMap { line in
            URL(string: String(line), relativeTo: baseURL)?.absoluteURL
        }
        let isFmp4 = mapURL != nil || segments.contains { $0.pathExtension.lowercased() == "m4s" }
        if let mapURL {
            return ([mapURL] + segments, isFmp4)
        }
        return (segments, isFmp4)
    }
}

struct DownloadItem: Identifiable, Equatable {
    let id: String
    let title: String
    let episode: Int
    let url: URL
    var progress: Double
    var localFile: URL?
    var status: String
    var isHls: Bool
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    @Published private(set) var items: [DownloadItem] = []

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "kyomiru.downloads")
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let fm = FileManager.default
    private let indexKey = "downloads_index.json"
    private let offlineManager = OfflineDownloadManager()

    override init() {
        super.init()
        loadIndex()
        Task { @MainActor in
            resumePendingRemuxes()
        }
    }

    func enqueue(title: String, episode: Int, url: URL) {
        let id = "\(title)|\(episode)|\(url.absoluteString)"
        if items.contains(where: { $0.id == id }) {
            AppLog.debug(.downloads, "download already queued id=\(id)")
            return
        }
        let item = DownloadItem(id: id, title: title, episode: episode, url: url, progress: 0, localFile: nil, status: "Queued", isHls: false)
        items.append(item)
        saveIndex()
        AppLog.debug(.downloads, "download enqueue id=\(id)")
        let task = session.downloadTask(with: url)
        task.taskDescription = id
        task.resume()
        updateStatus(id: id, status: "Downloading")
    }

    func enqueueHLS(title: String, episode: Int, url: URL, headers: [String: String]) {
        let id = "\(title)|\(episode)|\(url.absoluteString)"
        if items.contains(where: { $0.id == id }) {
            AppLog.debug(.downloads, "hls already queued id=\(id)")
            return
        }
        let item = DownloadItem(id: id, title: title, episode: episode, url: url, progress: 0, localFile: nil, status: "Queued", isHls: true)
        items.append(item)
        saveIndex()
        updateStatus(id: id, status: "Downloading HLS")
        AppLog.debug(.downloads, "hls enqueue id=\(id)")
        Task { await downloadHLS(id: id, url: url, headers: headers) }
    }

    func localFileURL(for title: String, episode: Int) -> URL {
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("KyomiruDownloads/\(safe(title))", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("E\(episode).mp4")
    }

    private func localMergedHLSFileURL(for title: String, episode: Int) -> URL {
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("KyomiruDownloads/\(safe(title))", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("E\(episode).ts")
    }

    private func localHLSFolder(title: String, episode: Int) -> URL {
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("KyomiruDownloads/\(safe(title))/E\(episode)", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func safe(_ text: String) -> String {
        text.replacingOccurrences(of: "/", with: "_")
    }

    private func updateProgress(id: String, progress: Double) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].progress = progress
            saveIndex()
        }
    }

    private func updateStatus(id: String, status: String, localFile: URL? = nil) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].status = status
            if let localFile { items[idx].localFile = localFile }
            saveIndex()
            AppLog.debug(.downloads, "download status id=\(id) status=\(status)")
        }
    }

    private func downloadHLS(id: String, url: URL, headers: [String: String]) async {
        do {
            guard let item = items.first(where: { $0.id == id }) else { return }
            AppLog.debug(.downloads, "hls download start id=\(id)")
            updateProgress(id: id, progress: 0)
            let output = localMergedHLSFileURL(for: item.title, episode: item.episode)
            let localFile = try await offlineManager.downloadAndMerge(
                playlistURL: url,
                headers: headers,
                outputURL: output
            ) { [weak self] value in
                Task { @MainActor in
                    self?.updateProgress(id: id, progress: value)
                }
            }
            updateStatus(id: id, status: "Remuxing", localFile: localFile)
            AppLog.debug(.downloads, "hls download complete id=\(id) starting remux")
            Task { @MainActor in
                await remuxIfNeeded(id: id, localFile: localFile)
            }
            markWatched(mediaTitle: item.title, episode: item.episode)
        } catch {
            updateStatus(id: id, status: "Failed")
            AppLog.error(.downloads, "hls download failed id=\(id) error=\(error.localizedDescription)")
        }
    }

    private func remuxIfNeeded(id: String, localFile: URL) async {
        guard localFile.pathExtension.lowercased() == "ts" else {
            updateStatus(id: id, status: "Completed", localFile: localFile)
            return
        }
        let mp4URL = localFile.deletingPathExtension().appendingPathExtension("mp4")
        if fm.fileExists(atPath: mp4URL.path) {
            updateStatus(id: id, status: "Completed", localFile: mp4URL)
            return
        }
        do {
            updateProgress(id: id, progress: 0)
            let output = try await MediaConversionManager.shared.convertToMp4(inputURL: localFile) { [weak self] value in
                Task { @MainActor in
                    self?.updateProgress(id: id, progress: value)
                }
            }
            updateProgress(id: id, progress: 1)
            updateStatus(id: id, status: "Completed", localFile: output)
            AppLog.debug(.downloads, "remux complete id=\(id)")
        } catch {
            updateStatus(id: id, status: "Remux Failed", localFile: localFile)
            AppLog.error(.downloads, "remux failed id=\(id) error=\(error.localizedDescription)")
        }
    }

    private func resumePendingRemuxes() {
        let pending = items.filter { item in
            guard let local = item.localFile else { return false }
            if !fm.fileExists(atPath: local.path) { return false }
            return local.pathExtension.lowercased() == "ts"
        }
        for item in pending {
            updateStatus(id: item.id, status: "Remuxing", localFile: item.localFile)
            Task { @MainActor in
                if let local = item.localFile {
                    await remuxIfNeeded(id: item.id, localFile: local)
                }
            }
        }
    }

    func retryRemux(itemId: String) {
        guard let item = items.first(where: { $0.id == itemId }),
              let local = item.localFile else { return }
        updateStatus(id: itemId, status: "Remuxing", localFile: local)
        Task { @MainActor in
            await remuxIfNeeded(id: itemId, localFile: local)
        }
    }

    private func handleDidFinishDownload(task: URLSessionDownloadTask, location: URL) {
        guard let id = task.taskDescription,
              let item = items.first(where: { $0.id == id }) else { return }
        let target = localFileURL(for: item.title, episode: item.episode)
        try? fm.removeItem(at: target)
        do {
            try fm.moveItem(at: location, to: target)
            updateStatus(id: id, status: "Completed", localFile: target)
            AppLog.debug(.downloads, "download complete id=\(id)")
            markWatched(mediaTitle: item.title, episode: item.episode)
        } catch {
            updateStatus(id: id, status: "Failed")
            AppLog.error(.downloads, "download failed id=\(id) error=\(error.localizedDescription)")
        }
    }

    private func handleDidWriteData(task: URLSessionDownloadTask,
                                    totalBytesWritten: Int64,
                                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0,
              let id = task.taskDescription else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        updateProgress(id: id, progress: progress)
    }

    func delete(itemId: String) {
        if let idx = items.firstIndex(where: { $0.id == itemId }) {
            if let localFile = items[idx].localFile {
                try? fm.removeItem(at: localFile)
                let folder = localFile.deletingLastPathComponent()
                try? fm.removeItem(at: folder)
            }
            items.remove(at: idx)
            saveIndex()
            AppLog.debug(.downloads, "download delete id=\(itemId)")
        }
    }

    func markWatched(mediaTitle: String, episode: Int) {
        AppLog.debug(.downloads, "mark watched title=\(mediaTitle) ep=\(episode)")
        NotificationCenter.default.post(
            name: .downloadCompleted,
            object: nil,
            userInfo: ["title": mediaTitle, "episode": episode]
        )
    }

    private func loadIndex() {
        let url = indexURL()
        guard let data = try? Data(contentsOf: url) else { return }
        guard let decoded = try? JSONDecoder().decode([PersistedDownload].self, from: data) else { return }
        items = decoded.map { $0.asItem() }
        AppLog.debug(.downloads, "download index loaded count=\(self.items.count)")
    }

    private func saveIndex() {
        let url = indexURL()
        let payload = items.map { PersistedDownload(from: $0) }
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func indexURL() -> URL {
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(indexKey)
    }
}

private struct PersistedDownload: Codable {
    let id: String
    let title: String
    let episode: Int
    let url: String
    let progress: Double
    let localFile: String?
    let status: String
    let isHls: Bool

    init(from item: DownloadItem) {
        id = item.id
        title = item.title
        episode = item.episode
        url = item.url.absoluteString
        progress = item.progress
        localFile = item.localFile?.absoluteString
        status = item.status
        isHls = item.isHls
    }

    func asItem() -> DownloadItem {
        DownloadItem(
            id: id,
            title: title,
            episode: episode,
            url: URL(string: url)!,
            progress: progress,
            localFile: localFile.flatMap(URL.init(string:)),
            status: status,
            isHls: isHls
        )
    }
}

extension DownloadManager: @preconcurrency URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        Task { @MainActor in
            self.handleDidFinishDownload(task: downloadTask, location: location)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            self.handleDidWriteData(task: downloadTask,
                                    totalBytesWritten: totalBytesWritten,
                                    totalBytesExpectedToWrite: totalBytesExpectedToWrite)
        }
    }
}

actor MediaConversionManager {
    static let shared = MediaConversionManager()

    enum ConversionError: LocalizedError {
        case exportFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .exportFailed(let message):
                return message
            case .cancelled:
                return "conversion cancelled"
            }
        }
    }

    func convertToMp4(inputURL: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if inputURL.pathExtension.lowercased() == "mp4" {
            return inputURL
        }

        let outputURL = inputURL.deletingPathExtension().appendingPathExtension("mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        let coordinator = NSFileCoordinator()

        return try await withCheckedThrowingContinuation { continuation in
            var coordError: NSError?
            var coordinatedURL: URL?
            coordinator.coordinate(readingItemAt: inputURL, options: .withoutChanges, error: &coordError) { url in
                coordinatedURL = url
            }

            if let coordError {
                continuation.resume(throwing: coordError)
                return
            }

            guard let coordinatedURL else {
                continuation.resume(throwing: ConversionError.exportFailed("File coordination failed"))
                return
            }

            let asset = AVURLAsset(url: coordinatedURL)
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                continuation.resume(throwing: ConversionError.exportFailed("AVAssetExportSession init failed"))
                return
            }

            try? FileManager.default.removeItem(at: outputURL)
            export.outputURL = outputURL
            export.outputFileType = .mp4
            export.shouldOptimizeForNetworkUse = true

            let progressTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            progressTimer.schedule(deadline: .now(), repeating: .milliseconds(200))
            progressTimer.setEventHandler {
                progress?(Double(export.progress))
            }
            progressTimer.resume()

            export.exportAsynchronously {
                progressTimer.cancel()

                switch export.status {
                case .completed:
                    if inputURL.pathExtension.lowercased() == "ts" {
                        try? FileManager.default.removeItem(at: inputURL)
                    }
                    continuation.resume(returning: outputURL)
                case .failed:
                    let message = MediaConversionManager.describe(export.error)
                    continuation.resume(throwing: ConversionError.exportFailed(message))
                case .cancelled:
                    continuation.resume(throwing: ConversionError.cancelled)
                default:
                    let message = MediaConversionManager.describe(export.error)
                    continuation.resume(throwing: ConversionError.exportFailed(message))
                }
            }
        }
    }

    nonisolated static func describe(_ error: Error?) -> String {
        guard let error = error as NSError? else {
            return "unknown export error"
        }
        let domain = error.domain
        let code = error.code
        let message = error.localizedDescription
        let lower = message.lowercased()
        if lower.contains("unsupported") {
            return "unsupported container: \(message)"
        }
        if lower.contains("codec") {
            return "codec mismatch: \(message)"
        }
        if domain == AVFoundationErrorDomain {
            return "AVFoundation error code=\(code) \(message)"
        }
        if domain == NSOSStatusErrorDomain {
            return "OSStatus error code=\(code) \(message)"
        }
        return "Export failed (\(domain)) code=\(code) \(message)"
    }
}

