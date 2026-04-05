import Foundation

public struct AniZipMapping: Codable {
    public let themoviedb_id: String?  // TMDB ID (can be string)
    public let thetvdb_id: Int?        // TVDB ID
    public let mal_id: Int?
    
    enum CodingKeys: String, CodingKey {
        case themoviedb_id, thetvdb_id, mal_id
    }
}

// Per-episode metadata from ani.zip
public struct AniZipEpisode: Codable, Hashable {
    public let episodeNumber: Int?
    public let seasonNumber: Int?
    public let absoluteEpisodeNumber: Int?
    public let title: [String: String]? // Multilingual titles
    public let airDate: String?
    public let runtime: Int?
    public let overview: String?
    
    enum CodingKeys: String, CodingKey {
        case episodeNumber, seasonNumber, absoluteEpisodeNumber, title, airDate, runtime, overview
    }
}

// Full show data from ani.zip
public struct AniZipShowData: Codable {
    public let episodes: [String: AniZipEpisode]?
    public let episodeCount: Int?
    public let specialCount: Int?
    public let mappings: AniZipMapping?
}

// Cached entry with metadata
struct AniZipCacheEntry: Codable {
    let showData: AniZipShowData
    let cachedAt: Date
}

public struct AniZipClient {
    private static let cache = UserDefaults.standard
    private static let cacheTTL: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private static let cacheKeyPrefix = "ani.zip.show:"
    
    /// Fetch or return cached show data
    public static func fetchShowData(aniListId: Int) async -> AniZipShowData? {
        // Try cache first
        if let cached = getCachedShowData(aniListId: aniListId) {
            AppLog.debug(.network, "ani.zip cache hit for \(aniListId)")
            return cached
        }
        
        // Fetch from API
        let url = URL(string: "https://api.ani.zip/mappings?anilist_id=\(aniListId)")!
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let showData = try JSONDecoder().decode(AniZipShowData.self, from: data)
            
            // Cache result
            let entry = AniZipCacheEntry(showData: showData, cachedAt: Date())
            if let encoded = try? JSONEncoder().encode(entry) {
                cache.set(encoded, forKey: cacheKeyPrefix + String(aniListId))
            }
            
            AppLog.debug(.network, "ani.zip fetched and cached for \(aniListId)")
            return showData
        } catch {
            AppLog.error(.network, "ani.zip fetch failed for \(aniListId): \(error)")
            return nil
        }
    }
    
    /// Legacy method for backwards compatibility
    public static func fetchMapping(aniListId: Int) async -> AniZipMapping? {
        if let showData = await fetchShowData(aniListId: aniListId) {
            return showData.mappings
        }
        return nil
    }
    
    /// Get episode offset for a given episode number (using absoluteEpisodeNumber)
    public static func getEpisodeOffset(aniListId: Int, forEpisodeNumber episodeNum: Int) async -> Int? {
        guard let showData = await fetchShowData(aniListId: aniListId),
              let episodes = showData.episodes else { return nil }
        
        // Find episode with matching episode number
        for (_, episode) in episodes {
            if episode.episodeNumber == episodeNum || episode.absoluteEpisodeNumber == episodeNum {
                // Return the season offset (episodes before this season started)
                if let seasonNum = episode.seasonNumber, let absNum = episode.absoluteEpisodeNumber {
                    // Rough offset: absoluteEpisodeNumber - episodeNumber = offset
                    let offset = absNum - (episode.episodeNumber ?? 1)
                    return offset
                }
            }
        }
        return nil
    }
    
    /// Get season info from ani.zip for episode matching
    public static func getSeasonInfo(aniListId: Int) async -> (tmdbId: Int?, tvdbId: Int?, episodeCount: Int?, episodes: [String: AniZipEpisode]?)? {
        guard let showData = await fetchShowData(aniListId: aniListId) else { return nil }
        
        // Convert TMDB ID from String to Int if needed
        var tmdbId: Int? = nil
        if let tmdbStr = showData.mappings?.themoviedb_id {
            tmdbId = Int(tmdbStr)
        }
        
        return (
            tmdbId: tmdbId,
            tvdbId: showData.mappings?.thetvdb_id,
            episodeCount: showData.episodeCount,
            episodes: showData.episodes
        )
    }
    
    /// Get episode metadata for display enrichment
    public static func getEpisodeMetadata(aniListId: Int, episodeNumber: Int) async -> (title: String?, airDate: String?, overview: String?)? {
        guard let showData = await fetchShowData(aniListId: aniListId),
              let episodes = showData.episodes else { return nil }
        
        // Find episode
        for (_, episode) in episodes {
            if episode.episodeNumber == episodeNumber {
                let title = episode.title?["en"] ?? episode.title?.values.first
                return (title: title, airDate: episode.airDate, overview: episode.overview)
            }
        }
        return nil
    }
    
    private static func getCachedShowData(aniListId: Int) -> AniZipShowData? {
        guard let data = cache.data(forKey: cacheKeyPrefix + String(aniListId)),
              let entry = try? JSONDecoder().decode(AniZipCacheEntry.self, from: data) else {
            return nil
        }
        
        // Check if cache is stale
        if Date().timeIntervalSince(entry.cachedAt) > cacheTTL {
            cache.removeObject(forKey: cacheKeyPrefix + String(aniListId))
            return nil
        }
        
        return entry.showData
    }
    
    /// Clear cache for a show (useful for manual refresh)
    public static func clearCache(aniListId: Int) {
        cache.removeObject(forKey: cacheKeyPrefix + String(aniListId))
    }
}