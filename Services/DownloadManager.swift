import Foundation
import AVFoundation
import CommonCrypto

actor OfflineDownloadManager {
    typealias ProgressHandler = @Sendable (Double) -> Void
    private struct KeySpec: Hashable {
        let url: URL
        let iv: Data?
    }

    private struct SegmentInfo {
        let url: URL
        let key: KeySpec?
        let sequence: Int
    }

    private struct ResolvedPlaylist {
        let lines: [String]
        let segments: [SegmentInfo]
        let mapURL: URL?
        let isFmp4: Bool
        let baseURL: URL
        let usesByteRange: Bool
        let mediaSequence: Int
    }

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
        outputFolder: URL?,
        progress: ProgressHandler?,
        preferLocalHLS: Bool
    ) async throws -> URL {
        let playlistData = try await fetchData(url: playlistURL, headers: headers)
        let resolved = try await resolveSegments(from: playlistData, baseURL: playlistURL, headers: headers)
        let segmentURLs = resolved.segments.map { $0.url }
        let finalOutputURL = resolved.isFmp4
            ? outputURL.deletingPathExtension().appendingPathExtension("mp4")
            : outputURL
        guard !segmentURLs.isEmpty else {
            throw URLError(.cannotParseResponse)
        }

        if preferLocalHLS || resolved.isFmp4 || resolved.usesByteRange {
            if resolved.usesByteRange && !preferLocalHLS {
                AppLog.debug(.downloads, "byte-range playlist detected; forcing local HLS for reliable playback")
            }
            let folder = outputFolder ?? outputURL.deletingPathExtension().appendingPathExtension("hls")
            return try await storeAsLocalHLS(resolved: resolved, outputFolder: folder, headers: headers, progress: progress)
        }
        return try await mergeSegments(resolved: resolved, outputURL: finalOutputURL, headers: headers, progress: progress)
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

    private func resolveSegments(from data: Data, baseURL: URL, headers: [String: String]) async throws -> ResolvedPlaylist {
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let mediaLines = lines.filter { !$0.hasPrefix("#") && !$0.isEmpty }
        let mapLine = lines.first { $0.hasPrefix("#EXT-X-MAP:") }
        let usesByteRange = lines.contains { $0.hasPrefix("#EXT-X-BYTERANGE") }
        let mediaSequence = lines.first { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") }
            .flatMap { Int($0.split(separator: ":").last ?? "") } ?? 0
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

        var segments: [SegmentInfo] = []
        segments.reserveCapacity(mediaLines.count)
        var currentKey: KeySpec?
        var sequence = mediaSequence

        for line in lines {
            if line.hasPrefix("#EXT-X-KEY:") {
                currentKey = parseKeySpec(from: line, baseURL: baseURL)
                continue
            }
            if !line.hasPrefix("#") && !line.isEmpty {
                if let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                    segments.append(SegmentInfo(url: url, key: currentKey, sequence: sequence))
                    sequence += 1
                }
                continue
            }
        }

        let isFmp4 = mapURL != nil || segments.contains { $0.url.pathExtension.lowercased() == "m4s" }
        return ResolvedPlaylist(
            lines: lines,
            segments: segments,
            mapURL: mapURL,
            isFmp4: isFmp4,
            baseURL: baseURL,
            usesByteRange: usesByteRange,
            mediaSequence: mediaSequence
        )
    }

    private func storeAsLocalHLS(
        resolved: ResolvedPlaylist,
        outputFolder: URL,
        headers: [String: String],
        progress: ProgressHandler?
    ) async throws -> URL {
        let baseFolder = outputFolder
        try? fm.removeItem(at: baseFolder)
        try? fm.createDirectory(at: baseFolder, withIntermediateDirectories: true)

        var rewrittenLines: [String] = []
        var segmentIndex = 0
        let keyURLs = collectKeyURLs(from: resolved)
        let total = max(resolved.segments.count
                        + (resolved.mapURL == nil ? 0 : 1)
                        + keyURLs.count, 1)
        var completed = 0
        var keyIndex = 0
        var keyMap: [URL: String] = [:]
        var segmentsWritten = 0

        func writeProgress() {
            let value = Double(completed) / Double(total)
            progress?(value)
        }

        for line in resolved.lines {
            if line.hasPrefix("#EXT-X-KEY:"),
               let keyURL = extractKeyURL(from: line, baseURL: resolved.baseURL) {
                if let localName = keyMap[keyURL] {
                    rewrittenLines.append(replaceKeyURI(in: line, with: localName))
                } else {
                    let ext = keyURL.pathExtension.isEmpty ? "key" : keyURL.pathExtension
                    let localName = String(format: "key_%03d.%@", keyIndex, ext)
                    keyIndex += 1
                    let data = try await fetchData(url: keyURL, headers: headers)
                    let localURL = baseFolder.appendingPathComponent(localName)
                    try data.write(to: localURL, options: .atomic)
                    keyMap[keyURL] = localName
                    completed += 1
                    writeProgress()
                    rewrittenLines.append(replaceKeyURI(in: line, with: localName))
                }
                continue
            }

            if line.hasPrefix("#EXT-X-MAP:"),
               let mapURL = resolved.mapURL {
                let ext = mapURL.pathExtension.isEmpty ? "mp4" : mapURL.pathExtension
                let localName = "init.\(ext)"
                let data = try await fetchData(url: mapURL, headers: headers)
                let localURL = baseFolder.appendingPathComponent(localName)
                try data.write(to: localURL, options: .atomic)
                completed += 1
                writeProgress()
                let replaced = line.replacingOccurrences(of: "URI=\"", with: "URI=\"\(localName)")
                rewrittenLines.append(replaced)
                continue
            }

            if !line.hasPrefix("#") && !line.isEmpty {
                guard segmentIndex < resolved.segments.count else { continue }
                let segmentURL = resolved.segments[segmentIndex].url
                let localName = "segment_\(segmentIndex).ts"
                segmentIndex += 1
                let data = try await fetchData(url: segmentURL, headers: headers)
                let localURL = baseFolder.appendingPathComponent(localName)
                try data.write(to: localURL, options: .atomic)
                completed += 1
                writeProgress()
                rewrittenLines.append(localName)
                segmentsWritten += 1
                continue
            }

            rewrittenLines.append(line)
        }

        let playlistURL = baseFolder.appendingPathComponent("playlist.m3u8")
        let playlistText = rewrittenLines.joined(separator: "\n")
        try playlistText.data(using: .utf8)?.write(to: playlistURL, options: .atomic)
        AppLog.debug(.downloads, "offline hls stored folder=\(baseFolder.path) segments=\(segmentsWritten) keys=\(keyMap.count) map=\(resolved.mapURL != nil)")
        return playlistURL
    }

    private func mergeSegments(
        resolved: ResolvedPlaylist,
        outputURL: URL,
        headers: [String: String],
        progress: ProgressHandler?
    ) async throws -> URL {
        let segments = resolved.segments
        guard !segments.isEmpty else {
            throw URLError(.cannotParseResponse)
        }

        try? fm.removeItem(at: outputURL)
        fm.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        let total = max(segments.count, 1)
        var completed = 0
        var expectedBytes: Int64 = 0
        var keyCache: [URL: Data] = [:]
        let needsDecryption = segments.contains { $0.key != nil }
        if needsDecryption {
            AppLog.debug(.downloads, "hls merge decrypt: AES-128 key detected; decrypting segments before merge")
        }

        for (index, segment) in segments.enumerated() {
            var data = try await fetchData(url: segment.url, headers: headers)
            if let keySpec = segment.key {
                let keyData: Data
                if let cached = keyCache[keySpec.url] {
                    keyData = cached
                } else {
                    keyData = try await fetchData(url: keySpec.url, headers: headers)
                    keyCache[keySpec.url] = keyData
                }
                data = try decryptAES128(data: data, key: keyData, iv: keySpec.iv, sequence: segment.sequence)
            }
            expectedBytes += Int64(data.count)
            try handle.write(contentsOf: data)
            completed = index + 1
            let value = Double(completed) / Double(total)
            progress?(value)
        }

        try handle.synchronize()
        let attrs = try fm.attributesOfItem(atPath: outputURL.path)
        let fileBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        AppLog.debug(.downloads, "hls merge complete segments=\(segments.count) expectedBytes=\(expectedBytes) actualBytes=\(fileBytes)")
        if fileBytes != expectedBytes {
            AppLog.error(.downloads, "hls merge size mismatch expected=\(expectedBytes) actual=\(fileBytes) path=\(outputURL.path)")
            throw URLError(.cannotDecodeContentData)
        }

        return outputURL
    }

    private func collectKeyURLs(from resolved: ResolvedPlaylist) -> [URL] {
        var urls: [URL] = []
        for line in resolved.lines {
            guard line.hasPrefix("#EXT-X-KEY:"),
                  let url = extractKeyURL(from: line, baseURL: resolved.baseURL) else { continue }
            if !urls.contains(url) {
                urls.append(url)
            }
        }
        return urls
    }

    private func extractKeyURL(from line: String, baseURL: URL) -> URL? {
        guard let range = line.range(of: "URI=") else { return nil }
        var value = String(line[range.upperBound...])
        if let comma = value.firstIndex(of: ",") {
            value = String(value[..<comma])
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\"") { value.removeFirst() }
        if value.hasSuffix("\"") { value.removeLast() }
        guard !value.isEmpty else { return nil }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    private func parseKeySpec(from line: String, baseURL: URL) -> KeySpec? {
        guard line.hasPrefix("#EXT-X-KEY:") else { return nil }
        guard line.contains("METHOD=AES-128") else { return nil }
        guard let url = extractKeyURL(from: line, baseURL: baseURL) else { return nil }
        let iv = extractIV(from: line)
        return KeySpec(url: url, iv: iv)
    }

    private func extractIV(from line: String) -> Data? {
        guard let range = line.range(of: "IV=") else { return nil }
        var value = String(line[range.upperBound...])
        if let comma = value.firstIndex(of: ",") {
            value = String(value[..<comma])
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("0x") {
            value = String(value.dropFirst(2))
        }
        guard value.count >= 2 else { return nil }
        return Data(hexString: value)
    }

    private func decryptAES128(data: Data, key: Data, iv: Data?, sequence: Int) throws -> Data {
        guard key.count == kCCKeySizeAES128 else {
            AppLog.error(.downloads, "hls decrypt failed: key length \(key.count) != 16")
            throw URLError(.cannotDecodeContentData)
        }
        let ivData = iv ?? makeIV(sequence: sequence)
        guard ivData.count == kCCBlockSizeAES128 else {
            AppLog.error(.downloads, "hls decrypt failed: iv length \(ivData.count) != 16")
            throw URLError(.cannotDecodeContentData)
        }

        var outLength = 0
        let outCapacity = data.count + kCCBlockSizeAES128
        var out = Data(count: outCapacity)
        let status = out.withUnsafeMutableBytes { outBytes in
            let outBase = outBytes.baseAddress
            return data.withUnsafeBytes { dataBytes in
                return key.withUnsafeBytes { keyBytes in
                    return ivData.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBytes.baseAddress, kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            outBase, outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            AppLog.error(.downloads, "hls decrypt failed status=\(status)")
            throw URLError(.cannotDecodeContentData)
        }
        out.removeSubrange(outLength..<out.count)
        return out
    }

    private func makeIV(sequence: Int) -> Data {
        var iv = [UInt8](repeating: 0, count: 16)
        let seq = UInt64(sequence).bigEndian
        withUnsafeBytes(of: seq) { bytes in
            for i in 0..<8 {
                iv[8 + i] = bytes[i]
            }
        }
        return Data(iv)
    }

    private func replaceKeyURI(in line: String, with localName: String) -> String {
        guard let range = line.range(of: "URI=") else { return line }
        let prefix = line[..<range.upperBound]
        let suffix = line[range.upperBound...]
        if suffix.hasPrefix("\"") {
            if let end = suffix.dropFirst().firstIndex(of: "\"") {
                let tail = suffix[end...]
                let quote = "\""
                return prefix + quote + localName + quote + tail
            }
        } else if let end = suffix.firstIndex(of: ",") {
            let tail = suffix[end...]
            return prefix + localName + tail
        }
        return prefix + localName
    }
}

private extension Data {
    init?(hexString: String) {
        let len = hexString.count
        guard len % 2 == 0 else { return nil }
        var data = Data(capacity: len / 2)
        var index = hexString.startIndex
        for _ in 0..<(len / 2) {
            let nextIndex = hexString.index(index, offsetBy: 2)
            let byteString = hexString[index..<nextIndex]
            guard let num = UInt8(byteString, radix: 16) else { return nil }
            data.append(num)
            index = nextIndex
        }
        self = data
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
        return folder.appendingPathComponent("Episode(\(episode)).ts")
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
                outputURL: output,
                outputFolder: nil,
                progress: { [weak self] value in
                Task { @MainActor in
                    self?.updateProgress(id: id, progress: value)
                }
            },
                preferLocalHLS: false
            )
            if MPVSupport.isAvailable {
                updateStatus(id: id, status: "Completed", localFile: localFile)
                AppLog.debug(.downloads, "hls download complete id=\(id) (mpv)")
            } else {
                updateStatus(id: id, status: "Remuxing", localFile: localFile)
                AppLog.debug(.downloads, "hls download complete id=\(id) starting remux")
                Task { @MainActor in
                    await remuxIfNeeded(id: id, localFile: localFile)
                }
            }
            let segmentFolder = localHLSFolder(title: item.title, episode: item.episode)
            if fm.fileExists(atPath: segmentFolder.path) {
                try? fm.removeItem(at: segmentFolder)
                AppLog.debug(.downloads, "hls cleanup removed segment folder=\(segmentFolder.path)")
            }
            markWatched(mediaTitle: item.title, episode: item.episode)
        } catch {
            updateStatus(id: id, status: "Failed")
            AppLog.error(.downloads, "hls download failed id=\(id) error=\(error.localizedDescription)")
        }
    }

    private func remuxIfNeeded(id: String, localFile: URL) async {
        if MPVSupport.isAvailable {
            updateStatus(id: id, status: "Completed", localFile: localFile)
            return
        }
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
        if MPVSupport.isAvailable {
            for item in items {
                guard let local = item.localFile, fm.fileExists(atPath: local.path) else { continue }
                updateStatus(id: item.id, status: "Completed", localFile: local)
            }
            return
        }
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
        if MPVSupport.isAvailable {
            updateStatus(id: itemId, status: "Completed", localFile: local)
            return
        }
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

    func playableURL(for item: DownloadItem) -> URL? {
        if let local = item.localFile {
            let resolved = resolvePlayableURL(localFile: local, item: item)
            if resolved == nil {
                AppLog.error(.downloads, "offline resolve failed localFile=\(local.path) title=\(item.title) ep=\(item.episode)")
            }
            return resolved
        }
        let resolved = resolveFallbackPlayableURL(for: item)
        if resolved == nil {
            AppLog.error(.downloads, "offline resolve failed no localFile title=\(item.title) ep=\(item.episode)")
        }
        return resolved
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

    private func resolvePlayableURL(localFile: URL, item: DownloadItem) -> URL {
        let ext = localFile.pathExtension.lowercased()
        let exists = fm.fileExists(atPath: localFile.path)
        AppLog.debug(.downloads, "offline resolve path=\(localFile.path) exists=\(exists) isDir=\(localFile.hasDirectoryPath)")

        if ext == "ts", isMergedEpisodeFile(localFile, item: item) {
            AppLog.debug(.downloads, "offline resolve using merged episode ts path=\(localFile.path)")
            return localFile
        }

        if item.isHls {
            if let segmentFolder = findSegmentFolder(for: item, localFile: localFile),
               let playlist = ensurePlaylist(forFolder: segmentFolder, prefix: nil) {
                AppLog.debug(.downloads, "offline resolve using playlist path=\(playlist.path)")
                return playlist
            }
            let candidateFolders = [
                localHLSFolder(title: item.title, episode: item.episode),
                localFile.deletingPathExtension(),
                localFile.deletingLastPathComponent()
            ]
            for folder in candidateFolders {
                let count = countSegments(in: folder, prefix: nil)
                AppLog.debug(.downloads, "offline resolve candidate folder=\(folder.path) segments=\(count)")
            }
        }

        if !exists {
            if let fallback = resolveFallbackPlayableURL(for: item) {
                return fallback
            }
        }

        if ext == "m3u8" {
            if hasLocalPlaylistSegments(localFile) {
                AppLog.debug(.downloads, "offline resolve using m3u8 path=\(localFile.path)")
                return localFile
            }
            AppLog.error(.downloads, "offline resolve playlist missing segments path=\(localFile.path)")
        }

        if localFile.hasDirectoryPath {
            if let playlist = ensurePlaylist(forFolder: localFile, prefix: nil) {
                AppLog.debug(.downloads, "offline resolve using playlist path=\(playlist.path)")
                return playlist
            }
            return localFile
        }

        if ext == "ts" {
            let folder = localFile.deletingLastPathComponent()
            let baseName = localFile.deletingPathExtension().lastPathComponent
            if countSegments(in: folder, prefix: baseName) > 1,
               let playlist = ensurePlaylist(forFolder: folder, prefix: baseName) {
                AppLog.debug(.downloads, "offline resolve using playlist path=\(playlist.path)")
                return playlist
            }
            let playlist = folder.appendingPathComponent("playlist.m3u8")
            if fm.fileExists(atPath: playlist.path) {
                AppLog.debug(.downloads, "offline resolve using existing playlist path=\(playlist.path)")
                return playlist
            }
        }

        AppLog.debug(.downloads, "offline resolve using file path=\(localFile.path)")
        return localFile
    }

    private func resolveFallbackPlayableURL(for item: DownloadItem) -> URL? {
        let folder = localHLSFolder(title: item.title, episode: item.episode)
        if fm.fileExists(atPath: folder.path) {
            if let playlist = ensurePlaylist(forFolder: folder, prefix: nil) {
                AppLog.debug(.downloads, "offline fallback using playlist path=\(playlist.path)")
                return playlist
            }
        }

        let mergedTs = localMergedHLSFileURL(for: item.title, episode: item.episode)
        if fm.fileExists(atPath: mergedTs.path) {
            AppLog.debug(.downloads, "offline fallback using merged ts path=\(mergedTs.path)")
            return mergedTs
        }

        let mp4 = localFileURL(for: item.title, episode: item.episode)
        if fm.fileExists(atPath: mp4.path) {
            AppLog.debug(.downloads, "offline fallback using mp4 path=\(mp4.path)")
            return mp4
        }

        AppLog.error(.downloads, "offline resolve failed title=\(item.title) ep=\(item.episode)")
        return nil
    }

    private func ensurePlaylist(forFolder folder: URL, prefix: String?) -> URL? {
        let playlist = folder.appendingPathComponent("playlist.m3u8")
        if fm.fileExists(atPath: playlist.path) {
            return playlist
        }

        let segments = collectSegments(in: folder, prefix: prefix)

        if segments.isEmpty {
            AppLog.debug(.downloads, "offline playlist not generated (no segments) folder=\(folder.path)")
            return nil
        }

        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:3")
        lines.append("#EXT-X-TARGETDURATION:10")
        lines.append("#EXT-X-MEDIA-SEQUENCE:0")

        for segment in segments {
            lines.append("#EXTINF:10.0,")
            lines.append(segment.lastPathComponent)
        }
        lines.append("#EXT-X-ENDLIST")

        let text = lines.joined(separator: "\n")
        do {
            try text.data(using: .utf8)?.write(to: playlist, options: .atomic)
            AppLog.debug(.downloads, "offline playlist generated path=\(playlist.path)")
            return playlist
        } catch {
            AppLog.error(.downloads, "offline playlist write failed path=\(playlist.path) error=\(error.localizedDescription)")
            return nil
        }
    }

    private func hasSegments(in folder: URL, prefix: String? = nil) -> Bool {
        countSegments(in: folder, prefix: prefix) > 0
    }

    private func countSegments(in folder: URL, prefix: String? = nil) -> Int {
        collectSegments(in: folder, prefix: prefix).count
    }

    private func collectSegments(in folder: URL, prefix: String?) -> [URL] {
        guard fm.fileExists(atPath: folder.path) else { return [] }
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        var segments: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "ts" || ext == "m4s" else { continue }
            if prefix == nil, isEpisodeLikeSegment(fileURL) {
                continue
            }
            if let prefix, !fileURL.deletingPathExtension().lastPathComponent.hasPrefix(prefix) {
                continue
            }
            segments.append(fileURL)
        }
        return segments.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func hasLocalPlaylistSegments(_ playlistURL: URL) -> Bool {
        guard let text = try? String(contentsOf: playlistURL) else { return false }
        let base = playlistURL.deletingLastPathComponent()
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var hits = 0
        for line in lines {
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let candidate = URL(string: line, relativeTo: base)?.absoluteURL
                ?? base.appendingPathComponent(line)
            if fm.fileExists(atPath: candidate.path) {
                hits += 1
            }
        }
        return hits > 0
    }

    private func isMergedEpisodeFile(_ url: URL, item: DownloadItem) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        return name == "Episode(\(item.episode))"
    }

    private func isEpisodeLikeSegment(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("E") else { return false }
        let digits = name.dropFirst()
        return !digits.isEmpty && digits.allSatisfy { $0.isNumber }
    }

    private func findSegmentFolder(for item: DownloadItem, localFile: URL) -> URL? {
        let titleFolder = localFile.deletingLastPathComponent()
        let sibling = localFile.deletingPathExtension()
        let candidates = [
            localHLSFolder(title: item.title, episode: item.episode),
            sibling,
            titleFolder
        ]

        var bestFolder: URL?
        var bestCount = 0
        for folder in candidates {
            let count = countSegments(in: folder, prefix: nil)
            if count > bestCount {
                bestCount = count
                bestFolder = folder
            }
        }

        if bestCount >= 3, let bestFolder {
            AppLog.debug(.downloads, "offline resolve segments folder=\(bestFolder.path) count=\(bestCount)")
            return bestFolder
        }

        if let auto = findBestSegmentFolder(in: titleFolder) {
            AppLog.debug(.downloads, "offline resolve segments folder=\(auto.path) count=\(countSegments(in: auto))")
            return auto
        }

        return nil
    }

    private func findBestSegmentFolder(in root: URL) -> URL? {
        guard fm.fileExists(atPath: root.path) else { return nil }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }

        var counts: [URL: Int] = [:]
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "ts" else { continue }
            let folder = fileURL.deletingLastPathComponent()
            counts[folder, default: 0] += 1
        }

        let sorted = counts.sorted { $0.value > $1.value }
        guard let best = sorted.first, best.value >= 3 else { return nil }
        return best.key
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





