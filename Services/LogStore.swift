import Foundation
import SwiftUI

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let level: String
    let category: LogCategory
    let message: String
}

@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var entries: [LogEntry] = []
    private let formatter = ISO8601DateFormatter()
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = base.appendingPathComponent("KyomiruLogs.txt")
        resetForLaunch()
    }

    func append(level: String, category: LogCategory, message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, category: category, message: message)
        entries.append(entry)
        appendToFile(entry: entry)
    }

    func exportURL() -> URL {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let content = entries.map(formatEntry).joined(separator: "\n")
            try? content.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        }
        return fileURL
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func resetForLaunch() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func formatEntry(_ entry: LogEntry) -> String {
        let stamp = formatter.string(from: entry.timestamp)
        return "[\(stamp)] [\(entry.level)] [\(entry.category.rawValue)] \(entry.message)"
    }

    private func appendToFile(entry: LogEntry) {
        let line = formatEntry(entry) + "\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
