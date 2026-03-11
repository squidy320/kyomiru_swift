import Foundation
import os

enum AppLog {
    static let subsystem = "com.kyomiru.app"
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let cache = Logger(subsystem: subsystem, category: "cache")
    static let downloads = Logger(subsystem: subsystem, category: "downloads")
    static let player = Logger(subsystem: subsystem, category: "player")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let matching = Logger(subsystem: subsystem, category: "matching")
}
