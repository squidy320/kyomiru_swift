import Foundation

private actor AniMapTaskCoalescer<Key: Hashable, Value> {
    private var inFlight: [Key: Task<Value, Never>] = [:]

    func value(for key: Key, start: @escaping @Sendable () async -> Value) async -> Value {
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task {
            await start()
        }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value
    }
}

struct AniMapResolvedMapping: Codable, Equatable {
    let anilistID: Int?
    let malID: Int?
    let tmdbShowID: Int?
    let tmdbMovieID: Int?
    let tvdbID: Int?
    let tvdbSeason: Int?
    let tvdbEpisodeOffset: Int?
    let imdbID: String?
    let mediaType: String?

    var normalizedTMDBMediaType: String? {
        if tmdbMovieID != nil, tmdbShowID != nil {
            if mediaType?.uppercased() == "MOVIE" {
                return "movie"
            }
            return "tv"
        }
        if tmdbMovieID != nil {
            return "movie"
        }
        if tmdbShowID != nil {
            return "tv"
        }
        return nil
    }

    var normalizedTMDBID: Int? {
        switch normalizedTMDBMediaType {
        case "movie":
            return tmdbMovieID
        case "tv":
            return tmdbShowID
        default:
            return nil
        }
    }

    var normalizedSeasonNumber: Int? {
        guard let season = tvdbSeason, season > 0 else { return nil }
        return season
    }

    var normalizedEpisodeOffset: Int? {
        guard let offset = tvdbEpisodeOffset, offset >= 0 else { return nil }
        return offset
    }
}

private struct AniMapEntry: Codable {
    let mal_id: Int?
    let anilist_id: Int?
    let tvdb_id: Int?
    let tvdb_season: Int?
    let tvdb_epoffset: Int?
    let tmdb_movie_id: Int?
    let tmdb_show_id: Int?
    let imdb_id: String?
    let media_type: String?
}

private struct AniMapCachedIndex: Codable {
    let fetchedAt: Date
    let byAniList: [String: AniMapResolvedMapping]
    let byMAL: [String: AniMapResolvedMapping]
}

final class AniMapClient {
    private static let cacheKey = "animap:index:v1"
    private static let cacheTTL: TimeInterval = 7 * 24 * 60 * 60
    private static let endpoint = URL(string: "https://animap.s0n1c.ca/mappings/all")!

    private let cacheStore: CacheStore
    private let session: URLSession
    private let requests = AniMapTaskCoalescer<String, AniMapCachedIndex?>()

    init(cacheStore: CacheStore, session: URLSession = .custom) {
        self.cacheStore = cacheStore
        self.session = session
    }

    func mapping(for media: AniListMedia) async -> AniMapResolvedMapping? {
        guard let index = await cachedIndexForLookup() else { return nil }

        if let direct = index.byAniList[String(media.id)] {
            return direct
        }

        if let malID = media.idMal {
            return index.byMAL[String(malID)]
        }

        return nil
    }

    func refreshIfNeeded() async {
        _ = await cachedIndexForLookup()
    }

    func clearCache() {
        cacheStore.remove(key: Self.cacheKey)
    }

    private func cachedIndexForLookup() async -> AniMapCachedIndex? {
        if let cached = loadCachedIndex() {
            if isFresh(cached) {
                return cached
            }

            Task {
                _ = await self.refreshIndex()
            }
            return cached
        }

        return await refreshIndex()
    }

    private func refreshIndex() async -> AniMapCachedIndex? {
        await requests.value(for: Self.cacheKey) { [self] in
            do {
                AppLog.debug(.network, "animap bulk fetch start")
                let (data, response) = try await session.data(from: Self.endpoint)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    AppLog.error(.network, "animap bulk fetch bad status")
                    return loadCachedIndex()
                }

                let entries = try JSONDecoder().decode([AniMapEntry].self, from: data)
                let index = buildIndex(from: entries)
                if let encoded = try? JSONEncoder().encode(index) {
                    cacheStore.writeJSON(encoded, forKey: Self.cacheKey)
                }
                AppLog.debug(.network, "animap bulk fetch success entries=\(entries.count)")
                return index
            } catch {
                AppLog.error(.network, "animap bulk fetch failed \(error.localizedDescription)")
                return loadCachedIndex()
            }
        }
    }

    private func loadCachedIndex() -> AniMapCachedIndex? {
        guard let data = cacheStore.readJSON(forKey: Self.cacheKey),
              let decoded = try? JSONDecoder().decode(AniMapCachedIndex.self, from: data) else {
            return nil
        }
        return decoded
    }

    private func isFresh(_ index: AniMapCachedIndex) -> Bool {
        Date().timeIntervalSince(index.fetchedAt) <= Self.cacheTTL
    }

    private func buildIndex(from entries: [AniMapEntry]) -> AniMapCachedIndex {
        var byAniList: [String: AniMapResolvedMapping] = [:]
        var byMAL: [String: AniMapResolvedMapping] = [:]

        for entry in entries {
            let mapping = AniMapResolvedMapping(
                anilistID: entry.anilist_id,
                malID: entry.mal_id,
                tmdbShowID: entry.tmdb_show_id,
                tmdbMovieID: entry.tmdb_movie_id,
                tvdbID: entry.tvdb_id,
                tvdbSeason: entry.tvdb_season,
                tvdbEpisodeOffset: entry.tvdb_epoffset,
                imdbID: entry.imdb_id,
                mediaType: entry.media_type
            )

            if let aniListID = entry.anilist_id {
                byAniList[String(aniListID)] = mapping
            }

            if let malID = entry.mal_id {
                byMAL[String(malID)] = mapping
            }
        }

        return AniMapCachedIndex(
            fetchedAt: Date(),
            byAniList: byAniList,
            byMAL: byMAL
        )
    }
}
