import Foundation

final class CacheService {
    static let shared = CacheService()

    private init() {}

    func clearAll() async {
        AppLog.cache.debug("clear all start")
        URLCache.shared.removeAllCachedResponses()
        await clearTemporaryFiles()
        await clearDownloads()
        AppLog.cache.debug("clear all complete")
    }

    func clearDownloadsOnly() async {
        AppLog.cache.debug("clear downloads only start")
        await clearDownloads()
        AppLog.cache.debug("clear downloads only complete")
    }

    private func clearTemporaryFiles() async {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        guard let enumerator = fm.enumerator(
            at: temp,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var cleared = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let name = fileURL.lastPathComponent.lowercased()
            if name.hasSuffix(".m3u8") || name.hasSuffix(".ts") || name.hasSuffix(".mp4") {
                try? fm.removeItem(at: fileURL)
                cleared += 1
            }
        }
        AppLog.cache.debug("cleared temp files count=\(cleared)")
    }

    private func clearDownloads() async {
        let fm = FileManager.default
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("KyomiruDownloads", isDirectory: true)
        try? fm.removeItem(at: folder)
        AppLog.cache.debug("downloads folder cleared")
    }
}
