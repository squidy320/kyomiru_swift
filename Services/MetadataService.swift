import Foundation

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
    private let tmdbImageBase = "https://image.tmdb.org/t/p"
    private let session: URLSession
    private let cacheStore: CacheStore
    private let apiKey: String?
    private let metadataRequests = TMDBTaskCoalescer<Int, TMDBMetadata?>()
    private let logoRequests = TMDBTaskCoalescer<Int, URL?>()
    private let tmdbMatcher: TMDBMatchingService

    private struct ResolvedArtworkContext {
        let showId: Int
        let mediaType: String
        let posterSeasonNumber: Int?
    }

    init(
        cacheStore: CacheStore,
        session: URLSession = .custom,
        tmdbMatcher: TMDBMatchingService? = nil
    ) {
        self.cacheStore = cacheStore
        self.session = session
        let bundleKey = Bundle.main.object(forInfoDictionaryKey: "TMDB_API_KEY") as? String
        let defaultsKey = UserDefaults.standard.string(forKey: "TMDB_API_KEY")
        self.apiKey = (bundleKey?.isEmpty == false) ? bundleKey : defaultsKey
        self.tmdbMatcher = tmdbMatcher ?? TMDBMatchingService(cacheStore: cacheStore, session: session)
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
                    AppLog.error(.network, "tmdb api key missing")
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

    func heroBackdropURL(for media: AniListMedia) async -> URL? {
        let meta = await fetchTMDBMetadata(for: media)
        return meta?.heroBackdropURL ?? meta?.backdropURL ?? meta?.posterURL
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
            AppLog.debug(.matching, "tmdb metadata unresolved mediaId=\(media.id)")
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
            return ResolvedArtworkContext(
                showId: overrideMatch.showId,
                mediaType: mediaType,
                posterSeasonNumber: mediaType == "tv" ? overrideMatch.seasonNumber : nil
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
            return ResolvedArtworkContext(
                showId: resolved.showId,
                mediaType: resolved.mediaType,
                posterSeasonNumber: posterSeasonNumber
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
            return ResolvedArtworkContext(
                showId: target.id,
                mediaType: target.mediaType,
                posterSeasonNumber: posterSeasonNumber
            )
        }

        return nil
    }

    private func cacheStoreSeasonNumber(for aniListId: Int) -> Int? {
        MetadataCacheManager().load(aniListId: aniListId)?.seasonNumber
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
        guard let apiKey else { return nil }
        var components = URLComponents(string: "https://api.themoviedb.org/3/find/\(malId)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "external_source", value: "myanimelist_id")
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let tv = (root?["tv_results"] as? [[String: Any]])?.first,
               let id = tv["id"] as? Int {
                return id
            }
        } catch {
            return nil
        }
        return nil
    }

    private func searchTMDB(title: String, year: Int?) async -> Int? {
        guard let apiKey else { return nil }
        let sanitized = TitleSanitizer.sanitize(title)
        let queries = TitleMatcher.buildQueries(from: sanitized)
        let normalizedTarget = TitleMatcher.cleanTitle(sanitized)
        var best: (id: Int, score: Double)?

        for query in queries {
            var components = URLComponents(string: "https://api.themoviedb.org/3/search/tv")!
            components.queryItems = [
                URLQueryItem(name: "api_key", value: apiKey),
                URLQueryItem(name: "query", value: query)
            ]
            guard let url = components.url else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    continue
                }
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let results = root?["results"] as? [[String: Any]] ?? []
                for row in results {
                    guard let id = row["id"] as? Int else { continue }
                    let name = row["name"] as? String ?? row["original_name"] as? String ?? ""
                    let titleScore = TitleMatcher.diceCoefficient(
                        TitleMatcher.cleanTitle(name),
                        normalizedTarget
                    )
                    let firstAirDate = row["first_air_date"] as? String
                    let yearScore: Double
                    if let year, let parsed = yearFrom(firstAirDate) {
                        yearScore = year == parsed ? 1.0 : 0.0
                    } else {
                        yearScore = 0.5
                    }
                    let score = (0.7 * titleScore) + (0.3 * yearScore)
                    if best == nil || score > best!.score {
                        best = (id, score)
                    }
                }
            } catch {
                continue
            }
        }
        return best?.id
    }

    private func fetchTMDBDetails(showId: Int, mediaType: String, apiKey: String, includeLogo: Bool) async -> TMDBMetadata? {
        let path = mediaType == "movie" ? "movie" : "tv"
        guard let url = URL(string: "https://api.themoviedb.org/3/\(path)/\(showId)?api_key=\(apiKey)") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let title = mediaType == "movie"
                ? (root?["title"] as? String ?? root?["original_title"] as? String ?? "Unknown")
                : (root?["name"] as? String ?? root?["original_name"] as? String ?? "Unknown")
            let posterPath = root?["poster_path"] as? String
            let backdropPath = root?["backdrop_path"] as? String
            let posterURL = posterPath.flatMap { tmdbImageURL(path: $0, size: "w342") }
            let backdropURL = backdropPath.flatMap { tmdbImageURL(path: $0, size: "w780") }
            let heroBackdropURL = backdropPath.flatMap { tmdbImageURL(path: $0, size: "original") }
            let logoURL = includeLogo ? await fetchBestLogo(showId: showId, mediaType: mediaType, apiKey: apiKey) : nil
            return TMDBMetadata(
                tmdbId: showId,
                mediaType: mediaType,
                title: title,
                posterURL: posterURL,
                backdropURL: backdropURL,
                heroBackdropURL: heroBackdropURL,
                logoURL: logoURL
            )
        } catch {
            return nil
        }
    }

    private func fetchBestLogo(showId: Int, mediaType: String = "tv", apiKey: String) async -> URL? {
        let path = mediaType == "movie" ? "movie" : "tv"
        guard let url = URL(string: "https://api.themoviedb.org/3/\(path)/\(showId)/images?api_key=\(apiKey)") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let logos = root?["logos"] as? [[String: Any]] ?? []
            let filtered = logos.filter { logo in
                let filePath = (logo["file_path"] as? String) ?? ""
                let lang = (logo["iso_639_1"] as? String) ?? ""
                let isPreferredLang = lang == "en" || lang == "ja"
                return filePath.lowercased().hasSuffix(".png") && (isPreferredLang || lang.isEmpty)
            }
            let sorted = filtered.sorted { a, b in
                let sizeA = a["file_size"] as? Double ?? 0
                let sizeB = b["file_size"] as? Double ?? 0
                return sizeA > sizeB
            }
            if let best = sorted.first, let path = best["file_path"] as? String {
                return tmdbImageURL(path: path, size: "original")
            }
        } catch {
            return nil
        }
        return nil
    }

    private func tmdbImageURL(path: String, size: String) -> URL? {
        URL(string: "\(tmdbImageBase)/\(size)\(path)")
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
            return "tmdb:media:v14:manual:\(mediaId):type:\(overrideMatch.mediaType ?? "tv"):show:\(overrideMatch.showId):season:\(overrideMatch.seasonNumber):offset:\(overrideMatch.episodeOffset)"
        }
        return "tmdb:media:v14:\(mediaId)"
    }

    private func logoCacheKey(for mediaId: Int) -> String {
        if let overrideMatch = tmdbMatcher.manualOverride(for: mediaId) {
            return "tmdb:logo:v4:manual:\(mediaId):type:\(overrideMatch.mediaType ?? "tv"):show:\(overrideMatch.showId)"
        }
        return "tmdb:logo:v4:\(mediaId)"
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
        cacheStore.removeKeys(withPrefix: "tmdb:logo:v1:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:logo:v1:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:logo:v2:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:logo:v2:manual:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:logo:v3:\(mediaId)")
        cacheStore.removeKeys(withPrefix: "tmdb:logo:v3:manual:\(mediaId)")
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
        let bundleKey = Bundle.main.object(forInfoDictionaryKey: "TMDB_API_KEY") as? String
        let defaultsKey = UserDefaults.standard.string(forKey: "TMDB_API_KEY")
        self.apiKey = (bundleKey?.isEmpty == false) ? bundleKey : defaultsKey
        self.tmdbMatcher = tmdbMatcher ?? TMDBMatchingService(cacheStore: cacheStore, session: session)
    }

    func ratingsForSeason(
        media: AniListMedia,
        seasonNumber: Int = 1,
        firstEpisodeNumber: Int? = nil
    ) async -> [Int: Double] {
        guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else {
            AppLog.error(.network, "tmdb api key missing")
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
        var components = URLComponents(string: "https://api.themoviedb.org/3/find/\(malId)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "external_source", value: "myanimelist_id")
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let tv = (root?["tv_results"] as? [[String: Any]])?.first,
               let id = tv["id"] as? Int {
                return id
            }
        } catch {
            return nil
        }
        return nil
    }

    private func searchTMDB(title: String, apiKey: String) async -> Int? {
        let sanitized = TitleSanitizer.sanitize(title)
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/tv")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: sanitized)
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let results = root?["results"] as? [[String: Any]]
            return results?.first?["id"] as? Int
        } catch {
            return nil
        }
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
    private let imageBase = "https://image.tmdb.org/t/p/original"

    init(cacheStore: CacheStore, session: URLSession = .custom) {
        self.cacheStore = cacheStore
        self.session = session
        let bundleKey = Bundle.main.object(forInfoDictionaryKey: "TMDB_API_KEY") as? String
        let defaultsKey = UserDefaults.standard.string(forKey: "TMDB_API_KEY")
        self.apiKey = (bundleKey?.isEmpty == false) ? bundleKey : defaultsKey
    }

    func fetchTrending() async -> [TrendingItem] {
        let cacheKey = "tmdb:trending:tv:week"
        if let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 30),
           let decoded = try? JSONDecoder().decode([TrendingItem].self, from: cached) {
            return decoded
        }

        guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else {
            AppLog.error(.network, "tmdb api key missing")
            return []
        }

        var components = URLComponents(string: "https://api.themoviedb.org/3/trending/tv/week")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "with_genres", value: "16"),
            URLQueryItem(name: "with_original_language", value: "ja")
        ]
        guard let url = components.url else { return [] }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let results = root?["results"] as? [[String: Any]] ?? []
            var items: [TrendingItem] = []
            for row in results {
                guard let id = row["id"] as? Int else { continue }
                let name = row["name"] as? String ?? row["original_name"] as? String ?? "Unknown"
                let backdrop = (row["backdrop_path"] as? String).flatMap { URL(string: "\(imageBase)\($0)") }
                let logo = await fetchBestLogo(tvId: id, apiKey: apiKey)
                items.append(TrendingItem(id: id, title: name, backdropURL: backdrop, logoURL: logo))
            }

            if let data = try? JSONEncoder().encode(items) {
                cacheStore.writeJSON(data, forKey: cacheKey)
            }
            return items
        } catch {
            return []
        }
    }

    func fetchRandomDiscoverAnime(minVoteCount: Int = 50) async -> TrendingItem? {
        guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else {
            AppLog.error(.network, "tmdb api key missing")
            return nil
        }

        let totalPages = await fetchDiscoverTotalPages(apiKey: apiKey, minVoteCount: minVoteCount)
        guard totalPages > 0 else { return nil }
        let cappedPages = min(totalPages, 500)
        let randomPage = Int.random(in: 1...cappedPages)
        guard let item = await fetchDiscoverPage(apiKey: apiKey, page: randomPage, minVoteCount: minVoteCount)?.randomElement() else {
            return nil
        }
        let logo = await fetchBestLogo(tvId: item.id, apiKey: apiKey)
        return TrendingItem(id: item.id, title: item.title, backdropURL: item.backdropURL, logoURL: logo)
    }

    private func fetchBestLogo(tvId: Int, apiKey: String) async -> URL? {
        guard let url = URL(string: "https://api.themoviedb.org/3/tv/\(tvId)/images?api_key=\(apiKey)") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let logos = root?["logos"] as? [[String: Any]] ?? []
            let filtered = logos.filter { logo in
                let filePath = (logo["file_path"] as? String) ?? ""
                let lang = (logo["iso_639_1"] as? String) ?? ""
                let isPreferredLang = lang == "en" || lang == "ja"
                return filePath.lowercased().hasSuffix(".png") && (isPreferredLang || lang.isEmpty)
            }
            let sorted = filtered.sorted { a, b in
                let sizeA = a["file_size"] as? Double ?? 0
                let sizeB = b["file_size"] as? Double ?? 0
                return sizeA > sizeB
            }
            if let best = sorted.first, let path = best["file_path"] as? String {
                return URL(string: "\(imageBase)\(path)")
            }
        } catch {
            return nil
        }
        return nil
    }

    private func fetchDiscoverTotalPages(apiKey: String, minVoteCount: Int) async -> Int {
        var components = URLComponents(string: "https://api.themoviedb.org/3/discover/tv")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "with_genres", value: "16"),
            URLQueryItem(name: "with_original_language", value: "ja"),
            URLQueryItem(name: "vote_count.gte", value: String(minVoteCount))
        ]
        guard let url = components.url else { return 0 }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return 0
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return root?["total_pages"] as? Int ?? 0
        } catch {
            return 0
        }
    }

    private func fetchDiscoverPage(apiKey: String, page: Int, minVoteCount: Int) async -> [TrendingItem]? {
        var components = URLComponents(string: "https://api.themoviedb.org/3/discover/tv")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "with_genres", value: "16"),
            URLQueryItem(name: "with_original_language", value: "ja"),
            URLQueryItem(name: "vote_count.gte", value: String(minVoteCount)),
            URLQueryItem(name: "page", value: String(page))
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let results = root?["results"] as? [[String: Any]] ?? []
            let items: [TrendingItem] = results.compactMap { row in
                guard let id = row["id"] as? Int else { return nil }
                let name = row["name"] as? String ?? row["original_name"] as? String ?? "Unknown"
                let backdrop = (row["backdrop_path"] as? String).flatMap { URL(string: "\(imageBase)\($0)") }
                return TrendingItem(id: id, title: name, backdropURL: backdrop, logoURL: nil)
            }
            return items
        } catch {
            return nil
        }
    }
}

final class EpisodeMetadataService {
    enum Provider: String {
        case kitsu
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
        provider: Provider = .tmdb,
        session: URLSession = .custom,
        tmdbMatcher: TMDBMatchingService? = nil,
        preferenceStore: EpisodeMetadataPreferenceStore = .shared
    ) {
        self.cacheStore = cacheStore
        self.session = session
        self.provider = provider
        self.aniListClient = aniListClient
        self.tmdbMatcher = tmdbMatcher ?? TMDBMatchingService(cacheStore: cacheStore, session: session)
        let bundleKey = Bundle.main.object(forInfoDictionaryKey: "TMDB_API_KEY") as? String
        let defaultsKey = UserDefaults.standard.string(forKey: "TMDB_API_KEY")
        self.tmdbKey = (bundleKey?.isEmpty == false) ? bundleKey : defaultsKey
        self.cacheManager = MetadataCacheManager()
        self.preferenceStore = preferenceStore
    }

    func preferredProvider(for media: AniListMedia) -> Provider {
        .tmdb
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
        case .tmdb:
            let desiredCount = episodes.isEmpty ? (media.episodes ?? 0) : episodes.count
            let maxEpisodeNumber = episodes.map(\.number).max() ?? 0
            let globalNumbering = maxEpisodeNumber >= desiredCount + 5 && maxEpisodeNumber > 0
            let maxKey = globalNumbering ? ":max:\(maxEpisodeNumber)" : ""
            let structureKey = "tmdb:structure:v7:\(media.id)"
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
        case .tmdb:
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

        if let resolved = await tmdbMatcher.matchShowAndSeason(media: media) {
            let seasonMeta = await fetchTMDBSeason(showId: resolved.showId, seasonNumber: resolved.seasonNumber)
            if !seasonMeta.isEmpty {
                var mapped: [Int: EpisodeMetadata] = [:]
                // Apply offset to map season episode numbers to local display numbers (starting at 1)
                for (number, meta) in seasonMeta {
                    let adjusted = number - resolved.episodeOffset
                    if adjusted >= 1 && adjusted <= desiredCount + 5 { // allowance for slight mismatch
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
                return (mapped, resolved.showId, resolved.seasonNumber, resolved.episodeOffset, 0, 0, !mapped.isEmpty, "resolved-match-direct-fetch")
            }
        }

        return ([:], 0, preferredSeason ?? 1, 0, 0, 0, false, "no-match")
    }

    private func fetchTMDBSeason(showId: Int, seasonNumber: Int) async -> [Int: EpisodeMetadata] {
        guard let tmdbKey else { return [:] }
        guard let url = URL(string: "https://api.themoviedb.org/3/tv/\(showId)/season/\(seasonNumber)?api_key=\(tmdbKey)") else {
            return [:]
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return [:]
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rows = root?["episodes"] as? [[String: Any]] ?? []
            var result: [Int: EpisodeMetadata] = [:]
            for row in rows {
                let number = row["episode_number"] as? Int ?? 0
                let title = row["name"] as? String ?? "Episode \(number)"
                let summary = row["overview"] as? String
                let airDate = row["air_date"] as? String
                let runtime = (row["runtime"] as? Int) ?? (row["runtime"] as? [Int])?.first
                let stillPath = row["still_path"] as? String
                let thumb = stillPath.map { "https://image.tmdb.org/t/p/w780\($0)" }
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
