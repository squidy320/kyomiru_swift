import Foundation

final class CacheStore {
    private let fm = FileManager.default
    private let dirURL: URL

    init() {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        dirURL = base.appendingPathComponent("KyomiruCache", isDirectory: true)
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
    }

    func readJSON(forKey key: String, maxAge: TimeInterval? = nil) -> Data? {
        let url = fileURL(forKey: key)
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else {
            AppLog.cache.debug("cache miss key=\(key, privacy: .public)")
            return nil
        }
        if let maxAge, Date().timeIntervalSince(modified) > maxAge {
            AppLog.cache.debug("cache expired key=\(key, privacy: .public)")
            return nil
        }
        AppLog.cache.debug("cache hit key=\(key, privacy: .public)")
        return try? Data(contentsOf: url)
    }

    func writeJSON(_ data: Data, forKey key: String) {
        let url = fileURL(forKey: key)
        try? data.write(to: url, options: .atomic)
        AppLog.cache.debug("cache write key=\(key, privacy: .public)")
    }

    private func fileURL(forKey key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return dirURL.appendingPathComponent(safe).appendingPathExtension("json")
    }
}
