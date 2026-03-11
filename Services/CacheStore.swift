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
            AppLog.debug(.cache, "cache miss key=\(key)")
            return nil
        }
        if let maxAge, Date().timeIntervalSince(modified) > maxAge {
            AppLog.debug(.cache, "cache expired key=\(key)")
            return nil
        }
        AppLog.debug(.cache, "cache hit key=\(key)")
        return try? Data(contentsOf: url)
    }

    func writeJSON(_ data: Data, forKey key: String) {
        let url = fileURL(forKey: key)
        try? data.write(to: url, options: .atomic)
        AppLog.debug(.cache, "cache write key=\(key)")
    }

    private func fileURL(forKey key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return dirURL.appendingPathComponent(safe).appendingPathExtension("json")
    }
}

