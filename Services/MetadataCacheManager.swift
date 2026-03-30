import Foundation

struct TMDBCachedMetadata: Codable, Equatable {
    let aniListId: Int
    let showId: Int
    let seasonNumber: Int
    let episodeOffset: Int
    let cachedAt: Date
    let seasonDetails: TMDBSeasonDetails?
}

final class MetadataCacheManager {
    private let fileManager: FileManager
    private let directoryURL: URL
    private let cacheVersion = "v10"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.directoryURL = caches.appendingPathComponent("tmdb_meta_\(cacheVersion)", isDirectory: true)
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    func load(aniListId: Int) -> TMDBCachedMetadata? {
        let url = fileURL(for: aniListId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TMDBCachedMetadata.self, from: data)
    }

    func save(_ metadata: TMDBCachedMetadata) {
        let url = fileURL(for: metadata.aniListId)
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clear(aniListId: Int) {
        try? fileManager.removeItem(at: fileURL(for: aniListId))
    }

    private func fileURL(for aniListId: Int) -> URL {
        directoryURL.appendingPathComponent("tmdb_meta_\(cacheVersion)_\(aniListId).json")
    }
}
