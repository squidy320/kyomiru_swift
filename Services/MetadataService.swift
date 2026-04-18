import Foundation
import SwiftUI

private actor TMDBTaskCoalescer<Key: Hashable, Value> {
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

private actor TMDBRequestLimiter {
    private let maxConcurrent: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func run<T>(_ operation: @escaping @Sendable () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await operation()
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            running = max(0, running - 1)
        }
    }
}

struct TMDBMetadata: Equatable, Codable {
    let tmdbId: Int
    let mediaType: String
    let title: String
    let posterURL: URL?
    let backdropURL: URL?
    let heroBackdropURL: URL?
    let logoURL: URL?
}

private struct TMDBMetadataNegativeCacheEntry: Codable {
    let missing: Bool
}

private struct TMDBLogoCacheEntry: Codable {
    let url: URL?
}

private enum TMDBMetadataCacheResult {
    case hit(TMDBMetadata)
    case negative
    case missing
}

final class MetadataService {
    private static let metadataCacheTTL: TimeInterval = 60 * 60 * 24
    private static let negativeMetadataCacheTTL: TimeInterval = 60 * 30
    private static let requestLimiter = TMDBRequestLimiter(maxConcurrent: 3)
    private let session: URLSession
    private let cacheStore: CacheStore
    private let apiKey: String?
    private let tvdbClient: TVDBClient
    private let metadataRequests = TMDBTaskCoalescer<Int, TMDBMetadata?>()
    private let logoRequests = TMDBTaskCoalescer<Int, URL?>()
    private let tmdbMatcher: TMDBMatchingService
    // Keep this dedicated cache manager because it uniquely stores resolved season details
    // that are reused across artwork and episode metadata flows.
    private let metadataCacheManager: MetadataCacheManager

    private struct ResolvedArtworkContext {
        let showId: Int
        let mediaType: String
        let posterSeasonNumber: Int?
        let seasonIds: [Int: Int]?  // Maps season number to TVDB season ID
    }

    init(
        cacheStore: CacheStore,
        session: URLSession = .custom,
        tmdbMatcher: TMDBMatchingService? = nil,
        metadataCacheManager: MetadataCacheManager = MetadataCacheManager()
    ) {
        self.cacheStore = cacheStore
        self.session = session
        let bundleKey = Bundle.main.object(forInfoDictionaryKey: "TVDB_API_KEY") as? String
        let defaultsKey = UserDefaults.standard.string(forKey: "TVDB_API_KEY")
        self.apiKey = (bundleKey?.isEmpty == false) ? bundleKey : defaultsKey
        self.tvdbClient = TVDBClient(
            session: session,
            apiKey: self.apiKey,
            pin: UserDefaults.standard.string(forKey: "TVDB_PIN")
        )
        self.tmdbMatcher = tmdbMatcher ?? TMDBMatchingService(cacheStore: cacheStore, session: session)
        self.metadataCacheManager = metadataCacheManager
    }

    func cachedHeroArtwork(for media: AniListMedia) -> (backdrop: URL?, logo: URL?) {
        let metadata = cachedTMDBMetadata(for: media)
        let backdrop = metadata?.heroBackdropURL ?? metadata?.backdropURL ?? metadata?.posterURL
        let cachedLogoURL = cachedLogo(forKey: logoCacheKey(for: media.id)) ?? nil
        let logo = metadata?.logoURL ?? cachedLogoURL
        return (backdrop, logo)
    }

    func invalidateTMDBCaches(for media: AniListMedia) {
        invalidateTMDBCaches(for: media.id)
    }

    func fetchTMDBMetadata(for media: AniListMedia) async -> TMDBMetadata? {
        let cacheKey = metadataCacheKey(for: media.id)
        switch cachedMetadata(forKey: cacheKey) {
        case .hit(let cachedResult):
            if cachedResult.logoURL != nil {
                let logoCacheKey = logoCacheKey(for: media.id)
                if let logoData = try? JSONEncoder().encode(TMDBLogoCacheEntry(url: cachedResult.logoURL)) {
                    cacheStore.writeJSON(logoData, forKey: logoCacheKey)
                }
            }
            return cachedResult
        case .negative:
            return nil
        case .missing:
            break
        }

        return await metadataRequests.value(for: media.id) { [self] in
            await Self.requestLimiter.run {
                switch self.cachedMetadata(forKey: cacheKey) {
                case .hit(let cachedResult):
                    return cachedResult
                case .negative:
                    return nil
                case .missing:
                    break
                }

                guard let apiKey = self.apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else {
                    AppLog.error(.network, "tvdb api key missing")
                    return nil
                }

                guard let details = await self.fetchArtworkTMDBMetadata(for: media, apiKey: apiKey) else {
                    self.writeNegativeMetadataCache(forKey: cacheKey)
                    return nil
                }
                if let data = try? JSONEncoder().encode(details) {
                    self.cacheStore.writeJSON(data, forKey: cacheKey)
                }
                self.writeLogo(details.logoURL, forKey: self.logoCacheKey(for: media.id))
                return details
            }
        }
    }

    func posterURL(for media: AniListMedia) async -> URL? {
        let meta = await fetchTMDBMetadata(for: media)
        return meta?.posterURL
    }

    func backdropURL(for media: AniListMedia) async -> URL? {
        let meta = await fetchTMDBMetadata(for: media)
        return meta?.backdropURL ?? meta?.posterURL
    }

    func heroBackdropURL(for media: AniListMedia, tvdbSeasonNumber: Int? = nil) async -> URL? {
        // Try device-optimized backdrop selection first (with optional season support)
        if let optimized = await deviceOptimizedBackdropURL(for: media, tvdbSeasonNumber: tvdbSeasonNumber) {
            return optimized
        }
        
        // Fallback to standard metadata
        let meta = await fetchTMDBMetadata(for: media)
        return meta?.heroBackdropURL ?? meta?.backdropURL ?? meta?.posterURL
    }

    /// Get device-optimized backdrop/poster for full-screen display
    /// - Parameters:
    ///   - media: The anime media
    ///   - tvdbSeasonNumber: Optional TVDB season number (from AniMap) for season-specific artwork
    /// - Returns: Device-optimized backdrop URL
    private func deviceOptimizedBackdropURL(
        for media: AniListMedia,
        tvdbSeasonNumber: Int? = nil
    ) async -> URL? {
        guard let context = await resolveArtworkContext(for: media) else { return nil }
        guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else { return nil }
        
        let isTablet = PlatformSupport.prefersTabletLayout
        
        // Try season-specific artwork first if season number is provided
        if let seasonNumber = tvdbSeasonNumber,
           let seasonId = context.seasonIds?[seasonNumber] {
            let seasonArtworks = await tvdbClient.fetchSeasonArtworks(seasonId)
            if !seasonArtworks.isEmpty {
                if isTablet {
                    // iPad: Use textless background for full-screen display
                    if let url = tvdbClient.selectBestArtwork(from: seasonArtworks, ofType: "background", preferTextless: true) {
                        return url
                    }
                } else {
                    // iPhone: Use portrait-optimized poster
                    if let url = tvdbClient.selectBestArtwork(from: seasonArtworks, ofType: "poster") {
                        return url
                    }
                }
            }
        }
        
        // Fallback to series-level artwork
        let seriesArtworks = await tvdbClient.fetchSeriesArtworks(context.showId)
        guard !seriesArtworks.isEmpty else { return nil }
        
        if isTablet {
            // iPad: Use textless background for full-screen display
            return tvdbClient.selectBestArtwork(from: seriesArtworks, ofType: "background", preferTextless: true)
                ?? tvdbClient.selectBestArtwork(from: seriesArtworks, ofType: "poster")
        } else {
            // iPhone: Use portrait-optimized poster
            return tvdbClient.selectBestArtwork(from: seriesArtworks, ofType: "poster")
                ?? tvdbClient.selectBestArtwork(from: seriesArtworks, ofType: "background", preferTextless: true)
        }
    }

    func logoURL(for media: AniListMedia) async -> URL? {
        if let metadata = await fetchTMDBMetadata(for: media),
           let logo = metadata.logoURL {
            return logo
        }

        let cacheKey = logoCacheKey(for: media.id)
        if let cached = cachedLogo(forKey: cacheKey) {
            return cached
        }

        return await logoRequests.value(for: media.id) { [self] in
            if let cached = self.cachedLogo(forKey: cacheKey) {
                return cached
            }
            guard let apiKey = self.apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else {
                return nil
            }
            guard let context = await self.resolveArtworkContext(for: media) else {
                self.writeLogo(nil, forKey: cacheKey)
                return nil
            }
            let logo = await self.fetchBestLogo(showId: context.showId, mediaType: context.mediaType, apiKey: apiKey)
            self.writeLogo(logo, forKey: cacheKey)
            return logo
        }
    }

    func saveManualTMDBMatch(
        media: AniListMedia,
        showId: Int,
        mediaType: String = "tv",
        seasonNumber: Int,
        episodeOffset: Int = 0,
        showTitle: String? = nil,
        seasonLabel: String? = nil,
        parentSeriesId: Int? = nil
    ) async {
        await tmdbMatcher.saveManualOverride(
            aniListId: media.id,
            showId: showId,
            mediaType: mediaType,
            seasonNumber: seasonNumber,
            episodeOffset: episodeOffset,
            showTitle: showTitle,
            seasonLabel: seasonLabel,
            parentSeriesId: parentSeriesId
        )
        invalidateTMDBCaches(for: media.id)
    }

    func clearManualTMDBMatch(for media: AniListMedia) {
        tmdbMatcher.clearManualOverride(aniListId: media.id)
        invalidateTMDBCaches(for: media.id)
    }

    private func fetchArtworkTMDBMetadata(for media: AniListMedia, apiKey: String) async -> TMDBMetadata? {
        guard let context = await resolveArtworkContext(for: media) else {
            AppLog.debug(.matching, "tvdb metadata unresolved mediaId=\(media.id)")
            return nil
        }

        guard let details = await fetchTMDBDetails(showId: context.showId, mediaType: context.mediaType, apiKey: apiKey, includeLogo: true) else {
            return nil
        }
        let seasonPosterURL: URL?
        if context.mediaType == "tv", let posterSeasonNumber = context.posterSeasonNumber {
            seasonPosterURL = await tmdbMatcher.fetchSeasonDetails(
                aniListId: media.id,
                showId: context.showId,
                seasonNumber: posterSeasonNumber
            )?.posterURL
        } else {
            seasonPosterURL = nil
        }
        return TMDBMetadata(
            tmdbId: details.tmdbId,
            mediaType: details.mediaType,
            title: details.title,
            posterURL: seasonPosterURL ?? details.posterURL,
            backdropURL: details.backdropURL,
            heroBackdropURL: details.heroBackdropURL ?? seasonPosterURL,
            logoURL: details.logoURL
        )
    }

    private func resolveArtworkContext(for media: AniListMedia) async -> ResolvedArtworkContext? {
        if let overrideMatch = tmdbMatcher.manualOverride(for: media.id) {
            let mediaType = overrideMatch.mediaType ?? "tv"
            let seasonIds = mediaType == "tv" ? await buildSeasonIdMap(showId: overrideMatch.showId) : nil
            return ResolvedArtworkContext(
                showId: overrideMatch.showId,
                mediaType: mediaType,
                posterSeasonNumber: mediaType == "tv" ? overrideMatch.seasonNumber : nil,
                seasonIds: seasonIds
            )
        }

        let structured = await tmdbMatcher.resolveAnimeStructure(media: media)

        if let resolved = await tmdbMatcher.resolveShowAndSeason(
            media: media,
            preferredSeasonNumber: TitleMatcher.extractSeasonNumber(from: media.title.best),
            expectedEpisodeCount: media.episodes
        ) {
            let posterSeasonNumber: Int?
            if let structured,
               structured.showId == resolved.showId,
               structured.mediaType == resolved.mediaType,
               resolved.mediaType == "tv" {
                posterSeasonNumber = structured.currentSegment.posterSeasonNumber
            } else {
                posterSeasonNumber = resolved.mediaType == "tv" ? resolved.seasonNumber : nil
            }
            let seasonIds = resolved.mediaType == "tv" ? await buildSeasonIdMap(showId: resolved.showId) : nil
            return ResolvedArtworkContext(
                showId: resolved.showId,
                mediaType: resolved.mediaType,
                posterSeasonNumber: posterSeasonNumber,
                seasonIds: seasonIds
            )
        }

        if let target = await tmdbMatcher.resolveArtworkTarget(media: media) {
            let posterSeasonNumber: Int?
            if let structured,
               structured.showId == target.id,
               structured.mediaType == target.mediaType,
               target.mediaType == "tv" {
                posterSeasonNumber = structured.currentSegment.posterSeasonNumber
            } else {
                posterSeasonNumber = target.mediaType == "tv" ? cacheStoreSeasonNumber(for: media.id) : nil
            }
            let seasonIds = target.mediaType == "tv" ? await buildSeasonIdMap(showId: target.id) : nil
            return ResolvedArtworkContext(
                showId: target.id,
                mediaType: target.mediaType,
                posterSeasonNumber: posterSeasonNumber,
                seasonIds: seasonIds
            )
        }

        return nil
    }

    /// Build a mapping from season number to TVDB season ID for season-specific artwork
    private func buildSeasonIdMap(showId: Int) async -> [Int: Int]? {
        guard let series = await tvdbClient.fetchSeries(showId) else { return nil }
        var seasonMap: [Int: Int] = [:]
        for season in series.seasons {
            seasonMap[season.number] = season.id
        }
        return seasonMap.isEmpty ? nil : seasonMap
    }

    private func cacheStoreSeasonNumber(for aniListId: Int) -> Int? {
        metadataCacheManager.load(aniListId: aniListId)?.seasonNumber
    }

    private func resolveTMDBShowId(media: AniListMedia) async -> Int? {
        if let malId = media.idMal,
           let byMal = await findByMAL(malId: malId) {
            return byMal
        }
        let title = media.title.english ?? media.title.romaji ?? media.title.native ?? media.title.best
        return await searchTMDB(title: title, year: media.seasonYear)
    }

    private func findByMAL(malId: Int) async -> Int? {
        return nil
    }

    private func searchTMDB(title: String, year: Int?) async -> Int? {
        let sanitized = TitleSanitizer.sanitize(title)
        let queries = TitleMatcher.buildQueries(from: sanitized)
        let normalizedTarget = TitleMatcher.cleanTitle(sanitized)
        var best: (id: Int, score: Double)?

        for query in queries {
            let results = await tvdbClient.search(query: query)
            for row in results where row.mediaType == "tv" {
                let titleScore = TitleMatcher.diceCoefficient(
                    TitleMatcher.cleanTitle(row.title),
                    normalizedTarget
                )
                let yearScore: Double
                if let year, let parsed = row.year {
                    yearScore = year == parsed ? 1.0 : 0.0
                } else {
                    yearScore = 0.5
                }
                let score = (0.7 * titleScore) + (0.3 * yearScore)
                if best == nil || score > best!.score {
                    best = (row.id, score)
                }
            }
        }
        return best?.id
    }

    private func fetchTMDBDetails(showId: Int, mediaType: String, apiKey: String, includeLogo: Bool) async -> TMDBMetadata? {
        if mediaType == "movie" {
            guard let movie = await tvdbClient.fetchMovie(showId) else { return nil }
            return TMDBMetadata(
                tmdbId: showId,
                mediaType: mediaType,
                title: movie.title,
                posterURL: movie.posterURL,
                backdropURL: movie.backdropURL,
                heroBackdropURL: movie.backdropURL ?? movie.posterURL,
                logoURL: includeLogo ? movie.logoURL : nil
            )
        }
        guard let series = await tvdbClient.fetchSeries(showId) else { return nil }
        return TMDBMetadata(
            tmdbId: showId,
            mediaType: mediaType,
            title: series.title,
            posterURL: series.posterURL,
            backdropURL: series.backdropURL,
            heroBackdropURL: series.backdropURL ?? series.posterURL,
            logoURL: includeLogo ? series.logoURL : nil
        )
    }

    private func fetchBestLogo(showId: Int, mediaType: String = "tv", apiKey: String) async -> URL? {
        if mediaType == "movie" {
            return await tvdbClient.fetchMovie(showId)?.logoURL
        }
        return await tvdbClient.fetchSeries(showId)?.logoURL
    }

    private func yearFrom(_ dateString: String?) -> Int? {
        guard let dateString, dateString.count >= 4 else { return nil }
        return Int(dateString.prefix(4))
    }

    private func cachedMetadata(forKey key: String) -> TMDBMetadataCacheResult {
        if let cached = cacheStore.readJSON(forKey: key, maxAge: Self.metadataCacheTTL),
           let decoded = try? JSONDecoder().decode(TMDBMetadata.self, from: cached) {
            return .hit(decoded)
        }
        if let cached = cacheStore.readJSON(forKey: key, maxAge: Self.negativeMetadataCacheTTL),
           let negative = try? JSONDecoder().decode(TMDBMetadataNegativeCacheEntry.self, from: cached),
           negative.missing {
            return .negative
        }
        return .missing
    }

    private func cachedTMDBMetadata(for media: AniListMedia) -> TMDBMetadata? {
        switch cachedMetadata(forKey: metadataCacheKey(for: media.id)) {
        case .hit(let metadata):
            return metadata
        case .negative, .missing:
            return nil
        }
    }

    private func writeNegativeMetadataCache(forKey key: String) {
        let entry = TMDBMetadataNegativeCacheEntry(missing: true)
        if let data = try? JSONEncoder().encode(entry) {
            cacheStore.writeJSON(data, forKey: key)
        }
    }

    private func metadataCacheKey(for mediaId: Int) -> String {
        if let overrideMatch = tmdbMatcher.manualOverride(for: mediaId) {
            return "tmdb:media:v15:manual:\(mediaId):type:\(overrideMatch.mediaType ?? "tv"):show:\(overrideMatch.showId):season:\(overrideMatch.seasonNumber):offset:\(overrideMatch.episodeOffset)"
        }
        return "tmdb:media:v15:\(mediaId)"
    }

    private func logoCacheKey(for mediaId: Int) -> String {
        if let overrideMatch = tmdbMatcher.manualOverride(for: mediaId) {
            return "tmdb:logo:v5:manual:\(mediaId):type:\(overrideMatch.mediaType ?? "tv"):show:\(overrideMatch.showId)"
        }
        return "tmdb:logo:v5:\(mediaId)"
    }

    private func cachedLogo(forKey key: String) -> URL?? {
        if let cached = cacheStore.readJSON(forKey: key, maxAge: Self.metadataCacheTTL),
           let decoded = try? JSONDecoder().decode(TMDBLogoCacheEntry.self, from: cached) {
            return decoded.url
        }
        if let cached = cacheStore.readJSON(forKey: key, maxAge: Self.negativeMetadataCacheTTL),
           let negative = try? JSONDecoder().decode(TMDBMetadataNegativeCacheEntry.self, from: cached),
           negative.missing {
            return .some(nil)
        }
        return nil
    }

    private func writeLogo(_ url: URL?, forKey key: String) {
        if let url {
            let entry = TMDBLogoCacheEntry(url: url)
            if let data = try? JSONEncoder().encode(entry) {
                cacheStore.writeJSON(data, forKey: key)
            }
        } else {
            writeNegativeMetadataCache(forKey: key)
        }
    }

    private func invalidateTMDBCaches(for mediaId: Int) {
        metadataCacheManager.clear(aniListId: mediaId)
        cacheStore.removeKeys(withPrefix: "tmdb:match:v10:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:match:v11:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:match:v12:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:match:v13:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v6:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v6:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v7:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v7:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v8:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v8:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v9:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v9:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v10:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v10:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v11:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v11:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v12:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v12:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v13:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v13:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v14:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v14:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v15:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:media:v15:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:logo:v1:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:logo:v1:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:logo:v2:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:logo:v2:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:logo:v3:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:logo:v3:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:logo:v4:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:logo:v4:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:logo:v5:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:logo:v5:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:ratings:v6:\(mediaId):")
        cacheStore.removeKeys(withPrefix: "tmdb:ratings:v7:\(mediaId):")
        cacheStore.removeKeys(withPrefix: "tmdb:ratings:v8:\(mediaId):")
        cacheStore.removeKeys(withPrefix: "tmdb:ratings:v9:\(mediaId):")
        cacheStore.removeKeys(withPrefix: "episode-meta:tmdb:v9:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "episode-meta:tmdb:v9:\(mediaId):")
        cacheStore.removeKeys(withPrefix: "episode-meta:tmdb:v10:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "episode-meta:tmdb:v10:\(mediaId):")
        cacheStore.removeKeys(withPrefix: "episode-meta:tmdb:v11:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "episode-meta:tmdb:v11:\(mediaId):")
        cacheStore.removeKeys(withPrefix: "episode-meta:tmdb:v12:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "episode-meta:tmdb:v12:\(mediaId):")
        cacheStore.removeKeys(withPrefix: "tmdb:structure:v1:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:structure:v2:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:structure:v3:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:structure:v4:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:structure:v5:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:structure:v6:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:structure:v7:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:structure:v8:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:structure:v9:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:structure:v10:\(mediaId)")
    }
}

struct EpisodeMetadata: Equatable, Codable {
    let number: Int
    let title: String
    let summary: String?
    let airDate: String?
    let runtimeMinutes: Int?
    let thumbnailURL: URL?
}

struct EpisodeRating: Equatable, Codable {
    let number: Int
    let rating: Double
}

final class RatingService {
    private let session: URLSession
    private let cacheStore: CacheStore
    private let apiKey: String?
    private let tmdbMatcher: TMDBMatchingService

    init(cacheStore: CacheStore, session: URLSession = .custom, tmdbMatcher: TMDBMatchingService? = nil) {
        self.cacheStore = cacheStore
        self.session = session
        let bundleKey = Bundle.main.object(forInfoDictionaryKey: "TVDB_API_KEY") as? String
        let defaultsKey = UserDefaults.standard.string(forKey: "TVDB_API_KEY")
        self.apiKey = (bundleKey?.isEmpty == false) ? bundleKey : defaultsKey
        self.tmdbMatcher = tmdbMatcher ?? TMDBMatchingService(cacheStore: cacheStore, session: session)
    }

    func ratingsForSeason(
        media: AniListMedia,
        seasonNumber: Int = 1,
        firstEpisodeNumber: Int? = nil
    ) async -> [Int: Double] {
        guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else {
            AppLog.error(.network, "tvdb api key missing")
            return [:]
        }

        if let structured = await tmdbMatcher.resolveAnimeStructure(media: media) {
            let desiredCount = media.episodes ?? structured.currentSegment.episodeCount
            let cacheKey = "tmdb:ratings:v9:\(media.id):show:\(structured.showId):abs:\(structured.currentSlice.absoluteStart)-\(structured.currentSlice.absoluteEnd)"
            if let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 60 * 12),
               let decoded = try? JSONDecoder().decode([Int: Double].self, from: cached) {
                return decoded
            }

            let mapped = mapAbsoluteRatings(
                structured,
                desiredCount: desiredCount
            )
            if let data = try? JSONEncoder().encode(mapped) {
                cacheStore.writeJSON(data, forKey: cacheKey)
            }
            return mapped
        }

        if let resolved = await tmdbMatcher.matchShowAndSeason(media: media) {
            let cacheKey = "tmdb:ratings:v9:\(media.id):show:\(resolved.showId):season:\(resolved.seasonNumber):offset:\(resolved.episodeOffset)"
            if let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 60 * 12),
               let decoded = try? JSONDecoder().decode([Int: Double].self, from: cached) {
                return decoded
            }

            if let details = await tmdbMatcher.fetchSeasonDetails(aniListId: media.id, showId: resolved.showId, seasonNumber: resolved.seasonNumber) {
                var mapped: [Int: Double] = [:]
                let desiredCount = media.episodes ?? 0
                for episode in details.episodes {
                    let adjusted = episode.number - resolved.episodeOffset
                    if adjusted >= 1 && (desiredCount == 0 || adjusted <= desiredCount + 5),
                       let rating = episode.rating {
                        mapped[adjusted] = rating
                    }
                }
                if let data = try? JSONEncoder().encode(mapped) {
                    cacheStore.writeJSON(data, forKey: cacheKey)
                }
                return mapped
            }
        }

        return [:]
    }

    private func mapAbsoluteRatings(
        _ structured: TMDBAnimeStructureMatch,
        desiredCount: Int
    ) -> [Int: Double] {
        let startIndex = max(0, structured.currentSegment.absoluteStart - 1)
        let endIndex = min(structured.absoluteEpisodes.count - 1, structured.currentSegment.absoluteEnd - 1)
        guard startIndex <= endIndex else { return [:] }

        let slice = Array(structured.absoluteEpisodes[startIndex...endIndex])
        var result: [Int: Double] = [:]
        for (index, episode) in slice.enumerated() {
            guard let rating = episode.rating else { continue }
            result[index + 1] = rating // Always renumber to 1-based for display
        }
        return result
    }

    private func resolveTMDBShowId(media: AniListMedia, apiKey: String) async -> Int? {
        if let malId = media.idMal,
           let byMal = await findByMAL(malId: malId, apiKey: apiKey) {
            return byMal
        }
        let title = media.title.romaji ?? media.title.english ?? media.title.native ?? media.title.best
        return await searchTMDB(title: title, apiKey: apiKey)
    }

    private func findByMAL(malId: Int, apiKey: String) async -> Int? {
        return nil
    }

    private func searchTMDB(title: String, apiKey: String) async -> Int? {
        let sanitized = TitleSanitizer.sanitize(title)
        let client = TVDBClient(
            session: session,
            apiKey: apiKey,
            pin: UserDefaults.standard.string(forKey: "TVDB_PIN")
        )
        return await client.search(query: sanitized, type: "series").first?.id
    }

    private func applyEpisodeOffset(_ data: [Int: Double], offset: Int) -> [Int: Double] {
        guard offset != 0 else { return data }
        var result: [Int: Double] = [:]
        for (tmdbNumber, rating) in data {
            let newNumber = tmdbNumber + offset
            guard newNumber > 0 else { continue }
            result[newNumber] = rating
        }
        return result
    }
}

struct TrendingItem: Identifiable, Equatable, Codable {
    let id: Int
    let title: String
    let backdropURL: URL?
    let logoURL: URL?
}

final class TrendingService {
    private let session: URLSession
    private let cacheStore: CacheStore
    private let apiKey: String?
    private let tvdbClient: TVDBClient

    init(cacheStore: CacheStore, session: URLSession = .custom) {
        self.cacheStore = cacheStore
        self.session = session
        let bundleKey = Bundle.main.object(forInfoDictionaryKey: "TVDB_API_KEY") as? String
        let defaultsKey = UserDefaults.standard.string(forKey: "TVDB_API_KEY")
        self.apiKey = (bundleKey?.isEmpty == false) ? bundleKey : defaultsKey
        self.tvdbClient = TVDBClient(
            session: session,
            apiKey: self.apiKey,
            pin: UserDefaults.standard.string(forKey: "TVDB_PIN")
        )
    }

    func fetchTrending() async -> [TrendingItem] {
        let cacheKey = "tvdb:trending:anime:v1"
        if let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 30),
           let decoded = try? JSONDecoder().decode([TrendingItem].self, from: cached) {
            return decoded
        }

        guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else {
            AppLog.error(.network, "tvdb api key missing")
            return []
        }

        let queries = ["anime", "animation", "japanese animation"]
        var items: [TrendingItem] = []
        var seen: Set<Int> = []

        for query in queries {
            let hits = await tvdbClient.search(query: query, type: "series")
            for hit in hits where seen.insert(hit.id).inserted {
                guard let series = await tvdbClient.fetchSeries(hit.id) else { continue }
                items.append(
                    TrendingItem(
                        id: series.id,
                        title: series.title,
                        backdropURL: series.backdropURL ?? series.posterURL,
                        logoURL: series.logoURL
                    )
                )
                if items.count >= 20 {
                    break
                }
            }
            if items.count >= 20 {
                break
            }
        }

        if let data = try? JSONEncoder().encode(items) {
            cacheStore.writeJSON(data, forKey: cacheKey)
        }
        return items
    }

    func fetchRandomDiscoverAnime(minVoteCount: Int = 50) async -> TrendingItem? {
        guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else {
            AppLog.error(.network, "tvdb api key missing")
            return nil
        }

        return await fetchTrending().randomElement()
    }
}

final class EpisodeMetadataService {
    enum Provider: String {
        case kitsu
        case tvdb
        case tmdb
        case aniList
    }

    private let session: URLSession
    private let cacheStore: CacheStore
    private let provider: Provider
    private let aniListClient: AniListClient
    private let tmdbMatcher: TMDBMatchingService
    private let tmdbKey: String?
    private let cacheManager: MetadataCacheManager
    private let preferenceStore: EpisodeMetadataPreferenceStore

    init(
        cacheStore: CacheStore,
        aniListClient: AniListClient,
        provider: Provider = .tvdb,
        session: URLSession = .custom,
        tmdbMatcher: TMDBMatchingService? = nil,
        preferenceStore: EpisodeMetadataPreferenceStore = .shared
    ) {
        self.cacheStore = cacheStore
        self.session = session
        self.provider = provider
        self.aniListClient = aniListClient
        self.tmdbMatcher = tmdbMatcher ?? TMDBMatchingService(cacheStore: cacheStore, session: session)
        let bundleKey = Bundle.main.object(forInfoDictionaryKey: "TVDB_API_KEY") as? String
        let defaultsKey = UserDefaults.standard.string(forKey: "TVDB_API_KEY")
        self.tmdbKey = (bundleKey?.isEmpty == false) ? bundleKey : defaultsKey
        self.cacheManager = MetadataCacheManager()
        self.preferenceStore = preferenceStore
    }

    func preferredProvider(for media: AniListMedia) -> Provider {
        .tvdb
    }

    func setPreferredProvider(_ provider: Provider, for media: AniListMedia) {
        preferenceStore.clear(aniListId: media.id)
    }

    func cachedEpisodes(for media: AniListMedia, episodes: [SoraEpisode]) -> [Int: EpisodeMetadata]? {
        switch preferredProvider(for: media) {
        case .kitsu:
            let cacheKey = "episode-meta:kitsu:\(media.id)"
            if let cached = cacheStore.readJSON(forKey: cacheKey),
                let decoded = try? JSONDecoder().decode([Int: EpisodeMetadata].self, from: cached) {
                return decoded
            }
            return nil
        case .aniList:
            let cacheKey = "episode-meta:anilist:v3:\(media.id):count:\(episodes.count)"
            if let cached = cacheStore.readJSON(forKey: cacheKey),
               let decoded = try? JSONDecoder().decode([Int: EpisodeMetadata].self, from: cached) {
                return decoded
            }
            return nil
        case .tmdb, .tvdb:
            let desiredCount = episodes.isEmpty ? (media.episodes ?? 0) : episodes.count
            let maxEpisodeNumber = episodes.map(\.number).max() ?? 0
            let globalNumbering = maxEpisodeNumber >= desiredCount + 5 && maxEpisodeNumber > 0
            let maxKey = globalNumbering ? ":max:\(maxEpisodeNumber)" : ""
            let structureKey = "tmdb:structure:v10:\(media.id)"
            guard let cachedStructure = cacheStore.readJSON(forKey: structureKey),
                  let structured = try? JSONDecoder().decode(TMDBAnimeStructureMatch.self, from: cachedStructure) else {
                return nil
            }
            let seasonNumber = structured.currentSlice.tmdbSeasonNumber
            let episodeOffset = structured.currentSlice.episodeOffset
            let showId = structured.showId
            let offsetKey = episodeOffset != 0 ? ":offset:\(episodeOffset)" : ""
            let showKey = ":show:\(showId)"
            let absoluteKey = ":abs:\(structured.currentSlice.absoluteStart)-\(structured.currentSlice.absoluteEnd)"
            let cacheKey = "episode-meta:tmdb:v12:\(media.id)\(showKey):season:\(seasonNumber):count:\(desiredCount)\(maxKey)\(offsetKey)\(absoluteKey)"
            if let cached = cacheStore.readJSON(forKey: cacheKey),
               let decoded = try? JSONDecoder().decode([Int: EpisodeMetadata].self, from: cached) {
                return decoded
            }
            return nil
        }
    }

    func fetchEpisodes(for media: AniListMedia, episodes: [SoraEpisode]) async -> [Int: EpisodeMetadata] {
        let mapped: [Int: EpisodeMetadata]
        switch preferredProvider(for: media) {
        case .kitsu:
            let cacheKey = "episode-meta:kitsu:\(media.id)"
            if let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 60 * 12),
                let decoded = try? JSONDecoder().decode([Int: EpisodeMetadata].self, from: cached) {
                return decoded
            }
            mapped = await fetchFromKitsu(media: media)
            if let data = try? JSONEncoder().encode(mapped) {
                cacheStore.writeJSON(data, forKey: cacheKey)
            }
        case .aniList:
            let cacheKey = "episode-meta:anilist:v3:\(media.id):count:\(episodes.count)"
            if let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 60 * 6),
               let decoded = try? JSONDecoder().decode([Int: EpisodeMetadata].self, from: cached) {
                return decoded
            }
            mapped = await fetchFromAniListStreaming(media: media, episodes: episodes)
            if let data = try? JSONEncoder().encode(mapped) {
                cacheStore.writeJSON(data, forKey: cacheKey)
            }
        case .tmdb, .tvdb:
            let desiredCount = episodes.isEmpty ? (media.episodes ?? 0) : episodes.count
            let maxEpisodeNumber = episodes.map(\.number).max() ?? 0
            let preferredSeason = TitleMatcher.extractSeasonNumber(from: media.title.best)
            let firstEpisodeNumber = episodes.map(\.number).min()
            let (primary, showId, seasonNumber, episodeOffset, absoluteStart, absoluteEnd, accepted, rejectReason) = await fetchFromTMDB(
                media: media,
                preferredSeason: preferredSeason,
                desiredCount: desiredCount,
                maxEpisodeNumber: maxEpisodeNumber,
                firstEpisodeNumber: firstEpisodeNumber
            )
            let globalNumbering = maxEpisodeNumber >= desiredCount + 5 && maxEpisodeNumber > 0
            let maxKey = globalNumbering ? ":max:\(maxEpisodeNumber)" : ""
            let offsetKey = episodeOffset != 0 ? ":offset:\(episodeOffset)" : ""
            let absoluteKey = absoluteStart > 0 && absoluteEnd > 0 ? ":abs:\(absoluteStart)-\(absoluteEnd)" : ""
            let genericCacheKey = "episode-meta:tmdb:v12:\(media.id):show:\(showId):season:\(seasonNumber):count:\(desiredCount)\(maxKey)\(offsetKey)"
            let cacheKey = "\(genericCacheKey)\(absoluteKey)"
            if accepted, let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 60 * 12),
               let decoded = try? JSONDecoder().decode([Int: EpisodeMetadata].self, from: cached) {
                return decoded
            }
            if accepted, !primary.isEmpty {
                mapped = primary
                if let data = try? JSONEncoder().encode(mapped) {
                    cacheStore.writeJSON(data, forKey: cacheKey)
                    cacheStore.writeJSON(data, forKey: genericCacheKey)
                }
            } else {
                let aniListFallback = await fetchFromAniListStreaming(media: media, episodes: episodes)
                if let reason = rejectReason {
                    AppLog.debug(.matching, "tmdb season rejected mediaId=\(media.id) reason=\(reason)")
                }
                mapped = aniListFallback.isEmpty ? await fetchFromKitsu(media: media) : aniListFallback
            }
        }
        return mapped
    }

    private func fetchFromKitsu(media: AniListMedia) async -> [Int: EpisodeMetadata] {
        let title = media.title.english ?? media.title.romaji ?? media.title.native ?? media.title.best
        let animeId = await resolveKitsuAnimeId(malId: media.idMal, title: title)
        guard let animeId else { return [:] }
        return await fetchKitsuEpisodes(animeId: animeId)
    }

    private func fetchFromAniListStreaming(media: AniListMedia, episodes: [SoraEpisode]) async -> [Int: EpisodeMetadata] {
        let cacheKey = "episode-meta:anilist:v3:\(media.id):count:\(episodes.count)"
        if let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 60 * 6),
            let decoded = try? JSONDecoder().decode([Int: EpisodeMetadata].self, from: cached) {
            return decoded
        }
        guard let streaming = try? await aniListClient.streamingEpisodes(mediaId: media.id) else {
            return [:]
        }
        var result: [Int: EpisodeMetadata] = [:]

        let sortedLocalEpisodes = episodes.sorted { lhs, rhs in
            if lhs.number == rhs.number {
                return lhs.id < rhs.id
            }
            return lhs.number < rhs.number
        }

        for (index, streamEpisode) in streaming.enumerated() {
            let resolvedNumber: Int?
            if let explicit = streamEpisode.episodeNumber, explicit > 0 {
                resolvedNumber = explicit
            } else if index < sortedLocalEpisodes.count {
                resolvedNumber = sortedLocalEpisodes[index].number
            } else {
                resolvedNumber = index + 1
            }

            guard let number = resolvedNumber, number > 0 else { continue }
            guard result[number] == nil else { continue }

            let title = streamEpisode.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = title.isEmpty ? "Episode \(number)" : title
            result[number] = EpisodeMetadata(
                number: number,
                title: resolvedTitle,
                summary: nil,
                airDate: nil,
                runtimeMinutes: nil,
                thumbnailURL: streamEpisode.thumbnailURL
            )
        }

        if let data = try? JSONEncoder().encode(result) {
            cacheStore.writeJSON(data, forKey: cacheKey)
        }
        return result
    }

    private func resolveKitsuAnimeId(malId: Int?, title: String) async -> String? {
        var components = URLComponents(string: "https://kitsu.io/api/edge/anime")!
        if let malId {
            components.queryItems = [URLQueryItem(name: "filter[malId]", value: String(malId))]
        } else {
            components.queryItems = [URLQueryItem(name: "filter[text]", value: title)]
        }
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let dataList = root?["data"] as? [[String: Any]]
            return dataList?.first?["id"] as? String
        } catch {
            return nil
        }
    }

    private func fetchKitsuEpisodes(animeId: String) async -> [Int: EpisodeMetadata] {
        guard let url = URL(string: "https://kitsu.io/api/edge/anime/\(animeId)/episodes?page[limit]=50") else {
            return [:]
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return [:]
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rows = root?["data"] as? [[String: Any]] ?? []
            var result: [Int: EpisodeMetadata] = [:]
            for row in rows {
                guard let attributes = row["attributes"] as? [String: Any] else { continue }
                let number = attributes["number"] as? Int ?? 0
                let title = (attributes["titles"] as? [String: Any])?["en_jp"] as? String
                    ?? (attributes["titles"] as? [String: Any])?["en"] as? String
                    ?? "Episode \(number)"
                let summary = attributes["synopsis"] as? String
                let airDate = attributes["airdate"] as? String
                let runtime = attributes["length"] as? Int
                let thumb = (attributes["thumbnail"] as? [String: Any])?["original"] as? String
                let meta = EpisodeMetadata(
                    number: number,
                    title: title,
                    summary: summary,
                    airDate: airDate,
                    runtimeMinutes: runtime,
                    thumbnailURL: thumb.flatMap(URL.init(string:))
                )
                if number > 0 {
                    result[number] = meta
                }
            }
            return result
        } catch {
            return [:]
        }
    }

    private func fetchFromTMDB(
        media: AniListMedia,
        preferredSeason: Int?,
        desiredCount: Int,
        maxEpisodeNumber: Int,
        firstEpisodeNumber: Int?
    ) async -> ([Int: EpisodeMetadata], Int, Int, Int, Int, Int, Bool, String?) {
        guard let tmdbKey, !tmdbKey.isEmpty, tmdbKey != "CHANGE_ME" else {
            return ([:], 0, preferredSeason ?? 1, 0, 0, 0, false, "missing-key")
        }

        let prefersDirectMatch = prefersDirectTVDBMatch(for: media)

        if prefersDirectMatch,
           let direct = await directEpisodeMapping(for: media, desiredCount: desiredCount) {
            return direct
        }

        if let structured = await tmdbMatcher.resolveAnimeStructure(media: media) {
            let mapped = mapAbsoluteEpisodes(
                structured,
                desiredCount: desiredCount
            )
            return (
                mapped,
                structured.showId,
                structured.currentSegment.tmdbSeasonNumber,
                structured.currentSegment.episodeOffset,
                structured.currentSegment.absoluteStart,
                structured.currentSegment.absoluteEnd,
                !mapped.isEmpty,
                mapped.isEmpty ? "empty-absolute-segment" : nil
            )
        }

        if let direct = await directEpisodeMapping(for: media, desiredCount: desiredCount) {
            return direct
        }

        return ([:], 0, preferredSeason ?? 1, 0, 0, 0, false, "no-match")
    }

    private func prefersDirectTVDBMatch(for media: AniListMedia) -> Bool {
        let format = (media.format ?? "").uppercased()
        if format.contains("MOVIE") {
            return true
        }
        if format.contains("SPECIAL") || format.contains("OVA") || format.contains("ONA") {
            return true
        }
        let title = media.title.best.lowercased()
        return title.contains(" ova")
            || title.contains(" oad")
            || title.contains(" special")
            || title.contains(" movie")
    }

    private func directEpisodeMapping(
        for media: AniListMedia,
        desiredCount: Int
    ) async -> ([Int: EpisodeMetadata], Int, Int, Int, Int, Int, Bool, String?)? {
        guard let resolved = await tmdbMatcher.matchShowAndSeason(media: media) else {
            return nil
        }

        if resolved.mediaType == "movie" {
            guard let movie = await tmdbMatcher.fetchMovieEpisode(showId: resolved.showId) else {
                return nil
            }
            return ([1: movie], resolved.showId, 1, 0, 1, 1, true, "movie-direct-fetch")
        }

        let seasonMeta = await fetchTMDBSeason(showId: resolved.showId, seasonNumber: resolved.seasonNumber)
        guard !seasonMeta.isEmpty else { return nil }

        var mapped: [Int: EpisodeMetadata] = [:]
        for (number, meta) in seasonMeta {
            let adjusted = number - resolved.episodeOffset
            if adjusted >= 1 && adjusted <= desiredCount + 5 {
                let renumbered = EpisodeMetadata(
                    number: adjusted,
                    title: meta.title,
                    summary: meta.summary,
                    airDate: meta.airDate,
                    runtimeMinutes: meta.runtimeMinutes,
                    thumbnailURL: meta.thumbnailURL
                )
                mapped[adjusted] = renumbered
            }
        }

        return (
            mapped,
            resolved.showId,
            resolved.seasonNumber,
            resolved.episodeOffset,
            0,
            0,
            !mapped.isEmpty,
            "resolved-match-direct-fetch"
        )
    }

    private func fetchTMDBSeason(showId: Int, seasonNumber: Int) async -> [Int: EpisodeMetadata] {
        guard let tmdbKey, !tmdbKey.isEmpty, tmdbKey != "CHANGE_ME" else { return [:] }
        guard let details = await tmdbMatcher.fetchSeasonDetails(showId: showId, seasonNumber: seasonNumber) else {
            return [:]
        }
        var result: [Int: EpisodeMetadata] = [:]
        for episode in details.episodes where episode.number > 0 {
            result[episode.number] = EpisodeMetadata(
                number: episode.number,
                title: episode.title ?? "Episode \(episode.number)",
                summary: episode.summary,
                airDate: episode.airDate,
                runtimeMinutes: episode.runtimeMinutes,
                thumbnailURL: episode.stillURL
            )
        }
        return result
    }

    private func applyEpisodeOffset(_ data: [Int: EpisodeMetadata], offset: Int) -> [Int: EpisodeMetadata] {
        guard offset != 0 else { return data }
        var result: [Int: EpisodeMetadata] = [:]
        for (tmdbNumber, meta) in data {
            let newNumber = tmdbNumber + offset
            guard newNumber > 0 else { continue }
            let shifted = EpisodeMetadata(
                number: newNumber,
                title: meta.title,
                summary: meta.summary,
                airDate: meta.airDate,
                runtimeMinutes: meta.runtimeMinutes,
                thumbnailURL: meta.thumbnailURL
            )
            result[newNumber] = shifted
        }
        return result
    }

    private func mapAbsoluteEpisodes(
        _ structured: TMDBAnimeStructureMatch,
        desiredCount: Int
    ) -> [Int: EpisodeMetadata] {
        let startIndex = max(0, structured.currentSegment.absoluteStart - 1)
        let endIndex = min(structured.absoluteEpisodes.count - 1, structured.currentSegment.absoluteEnd - 1)
        guard startIndex <= endIndex else { return [:] }

        let slice = Array(structured.absoluteEpisodes[startIndex...endIndex])
        var result: [Int: EpisodeMetadata] = [:]
        for (index, episode) in slice.enumerated() {
            let number = index + 1 // Always renumber to 1-based for display
            result[number] = EpisodeMetadata(
                number: number,
                title: episode.title ?? "Episode \(episode.episodeNumber)",
                summary: episode.summary,
                airDate: episode.airDate,
                runtimeMinutes: episode.runtimeMinutes,
                thumbnailURL: episode.stillURL
            )
        }
        return result
    }
}
