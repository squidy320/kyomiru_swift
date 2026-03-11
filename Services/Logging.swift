import Foundation
import os

enum LogCategory: String {
    case auth
    case network
    case cache
    case downloads
    case player
    case ui
    case matching
}

enum AppLog {
    static let subsystem = "com.kyomiru.app"
    static let store = LogStore.shared

    static func debug(_ category: LogCategory, _ message: String) {
        logger(for: category).debug("\(message, privacy: .public)")
        Task { @MainActor in
            store.append(level: "DEBUG", category: category, message: message)
        }
    }

    static func error(_ category: LogCategory, _ message: String) {
        logger(for: category).error("\(message, privacy: .public)")
        Task { @MainActor in
            store.append(level: "ERROR", category: category, message: message)
        }
    }

    private static func logger(for category: LogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }
}
