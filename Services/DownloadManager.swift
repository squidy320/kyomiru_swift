import Foundation
import AVFoundation
import CommonCrypto
import ffmpegkit
import VideoToolbox
import UIKit

struct AniSkipSegment: Codable, Equatable, Hashable {
    let type: String
    let start: Double
    let end: Double
}

final class AniSkipService {
    private let session: URLSession

    init(session: URLSession = .custom) {
        self.session = session
    }

    func fetchSkipSegments(malId: Int, episode: Int) async -> [AniSkipSegment] {
        let base = "https://api.aniskip.com/v2/skip-times/\(malId)/\(episode)"
        let types = [
            "op", "ed", "mixed-op", "mixed-ed", "recap", "preview"
        ]
        let query = types.map { "types=\($0)" }.joined(separator: "&") + "&episodeLength=0"
        guard let url = URL(string: "\(base)?\(query)") else {
            return []
        }
        AppLog.debug(.player, "aniskip: request start malId=\(malId) ep=\(episode) url=\(url.absoluteString)")
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                AppLog.error(.player, "aniskip: request failed malId=\(malId) ep=\(episode) status=\(code)")
                return []
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let decoded = try decoder.decode(AniSkipResponse.self, from: data)
            AppLog.debug(.player, "aniskip: request success malId=\(malId) ep=\(episode) count=\(decoded.results.count)")
            return decoded.results.map {
                AniSkipSegment(
                    type: $0.skipType,
                    start: $0.interval.startTime,
                    end: $0.interval.endTime
                )
            }
        } catch {
            AppLog.error(.player, "aniskip: request error malId=\(malId) ep=\(episode) \(error.localizedDescription)")
            return []
        }
    }
}

private struct AniSkipResponse: Decodable {
    let results: [AniSkipResult]
}

private struct AniSkipResult: Decodable {
    let skipType: String
    let interval: AniSkipInterval
}

private struct AniSkipInterval: Decodable {
    let startTime: Double
    let endTime: Double
}

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
    let headers: [String: String]?
    var progress: Double
    var localFile: URL?
    var status: String
    var isHls: Bool
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var speedBytesPerSec: Double?
    var mediaId: Int?
    var malId: Int?
    var posterURL: URL?
    var bannerURL: URL?
    var totalEpisodes: Int?
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    @Published private(set) var items: [DownloadItem] = []
    private var aniSkipCache: [String: [AniSkipSegment]] = [:]
    private let aniSkipIndexKey = "aniskip_cache.json"
    private var speedSamples: [String: (bytes: Int64, time: TimeInterval)] = [:]

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
        loadAniSkipCache()
        Task { @MainActor in
            resumePendingRemuxes()
        }
    }

    func cachedSkipSegments(malId: Int, episode: Int) -> [AniSkipSegment]? {
        aniSkipCache[aniSkipKey(malId: malId, episode: episode)]
    }

    func storeSkipSegments(_ segments: [AniSkipSegment], malId: Int, episode: Int) {
        let key = aniSkipKey(malId: malId, episode: episode)
        aniSkipCache[key] = segments
        saveAniSkipCache()
    }

    func buildImportCandidates(urls: [URL]) -> [EpisodeImportCandidate] {
        urls.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            return EpisodeImportCandidate(
                url: url,
                fileName: name,
                episodeNumber: parseEpisodeNumber(from: name)
            )
        }
    }

    @MainActor
    func importEpisodes(media: MediaItem, candidates: [EpisodeImportCandidate]) async -> (imported: Int, skipped: Int, failed: [String]) {
        var bgTaskId = UIBackgroundTaskIdentifier.invalid
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "kyomiru.import") {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = UIBackgroundTaskIdentifier.invalid
        }
        defer {
            if bgTaskId != UIBackgroundTaskIdentifier.invalid {
                UIApplication.shared.endBackgroundTask(bgTaskId)
                bgTaskId = UIBackgroundTaskIdentifier.invalid
            }
        }
        let sorted = candidates.compactMap { candidate -> EpisodeImportCandidate? in
            guard let _ = candidate.episodeNumber else { return nil }
            return candidate
        }.sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }

        var imported = 0
        var skipped = 0
        var failed: [String] = []

        for candidate in sorted {
            guard let episodeNumber = candidate.episodeNumber else { continue }
            let outputURL = localFileURL(for: media.title, episode: episodeNumber)
            if let _ = downloadedItem(title: media.title, episode: episodeNumber) {
                skipped += 1
                continue
            }
            if fm.fileExists(atPath: outputURL.path) {
                registerImportedEpisode(media: media, episode: episodeNumber, fileURL: outputURL)
                imported += 1
                continue
            }

            let ext = candidate.url.pathExtension.lowercased()
            let supported = ["mp4", "m4v", "mov", "ts", "m3u8"]
            if !supported.contains(ext) {
                failed.append("\(candidate.fileName) (unsupported)")
                continue
            }

            var accessGranted = false
            if candidate.url.startAccessingSecurityScopedResource() {
                accessGranted = true
            }
            defer {
                if accessGranted { candidate.url.stopAccessingSecurityScopedResource() }
            }

            let tempURL = fm.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext.isEmpty ? "mp4" : ext)

            do {
                if fm.fileExists(atPath: tempURL.path) {
                    try fm.removeItem(at: tempURL)
                }
                try await ensureLocalFile(candidate.url)
                let coordinator = NSFileCoordinator()
                var coordinatorError: NSError?
                var copyError: Error?
                coordinator.coordinate(readingItemAt: candidate.url, options: .withoutChanges, error: &coordinatorError) { url in
                    do {
                        try fm.copyItem(at: url, to: tempURL)
                    } catch {
                        copyError = error
                    }
                }
                if let coordinatorError {
                    throw coordinatorError
                }
                if let copyError {
                    throw copyError
                }
            } catch {
                failed.append("\(candidate.fileName) (copy failed)")
                continue
            }

            do {
                if ["mp4", "m4v", "mov"].contains(ext) {
                    let asset = AVAsset(url: tempURL)
                    let hasVideo = !asset.tracks(withMediaType: .video).isEmpty
                    if asset.isPlayable && hasVideo {
                        if fm.fileExists(atPath: outputURL.path) {
                            try fm.removeItem(at: outputURL)
                        }
                        try fm.copyItem(at: tempURL, to: outputURL)
                        try? fm.removeItem(at: tempURL)
                    } else {
                        _ = try await MediaConversionManager.shared.remuxToMp4(
                            inputURL: tempURL,
                            outputURL: outputURL
                        )
                    }
                } else {
                    _ = try await MediaConversionManager.shared.remuxToMp4(
                        inputURL: tempURL,
                        outputURL: outputURL
                    )
                }
                registerImportedEpisode(media: media, episode: episodeNumber, fileURL: outputURL)
                imported += 1
            } catch {
                failed.append("\(candidate.fileName) (convert failed)")
                try? fm.removeItem(at: tempURL)
            }
        }

        if imported > 0 {
            saveIndex()
        }
        return (imported, skipped, failed)
    }

    private func ensureLocalFile(_ url: URL) async throws {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values.isUbiquitousItem == true else { return }
        if values.ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.current {
            return
        }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let refreshed = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if refreshed?.ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.current {
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        throw MediaConversionManager.ConversionError.exportFailed("file download timeout")
    }

    func enqueue(title: String, episode: Int, url: URL, media: MediaItem? = nil) {
        let id = "\(title)|\(episode)|\(url.absoluteString)"
        if items.contains(where: { $0.id == id }) {
            AppLog.debug(.downloads, "download already queued id=\(id)")
            return
        }
        let item = DownloadItem(
            id: id,
            title: title,
            episode: episode,
            url: url,
            headers: nil,
            progress: 0,
            localFile: nil,
            status: "Queued",
            isHls: false,
            downloadedBytes: nil,
            totalBytes: nil,
            speedBytesPerSec: nil,
            mediaId: media?.externalId,
            malId: nil,
            posterURL: media?.posterImageURL,
            bannerURL: media?.heroImageURL,
            totalEpisodes: media?.totalEpisodes
        )
        items.append(item)
        saveIndex()
        AppLog.debug(.downloads, "download enqueue id=\(id)")
        let task = session.downloadTask(with: url)
        task.taskDescription = id
        task.resume()
        updateStatus(id: id, status: "Downloading")
    }

    func enqueueHLS(title: String, episode: Int, url: URL, headers: [String: String], media: MediaItem? = nil) {
        let id = "\(title)|\(episode)|\(url.absoluteString)"
        if items.contains(where: { $0.id == id }) {
            AppLog.debug(.downloads, "hls already queued id=\(id)")
            return
        }
        let item = DownloadItem(
            id: id,
            title: title,
            episode: episode,
            url: url,
            headers: headers,
            progress: 0,
            localFile: nil,
            status: "Queued",
            isHls: true,
            downloadedBytes: nil,
            totalBytes: nil,
            speedBytesPerSec: nil,
            mediaId: media?.externalId,
            malId: nil,
            posterURL: media?.posterImageURL,
            bannerURL: media?.heroImageURL,
            totalEpisodes: media?.totalEpisodes
        )
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

    private func updateTransferStats(id: String, written: Int64, expected: Int64) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let now = Date().timeIntervalSince1970
        let previous = speedSamples[id]
        var speed: Double? = items[idx].speedBytesPerSec
        if let previous {
            let deltaBytes = written - previous.bytes
            let deltaTime = now - previous.time
            if deltaBytes > 0, deltaTime > 0.2 {
                speed = Double(deltaBytes) / deltaTime
            }
        }
        speedSamples[id] = (written, now)
        items[idx].downloadedBytes = written
        items[idx].totalBytes = expected > 0 ? expected : nil
        items[idx].speedBytesPerSec = speed
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
            let headerPayload = item.headers ?? headers
            let directMp4 = localFileURL(for: item.title, episode: item.episode)
            if fm.fileExists(atPath: directMp4.path) {
                AppLog.debug(.downloads, "hls direct mp4 exists id=\(id) path=\(directMp4.path)")
                updateStatus(id: id, status: "Completed", localFile: directMp4)
                // download completion no longer marks watched
                return
            }

            AppLog.debug(.downloads, "hls direct remux start id=\(id)")
            updateStatus(id: id, status: "Remuxing", localFile: nil)
            do {
                let output = try await MediaConversionManager.shared.convertHlsToMp4(
                    playlistURL: url,
                    headers: headerPayload,
                    outputURL: directMp4
                ) { [weak self] value in
                    Task { @MainActor in
                        self?.updateProgress(id: id, progress: value)
                    }
                }
                updateProgress(id: id, progress: 1)
                updateStatus(id: id, status: "Completed", localFile: output)
                AppLog.debug(.downloads, "hls direct remux complete id=\(id) output=\(output.path)")
                // download completion no longer marks watched
                return
            } catch {
                AppLog.error(.downloads, "hls direct remux failed id=\(id) error=\(error.localizedDescription) fallback=merge")
            }

            let output = localMergedHLSFileURL(for: item.title, episode: item.episode)
            let localFile = try await offlineManager.downloadAndMerge(
                playlistURL: url,
                headers: headerPayload,
                outputURL: output,
                outputFolder: nil,
                progress: { [weak self] value in
                    Task { @MainActor in
                        self?.updateProgress(id: id, progress: value)
                    }
                },
                preferLocalHLS: false
            )
            updateStatus(id: id, status: "Remuxing", localFile: localFile)
            AppLog.debug(.downloads, "hls download complete id=\(id) starting remux")
            Task { @MainActor in
                await remuxIfNeeded(id: id, localFile: localFile)
            }
            let segmentFolder = localHLSFolder(title: item.title, episode: item.episode)
            if fm.fileExists(atPath: segmentFolder.path) {
                try? fm.removeItem(at: segmentFolder)
                AppLog.debug(.downloads, "hls cleanup removed segment folder=\(segmentFolder.path)")
            }
            // download completion no longer marks watched
        } catch {
            updateStatus(id: id, status: "Failed")
            AppLog.error(.downloads, "hls download failed id=\(id) error=\(error.localizedDescription)")
        }
    }

    private func remuxIfNeeded(id: String, localFile: URL) async {
        guard localFile.pathExtension.lowercased() == "ts" else {
            AppLog.debug(.downloads, "remux skipped id=\(id) reason=not-ts ext=\(localFile.pathExtension)")
            updateStatus(id: id, status: "Completed", localFile: localFile)
            return
        }
        let mp4URL = localFile.deletingPathExtension().appendingPathExtension("mp4")
        if fm.fileExists(atPath: mp4URL.path) {
            AppLog.debug(.downloads, "remux skipped id=\(id) reason=mp4-exists path=\(mp4URL.path)")
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
            if let idx = items.firstIndex(where: { $0.id == id }) {
                let size = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
                items[idx].downloadedBytes = size > 0 ? size : nil
                items[idx].totalBytes = size > 0 ? size : items[idx].totalBytes
                items[idx].speedBytesPerSec = nil
            }
            updateStatus(id: id, status: "Completed", localFile: target)
            AppLog.debug(.downloads, "download complete id=\(id)")
            // download completion no longer marks watched
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
        updateTransferStats(id: id, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
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

    func downloadedItem(title: String, episode: Int) -> DownloadItem? {
        let key = normalizeTitle(title)
        return items.first(where: {
            $0.status == "Completed" &&
            $0.episode == episode &&
            normalizeTitle($0.title) == key
        })
    }

    func updateMediaInfo(title: String, media: MediaItem) {
        let key = normalizeTitle(title)
        var didUpdate = false
        for idx in items.indices {
            guard normalizeTitle(items[idx].title) == key else { continue }
            if items[idx].mediaId == nil {
                items[idx].mediaId = media.externalId
                didUpdate = true
            }
            if items[idx].posterURL == nil, let poster = media.posterImageURL {
                items[idx].posterURL = poster
                didUpdate = true
            }
            if items[idx].bannerURL == nil, let banner = media.heroImageURL {
                items[idx].bannerURL = banner
                didUpdate = true
            }
            if items[idx].totalEpisodes == nil, let total = media.totalEpisodes {
                items[idx].totalEpisodes = total
                didUpdate = true
            }
        }
        if didUpdate {
            saveIndex()
        }
    }

    // markWatched removed: downloads no longer auto-sync watched state

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

    private func loadAniSkipCache() {
        let url = aniSkipIndexURL()
        guard let data = try? Data(contentsOf: url) else { return }
        guard let decoded = try? JSONDecoder().decode([String: [AniSkipSegment]].self, from: data) else { return }
        aniSkipCache = decoded
    }

    private func saveAniSkipCache() {
        let url = aniSkipIndexURL()
        if let data = try? JSONEncoder().encode(aniSkipCache) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func aniSkipIndexURL() -> URL {
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(aniSkipIndexKey)
    }

    private func aniSkipKey(malId: Int, episode: Int) -> String {
        "\(malId)|\(episode)"
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

    private func normalizeTitle(_ title: String) -> String {
        let lowered = title.lowercased()
        let filtered = lowered.filter { $0.isLetter || $0.isNumber }
        return filtered
    }

    private func parseEpisodeNumber(from fileName: String) -> Int? {
        let patterns = [
            "S\\d+E(\\d+)",
            "\\bEP\\s*(\\d{1,3})\\b",
            "\\bE(\\d{1,3})\\b",
            "\\bEpisode\\s*(\\d{1,3})\\b",
            "\\b-\\s*(\\d{1,3})\\b"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(fileName.startIndex..., in: fileName)
                if let match = regex.firstMatch(in: fileName, options: [], range: range),
                   match.numberOfRanges > 1,
                   let numRange = Range(match.range(at: 1), in: fileName),
                   let value = Int(fileName[numRange]) {
                    return value
                }
            }
        }
        return nil
    }

    private func registerImportedEpisode(media: MediaItem, episode: Int, fileURL: URL) {
        let id = "\(media.title)|\(episode)|\(fileURL.absoluteString)"
        let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
        let item = DownloadItem(
            id: id,
            title: media.title,
            episode: episode,
            url: fileURL,
            headers: nil,
            progress: 1.0,
            localFile: fileURL,
            status: "Completed",
            isHls: false,
            downloadedBytes: size,
            totalBytes: size,
            speedBytesPerSec: nil,
            mediaId: media.externalId,
            malId: nil,
            posterURL: media.posterImageURL,
            bannerURL: media.heroImageURL,
            totalEpisodes: media.totalEpisodes
        )
        if !items.contains(where: { $0.id == item.id }) {
            items.append(item)
        }
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
    let headers: [String: String]?
    let mediaId: Int?
    let malId: Int?
    let posterURL: String?
    let bannerURL: String?
    let totalEpisodes: Int?

    init(from item: DownloadItem) {
        id = item.id
        title = item.title
        episode = item.episode
        url = item.url.absoluteString
        progress = item.progress
        localFile = item.localFile?.absoluteString
        status = item.status
        isHls = item.isHls
        headers = item.headers
        mediaId = item.mediaId
        malId = item.malId
        posterURL = item.posterURL?.absoluteString
        bannerURL = item.bannerURL?.absoluteString
        totalEpisodes = item.totalEpisodes
    }

    func asItem() -> DownloadItem {
        DownloadItem(
            id: id,
            title: title,
            episode: episode,
            url: URL(string: url)!,
            headers: headers,
            progress: progress,
            localFile: localFile.flatMap(URL.init(string:)),
            status: status,
            isHls: isHls,
            downloadedBytes: nil,
            totalBytes: nil,
            speedBytesPerSec: nil,
            mediaId: mediaId,
            malId: malId,
            posterURL: posterURL.flatMap(URL.init(string:)),
            bannerURL: bannerURL.flatMap(URL.init(string:)),
            totalEpisodes: totalEpisodes
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

        do {
            AppLog.debug(.downloads, "vt remux start input=\(inputURL.path) output=\(outputURL.path)")
            let output = try await convertWithVideoToolbox(inputURL: inputURL, outputURL: outputURL)
            AppLog.debug(.downloads, "vt remux success output=\(output.path)")
            return output
        } catch {
            AppLog.error(.downloads, "vt remux failed input=\(inputURL.path) error=\(error.localizedDescription) fallback=ffmpeg")
        }
        return try await convertToMp4WithFFmpeg(inputURL: inputURL, outputURL: outputURL, progress: progress)
    }

    func remuxToMp4(
        inputURL: URL,
        outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        do {
            AppLog.debug(.downloads, "vt remux start input=\(inputURL.path) output=\(outputURL.path)")
            let output = try await convertWithVideoToolbox(inputURL: inputURL, outputURL: outputURL)
            AppLog.debug(.downloads, "vt remux success output=\(output.path)")
            return output
        } catch {
            AppLog.error(.downloads, "vt remux failed input=\(inputURL.path) error=\(error.localizedDescription) fallback=ffmpeg")
        }
        return try await convertToMp4WithFFmpeg(inputURL: inputURL, outputURL: outputURL, progress: progress)
    }

    func convertHlsToMp4(
        playlistURL: URL,
        headers: [String: String]?,
        outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        let playlistPath = playlistURL.absoluteString
        let outputPath = outputURL.path
        try? FileManager.default.removeItem(at: outputURL)

        let headerString = buildHeaderString(headers)
        let headerArg = headerString.isEmpty ? "" : "-headers \(quoted(value: headerString))"
        let duration = await probeDurationSeconds(path: playlistPath)
        let baseArgs = "-y -protocol_whitelist file,http,https,tcp,tls,crypto -allowed_extensions ALL -fflags +genpts+discardcorrupt -err_detect ignore_err -avoid_negative_ts make_zero -dn -sn \(headerArg) -i \(quoted(value: playlistPath)) -map 0:v? -map 0:a?"
        let commandWithBsf = "\(baseArgs) -c:v copy -c:a aac -b:a 160k -ac 2 -bsf:a aac_adtstoasc -movflags +faststart -max_muxing_queue_size 1024 \(quoted(path: outputPath))"
        let commandNoBsf = "\(baseArgs) -c:v copy -c:a aac -b:a 160k -ac 2 -movflags +faststart -max_muxing_queue_size 1024 \(quoted(path: outputPath))"
        let commandAudioReencode = commandNoBsf
        let commandFullTranscode = "\(baseArgs) -c:v libx264 -preset veryfast -crf 21 -pix_fmt yuv420p -c:a aac -b:a 160k -ac 2 -movflags +faststart -max_muxing_queue_size 1024 \(quoted(path: outputPath))"

        AppLog.debug(.downloads, "ffmpeg hls start input=\(playlistPath) output=\(outputPath) duration=\(duration) headers=\(headerString.isEmpty ? 0 : headerString.count) audio=aac")

        let first = await runFFmpeg(commandWithBsf, duration: duration, progress: progress)
        if ReturnCode.isSuccess(first.code) {
            AppLog.debug(.downloads, "ffmpeg hls success output=\(outputPath)")
            return outputURL
        }
        if ReturnCode.isCancel(first.code) {
            AppLog.error(.downloads, "ffmpeg hls cancelled input=\(playlistPath)")
            throw ConversionError.cancelled
        }

        AppLog.error(.downloads, "ffmpeg hls failed with aac_adtstoasc, retrying without bsf input=\(playlistPath)")
        let second = await runFFmpeg(commandNoBsf, duration: duration, progress: progress)
        if ReturnCode.isSuccess(second.code) {
            AppLog.debug(.downloads, "ffmpeg hls success (no bsf) output=\(outputPath)")
            return outputURL
        }
        if ReturnCode.isCancel(second.code) {
            AppLog.error(.downloads, "ffmpeg hls cancelled (no bsf) input=\(playlistPath)")
            throw ConversionError.cancelled
        }

        AppLog.error(.downloads, "ffmpeg hls failed copy, retrying with audio reencode input=\(playlistPath)")
        let third = await runFFmpeg(commandAudioReencode, duration: duration, progress: progress)
        if ReturnCode.isSuccess(third.code) {
            AppLog.debug(.downloads, "ffmpeg hls success (audio reencode) output=\(outputPath)")
            return outputURL
        }
        if ReturnCode.isCancel(third.code) {
            AppLog.error(.downloads, "ffmpeg hls cancelled (audio reencode) input=\(playlistPath)")
            throw ConversionError.cancelled
        }

        AppLog.error(.downloads, "ffmpeg hls failed audio reencode, retrying full transcode input=\(playlistPath)")
        let fourth = await runFFmpeg(commandFullTranscode, duration: duration, progress: progress)
        if ReturnCode.isSuccess(fourth.code) {
            AppLog.debug(.downloads, "ffmpeg hls success (full transcode) output=\(outputPath)")
            return outputURL
        }
        if ReturnCode.isCancel(fourth.code) {
            AppLog.error(.downloads, "ffmpeg hls cancelled (full transcode) input=\(playlistPath)")
            throw ConversionError.cancelled
        }

        let message = fourth.logs ?? third.logs ?? second.logs ?? first.logs ?? "ffmpeg hls conversion failed"
        AppLog.error(.downloads, "ffmpeg hls failed input=\(playlistPath) error=\(message)")
        try? FileManager.default.removeItem(at: outputURL)
        throw ConversionError.exportFailed(message)
    }

    private func convertToMp4WithFFmpeg(
        inputURL: URL,
        outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let inputPath = inputURL.path
        let outputPath = outputURL.path
        try? FileManager.default.removeItem(at: outputURL)

        let duration = await probeDurationSeconds(path: inputPath)
        let baseArgs = "-y -fflags +genpts+discardcorrupt -err_detect ignore_err -avoid_negative_ts make_zero -dn -sn -i \(quoted(path: inputPath)) -map 0:v? -map 0:a?"
        let commandWithBsf = "\(baseArgs) -c:v copy -c:a aac -b:a 160k -ac 2 -bsf:a aac_adtstoasc -movflags +faststart -max_muxing_queue_size 1024 \(quoted(path: outputPath))"
        let commandNoBsf = "\(baseArgs) -c:v copy -c:a aac -b:a 160k -ac 2 -movflags +faststart -max_muxing_queue_size 1024 \(quoted(path: outputPath))"
        let commandAudioReencode = commandNoBsf
        let commandFullTranscode = "\(baseArgs) -c:v libx264 -preset veryfast -crf 21 -pix_fmt yuv420p -c:a aac -b:a 160k -ac 2 -movflags +faststart -max_muxing_queue_size 1024 \(quoted(path: outputPath))"

        AppLog.debug(.downloads, "ffmpeg remux start input=\(inputPath) output=\(outputPath) duration=\(duration) audio=aac")

        let first = await runFFmpeg(commandWithBsf, duration: duration, progress: progress)
        if ReturnCode.isSuccess(first.code) {
            if inputURL.pathExtension.lowercased() == "ts" {
                try? FileManager.default.removeItem(at: inputURL)
            }
            AppLog.debug(.downloads, "ffmpeg remux success output=\(outputPath)")
            return outputURL
        }
        if ReturnCode.isCancel(first.code) {
            AppLog.error(.downloads, "ffmpeg remux cancelled input=\(inputPath)")
            throw ConversionError.cancelled
        }

        AppLog.error(.downloads, "ffmpeg remux failed with aac_adtstoasc, retrying without bsf input=\(inputPath)")
        let second = await runFFmpeg(commandNoBsf, duration: duration, progress: progress)
        if ReturnCode.isSuccess(second.code) {
            if inputURL.pathExtension.lowercased() == "ts" {
                try? FileManager.default.removeItem(at: inputURL)
            }
            AppLog.debug(.downloads, "ffmpeg remux success (no bsf) output=\(outputPath)")
            return outputURL
        }
        if ReturnCode.isCancel(second.code) {
            AppLog.error(.downloads, "ffmpeg remux cancelled (no bsf) input=\(inputPath)")
            throw ConversionError.cancelled
        }

        AppLog.error(.downloads, "ffmpeg remux failed copy, retrying with audio reencode input=\(inputPath)")
        let third = await runFFmpeg(commandAudioReencode, duration: duration, progress: progress)
        if ReturnCode.isSuccess(third.code) {
            if inputURL.pathExtension.lowercased() == "ts" {
                try? FileManager.default.removeItem(at: inputURL)
            }
            AppLog.debug(.downloads, "ffmpeg remux success (audio reencode) output=\(outputPath)")
            return outputURL
        }
        if ReturnCode.isCancel(third.code) {
            AppLog.error(.downloads, "ffmpeg remux cancelled (audio reencode) input=\(inputPath)")
            throw ConversionError.cancelled
        }

        AppLog.error(.downloads, "ffmpeg remux failed audio reencode, retrying full transcode input=\(inputPath)")
        let fourth = await runFFmpeg(commandFullTranscode, duration: duration, progress: progress)
        if ReturnCode.isSuccess(fourth.code) {
            if inputURL.pathExtension.lowercased() == "ts" {
                try? FileManager.default.removeItem(at: inputURL)
            }
            AppLog.debug(.downloads, "ffmpeg remux success (full transcode) output=\(outputPath)")
            return outputURL
        }
        if ReturnCode.isCancel(fourth.code) {
            AppLog.error(.downloads, "ffmpeg remux cancelled (full transcode) input=\(inputPath)")
            throw ConversionError.cancelled
        }

        let message = fourth.logs ?? third.logs ?? second.logs ?? first.logs ?? "ffmpeg conversion failed"
        AppLog.error(.downloads, "ffmpeg remux failed input=\(inputPath) error=\(message)")
        throw ConversionError.exportFailed(message)
    }

    private func convertWithVideoToolbox(inputURL: URL, outputURL: URL) async throws -> URL {
        try? FileManager.default.removeItem(at: outputURL)
        let asset = AVAsset(url: inputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw ConversionError.exportFailed("missing video track")
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let size = apply(transform: preferredTransform, to: naturalSize)
        let bitrate = videoBitrate(width: Int(size.width), height: Int(size.height), fps: frameRate)

        AppLog.debug(
            .downloads,
            "vt details size=\(Int(size.width))x\(Int(size.height)) fps=\(frameRate) bitrate=\(bitrate) input=\(inputURL.lastPathComponent)"
        )

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ConversionError.exportFailed("reader video output unsupported")
        }
        reader.add(videoOutput)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        videoInput.transform = preferredTransform
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw ConversionError.exportFailed("writer video input unsupported")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let audioTrack = audioTracks.first {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }

            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 44100,
                    AVEncoderBitRateKey: 160000
                ]
            )
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw ConversionError.exportFailed(writer.error?.localizedDescription ?? "writer start failed")
        }
        guard reader.startReading() else {
            throw ConversionError.exportFailed(reader.error?.localizedDescription ?? "reader start failed")
        }
        writer.startSession(atSourceTime: .zero)

        return try await withCheckedThrowingContinuation { continuation in
            let group = DispatchGroup()
            var finalizeError: Error?

            let videoQueue = DispatchQueue(label: "vt.video.queue")
            group.enter()
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        if !videoInput.append(sample) {
                            finalizeError = writer.error ?? ConversionError.exportFailed("video append failed")
                            videoInput.markAsFinished()
                            group.leave()
                            return
                        }
                    } else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            if let audioInput, let audioOutput {
                let audioQueue = DispatchQueue(label: "vt.audio.queue")
                group.enter()
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        if let sample = audioOutput.copyNextSampleBuffer() {
                            if !audioInput.append(sample) {
                                finalizeError = writer.error ?? ConversionError.exportFailed("audio append failed")
                                audioInput.markAsFinished()
                                group.leave()
                                return
                            }
                        } else {
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: .global()) {
                if reader.status == .failed {
                    finalizeError = reader.error ?? ConversionError.exportFailed("reader failed")
                }
                writer.finishWriting {
                    if let finalizeError {
                        AppLog.error(.downloads, "vt finish failed error=\(finalizeError.localizedDescription)")
                        try? FileManager.default.removeItem(at: outputURL)
                        continuation.resume(throwing: finalizeError)
                        return
                    }
                    if writer.status == .failed || writer.status == .cancelled {
                        let error = writer.error?.localizedDescription ?? "writer failed"
                        AppLog.error(.downloads, "vt writer failed status=\(writer.status.rawValue) error=\(error)")
                        try? FileManager.default.removeItem(at: outputURL)
                        continuation.resume(throwing: ConversionError.exportFailed(error))
                        return
                    }
                    AppLog.debug(.downloads, "vt finish success output=\(outputURL.lastPathComponent)")
                    continuation.resume(returning: outputURL)
                }
            }
        }
    }

    private func apply(transform: CGAffineTransform, to size: CGSize) -> CGSize {
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    private func videoBitrate(width: Int, height: Int, fps: Float) -> Int {
        let clampedFps = max(24, min(60, fps == 0 ? 30 : fps))
        let bpp: Double = 0.07
        let raw = Double(width * height) * Double(clampedFps) * bpp
        let minRate = 2_000_000.0
        let maxRate = 12_000_000.0
        return Int(max(minRate, min(maxRate, raw)))
    }

    private func runFFmpeg(
        _ command: String,
        duration: Double,
        progress: (@Sendable (Double) -> Void)?
    ) async -> (code: ReturnCode?, logs: String?) {
        await withCheckedContinuation { continuation in
            let usesVideoToolbox = command.localizedCaseInsensitiveContains("videotoolbox")
            AppLog.debug(.downloads, "ffmpeg exec start uses_vt=\(usesVideoToolbox ? 1 : 0) duration=\(duration) cmd=\(command)")
            FFmpegKit.executeAsync(command, withCompleteCallback: { session in
                let returnCode = session?.getReturnCode()
                let logs = session?.getAllLogsAsString()
                if let logs, logs.localizedCaseInsensitiveContains("videotoolbox") {
                    AppLog.debug(.downloads, "ffmpeg log contains videotoolbox")
                }
                continuation.resume(returning: (returnCode, logs))
            }, withLogCallback: nil, withStatisticsCallback: { stats in
                guard let stats, duration > 0 else { return }
                let timeMs = Double(stats.getTime())
                let value = min(1.0, max(0, timeMs / (duration * 1000)))
                progress?(value)
            })
        }
    }

    private func probeDurationSeconds(path: String) async -> Double {
        await withCheckedContinuation { continuation in
            FFprobeKit.getMediaInformationAsync(path) { session in
                let info = session?.getMediaInformation()
                let duration = Double(info?.getDuration() ?? "") ?? 0
                continuation.resume(returning: duration)
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

    private func quoted(path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    private func quoted(value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    private func buildHeaderString(_ headers: [String: String]?) -> String {
        guard let headers, !headers.isEmpty else { return "" }
        return headers.map { "\($0): \($1)" }.joined(separator: "\r\n") + "\r\n"
    }
}





