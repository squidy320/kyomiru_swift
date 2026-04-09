import Foundation

struct PlaybackService {
    @MainActor
    static func resolvePlayableURL(for sourceURL: URL, title: String?, episode: Int?) -> URL {
        if let title, let episode,
           let item = DownloadManager.shared.downloadedItem(title: title, episode: episode),
           let local = DownloadManager.shared.playableURL(for: item) {
            AppLog.debug(.player, "playback resolve: matched download title=\(title) ep=\(episode) local=\(local.path)")
            return local
        }
        if let item = DownloadManager.shared.items.first(where: { $0.url == sourceURL }),
           let local = DownloadManager.shared.playableURL(for: item) {
            AppLog.debug(.player, "playback resolve: download item=\(item.id) local=\(local.path)")
            return local
        }
        AppLog.debug(.player, "playback resolve: using remote url=\(sourceURL)")
        return sourceURL
    }

}

struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

struct PreparedSubtitleTrack: Identifiable, Equatable {
    let id: String
    let label: String
    let languageCode: String?
    let fileURL: URL
    let cues: [SubtitleCue]
}

actor SubtitlePreparationService {
    static let shared = SubtitlePreparationService()

    private let fm = FileManager.default

    func prepareTracks(_ tracks: [SoraSubtitleTrack], headers: [String: String] = [:]) async -> [PreparedSubtitleTrack] {
        var prepared: [PreparedSubtitleTrack] = []
        for track in tracks {
            if let preparedTrack = try? await prepareTrack(track, headers: headers) {
                prepared.append(preparedTrack)
            }
        }
        return prepared
    }

    func defaultText(at time: Double, tracks: [PreparedSubtitleTrack]) -> String? {
        guard let track = defaultTrack(from: tracks) else { return nil }
        return cueText(at: time, track: track)
    }

    func defaultTrack(from tracks: [PreparedSubtitleTrack]) -> PreparedSubtitleTrack? {
        tracks.first(where: {
            ($0.languageCode ?? "").lowercased() == "en" || $0.label.lowercased().contains("english")
        }) ?? tracks.first
    }

    private func cueText(at time: Double, track: PreparedSubtitleTrack) -> String? {
        guard let cue = track.cues.first(where: { time >= $0.start && time <= $0.end }) else { return nil }
        let trimmed = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func prepareTrack(_ track: SoraSubtitleTrack, headers: [String: String]) async throws -> PreparedSubtitleTrack {
        let rawData = try await fetchSubtitleData(url: track.url, headers: headers)
        let rawText = decodeSubtitleText(rawData)
        let convertedVTT: String
        let cues: [SubtitleCue]

        switch normalizedSubtitleFormat(track: track, text: rawText) {
        case "vtt":
            convertedVTT = ensureWebVTTHeader(rawText)
            cues = parseWebVTT(convertedVTT)
        case "srt":
            cues = parseSRT(rawText)
            convertedVTT = renderWebVTT(cues: cues)
        case "ass", "ssa":
            cues = parseASS(rawText)
            convertedVTT = renderWebVTT(cues: cues)
        default:
            let fallbackCues = parseSRT(rawText)
            if fallbackCues.isEmpty {
                throw NSError(domain: "SubtitlePreparation", code: 415, userInfo: [NSLocalizedDescriptionKey: "Unsupported subtitle format"])
            }
            cues = fallbackCues
            convertedVTT = renderWebVTT(cues: cues)
        }

        let targetURL = subtitleCacheURL(for: track)
        try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try convertedVTT.data(using: .utf8)?.write(to: targetURL, options: .atomic)

        return PreparedSubtitleTrack(
            id: track.id,
            label: track.label,
            languageCode: track.languageCode,
            fileURL: targetURL,
            cues: cues
        )
    }

    private func fetchSubtitleData(url: URL, headers: [String: String]) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url)
        }
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.custom.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func subtitleCacheURL(for track: SoraSubtitleTrack) -> URL {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let safeName = track.label
            .replacingOccurrences(of: #"[^A-Za-z0-9_-]+"#, with: "_", options: .regularExpression)
        let fileName = "\(safeName)_\(abs(track.id.hashValue)).vtt"
        return base.appendingPathComponent("KyomiruSubtitles", isDirectory: true).appendingPathComponent(fileName)
    }

    private func normalizedSubtitleFormat(track: SoraSubtitleTrack, text: String) -> String {
        let format = track.format.lowercased()
        if format == "vtt" || text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("WEBVTT") {
            return "vtt"
        }
        if format == "srt" || text.contains("-->") {
            return "srt"
        }
        if format == "ass" || format == "ssa" || text.contains("[Events]") {
            return format == "ssa" ? "ssa" : "ass"
        }
        return format
    }

    private func decodeSubtitleText(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16LittleEndian)
            ?? String(data: data, encoding: .utf16BigEndian)
            ?? String(decoding: data, as: UTF8.self)
    }

    private func ensureWebVTTHeader(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasPrefix("WEBVTT") {
            return text
        }
        return "WEBVTT\n\n" + text
    }

    private func renderWebVTT(cues: [SubtitleCue]) -> String {
        var lines = ["WEBVTT", ""]
        for cue in cues {
            lines.append("\(formatVTTTime(cue.start)) --> \(formatVTTTime(cue.end))")
            lines.append(cue.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func parseWebVTT(_ text: String) -> [SubtitleCue] {
        parseTimedTextBlocks(text, timeSeparator: " --> ")
    }

    private func parseSRT(_ text: String) -> [SubtitleCue] {
        parseTimedTextBlocks(text.replacingOccurrences(of: ",", with: "."), timeSeparator: " --> ")
    }

    private func parseTimedTextBlocks(_ text: String, timeSeparator: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        for block in blocks {
            let lines = block.split(separator: "\n").map { String($0) }
            guard lines.count >= 2 else { continue }
            let timingLineIndex = lines[0].contains(timeSeparator) ? 0 : 1
            guard timingLineIndex < lines.count else { continue }
            let timingParts = lines[timingLineIndex].components(separatedBy: timeSeparator)
            guard timingParts.count == 2,
                  let start = parseSubtitleTime(timingParts[0]),
                  let end = parseSubtitleTime(timingParts[1]) else { continue }
            let textLines = lines.dropFirst(timingLineIndex + 1).joined(separator: "\n")
            let cleaned = stripSubtitleFormatting(from: textLines)
            guard !cleaned.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: cleaned))
        }
        return cues
    }

    private func parseASS(_ text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n").map(String.init)
        var cues: [SubtitleCue] = []
        for line in lines where line.hasPrefix("Dialogue:") {
            let payload = line.dropFirst("Dialogue:".count)
            let fields = payload.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 10,
                  let start = parseSubtitleTime(fields[1]),
                  let end = parseSubtitleTime(fields[2]) else { continue }
            let cleaned = stripSubtitleFormatting(from: fields[9].replacingOccurrences(of: "\\N", with: "\n"))
            guard !cleaned.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: cleaned))
        }
        return cues
    }

    private func stripSubtitleFormatting(from text: String) -> String {
        text
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{[^}]+\}"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseSubtitleTime(_ raw: String) -> Double? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .first ?? raw
        let parts = trimmed.components(separatedBy: ":")
        guard parts.count == 3 else { return nil }
        let hours = Double(parts[0]) ?? 0
        let minutes = Double(parts[1]) ?? 0
        let seconds = Double(parts[2].replacingOccurrences(of: ",", with: ".")) ?? 0
        return (hours * 3600) + (minutes * 60) + seconds
    }

    private func formatVTTTime(_ value: Double) -> String {
        let totalMilliseconds = max(Int((value * 1000).rounded()), 0)
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1000
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }
}
