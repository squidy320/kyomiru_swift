import Foundation
import CryptoKit

struct PlaybackService {
    static func resolvePlayableURL(for sourceURL: URL) -> URL {
        if let local = localTSURL(for: sourceURL) {
            return local
        }
        return sourceURL
    }

    static func localTSURL(for sourceURL: URL) -> URL? {
        let hash = sha256(sourceURL.absoluteString)
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let downloadsFolder = base.appendingPathComponent("downloads", isDirectory: true)
        let local = downloadsFolder.appendingPathComponent(hash).appendingPathExtension("ts")
        guard FileManager.default.fileExists(atPath: local.path) else { return nil }
        return local
    }

    private static func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
