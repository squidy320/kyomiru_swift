import Foundation

actor OfflineDownloadManager {
    typealias ProgressHandler = @Sendable (Double) -> Void

    private let session: URLSession
    private let fm = FileManager.default

    init() {
        let config = URLSessionConfiguration.background(withIdentifier: "kyomiru.hls.background")
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
        let segmentURLs = try await resolveSegments(from: playlistData, baseURL: playlistURL, headers: headers)

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

        try? fm.removeItem(at: outputURL)
        fm.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        for index in 0..<segmentURLs.count {
            let localURL = tempFolder.appendingPathComponent(String(format: "seg_%05d.ts", index))
            if let data = try? Data(contentsOf: localURL) {
                try handle.write(contentsOf: data)
            }
        }

        try? fm.removeItem(at: tempFolder)
        return outputURL
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

    private func resolveSegments(from data: Data, baseURL: URL, headers: [String: String]) async throws -> [URL] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let mediaLines = lines.filter { !$0.hasPrefix("#") && !$0.isEmpty }

        if let variantLine = mediaLines.first(where: { $0.hasSuffix(".m3u8") }) {
            let variantURL = URL(string: String(variantLine), relativeTo: baseURL)?.absoluteURL
            if let variantURL {
                let variantData = try await fetchData(url: variantURL, headers: headers)
                return try await resolveSegments(from: variantData, baseURL: variantURL, headers: headers)
            }
        }

        return mediaLines.compactMap { line in
            URL(string: String(line), relativeTo: baseURL)?.absoluteURL
        }
    }
}

