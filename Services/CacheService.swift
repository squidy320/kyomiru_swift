import Foundation

final class CacheService {
    static let shared = CacheService()

    private init() {}

    func clearAll() async {
        AppLog.debug(.cache, "clear all start")
        URLCache.shared.removeAllCachedResponses()
        await ImageCache.shared.clearAll()
        clearCacheDirectories()
        clearTemporaryFiles()
        AppLog.debug(.cache, "clear all complete")
    }

    func clearDownloadsOnly() async {
        AppLog.debug(.cache, "clear downloads only start")
        clearDownloads()
        AppLog.debug(.cache, "clear downloads only complete")
    }

    private func clearTemporaryFiles() {
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
        AppLog.debug(.cache, "cleared temp files count=\(cleared)")
    }

    private func clearCacheDirectories() {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let targets = [
            "KyomiruCache",
            "KyomiruImageCache",
            "KyomiruURLCache",
            "tmdb_meta",
            "tmdb_meta_v2",
            "tmdb_meta_v3"
        ]
        for name in targets {
            let url = caches.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: url)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func clearDownloads() {
        let fm = FileManager.default
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("KyomiruDownloads", isDirectory: true)
        try? fm.removeItem(at: folder)
        AppLog.debug(.cache, "downloads folder cleared")
    }

    func cacheSizeString() async -> String {
        let bytes = await cacheSizeBytes()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func cacheSizeBytes() async -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let targets = [
                "KyomiruCache",
                "KyomiruImageCache",
                "KyomiruURLCache",
                "tmdb_meta",
                "tmdb_meta_v2",
                "tmdb_meta_v3"
            ]
            for name in targets {
                let url = caches.appendingPathComponent(name, isDirectory: true)
                total += folderSize(url)
            }
        }
        total += Int64(URLCache.shared.currentDiskUsage)
        return total
    }

    private func folderSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var size: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize else { continue }
            size += Int64(fileSize)
        }
        return size
    }
}

