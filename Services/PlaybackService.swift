import Foundation
import CryptoKit

struct PlaybackService {
    static func resolvePlayableURL(for sourceURL: URL) -> URL {
        if let local = localPlaylistURL(for: sourceURL) {
            return local
        }
        if let local = localMergedTSURL(for: sourceURL) {
            return local
        }
        if let legacy = localTSURL(for: sourceURL) {
            return legacy
        }
        return sourceURL
    }

    static func localPlaylistURL(for sourceURL: URL) -> URL? {
        let folder = localDownloadFolder(for: sourceURL)
        let playlist = folder.appendingPathComponent("playlist.m3u8")
        guard FileManager.default.fileExists(atPath: playlist.path) else { return nil }
        return playlist
    }

    static func localMergedTSURL(for sourceURL: URL) -> URL? {
        let folder = localDownloadFolder(for: sourceURL)
        let merged = folder.appendingPathComponent("merged.ts")
        guard FileManager.default.fileExists(atPath: merged.path) else { return nil }
        return merged
    }

    static func localTSURL(for sourceURL: URL) -> URL? {
        let hash = sha256(sourceURL.absoluteString)
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let downloadsFolder = base.appendingPathComponent("downloads", isDirectory: true)
        let local = downloadsFolder.appendingPathComponent(hash).appendingPathExtension("ts")
        guard FileManager.default.fileExists(atPath: local.path) else { return nil }
        return local
    }

    private static func localDownloadFolder(for sourceURL: URL) -> URL {
        let hash = sha256(sourceURL.absoluteString)
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true)
    }

    private static func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
