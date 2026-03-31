import Foundation

private actor TMDBMatchTaskCoalescer<Key: Hashable, Value> {
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

private actor TMDBMatchRequestLimiter {
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

struct TMDBSeasonMatch: Equatable, Codable {
    let showId: Int
    let mediaType: String
    let seasonNumber: Int
    let episodeOffset: Int
}

struct TMDBResolvedMatch: Equatable, Codable {
    let showId: Int
    let mediaType: String
    let seasonNumber: Int
    let episodeOffset: Int
    let confidence: Double
    let reason: String
}

struct AbsoluteTMDBEpisode: Equatable, Codable {
    let absoluteNumber: Int
    let seasonNumber: Int
    let episodeNumber: Int
    let title: String?
    let summary: String?
    let airDate: String?
    let runtimeMinutes: Int?
    let stillURL: URL?
    let rating: Double?
}

struct AniListTMDBSegment: Equatable, Codable {
    let mediaId: Int
    let displayLabel: String
    let episodeCount: Int
    let tmdbSeasonNumber: Int
    let episodeOffset: Int
    let absoluteStart: Int
    let absoluteEnd: Int
    let posterSeasonNumber: Int
    let reason: String
}

struct TMDBAnimeStructureMatch: Equatable, Codable {
    let showId: Int
    let mediaType: String
    let showTitle: String
    let absoluteEpisodes: [AbsoluteTMDBEpisode]
    let segments: [AniListTMDBSegment]
    let currentSegment: AniListTMDBSegment
    let reason: String

    var tmdbId: Int { showId }
    var currentAniListMediaId: Int { currentSegment.mediaId }
    var currentSlice: AniListTMDBSegment { currentSegment }
    var franchiseContext: [AniListTMDBSegment]? { segments }
}

struct TMDBSearchResult: Identifiable, Equatable {
    let id: Int
    let mediaType: String
    let title: String
    let posterURL: URL?
    let firstAirYear: Int?
}

struct TMDBSeasonChoice: Identifiable, Equatable {
    var id: String { "\(mediaType)-\(showId)-\(tmdbSeasonNumber)-\(episodeOffset)-\(displayLabel)" }
    let showId: Int
    let mediaType: String
    let showTitle: String
    let tmdbSeasonNumber: Int
    let episodeOffset: Int
    let displayEpisodeCount: Int
    let displayLabel: String
    let isSynthetic: Bool
    let mappedAniListMediaId: Int?
    let mappingReason: String?
    let name: String
    let airYear: Int?

    var seasonNumber: Int { tmdbSeasonNumber }
    var episodeCount: Int { displayEpisodeCount }
}

struct TMDBSeasonDetails: Equatable, Codable {
    struct Episode: Equatable, Codable {
        let number: Int
        let title: String?
        let summary: String?
        let airDate: String?
        let runtimeMinutes: Int?
        let stillURL: URL?
        let rating: Double?
    }

    let posterURL: URL?
    let episodes: [Episode]
}

private struct TMDBMovieDetails: Equatable, Codable {
    let title: String
    let summary: String?
    let releaseDate: String?
    let runtimeMinutes: Int?
    let posterURL: URL?
    let backdropURL: URL?
    let rating: Double?
}

private struct TMDBSeasonMatchNegativeCacheEntry: Codable {
    let missing: Bool
}

private enum TMDBMatchCacheResult {
    case hit(TMDBResolvedMatch)
    case negative
    case missing
}

final class TMDBMatchingService {
    private static let matchCacheTTL: TimeInterval = 60 * 60 * 12
    private static let negativeMatchCacheTTL: TimeInterval = 60 * 30
    private static let structureCacheTTL: TimeInterval = 60 * 30
    private static let requestLimiter = TMDBMatchRequestLimiter(maxConcurrent: 3)

    private let session: URLSession
    private let cacheStore: CacheStore
    private let cacheManager: MetadataCacheManager
    private let overrideStore: TMDBOverrideStore
    private let aniListClient: AniListClient?
    private let apiKey: String?
    private let dateFormatter: DateFormatter
    private let matchRequests = TMDBMatchTaskCoalescer<String, TMDBResolvedMatch?>()
    private let seasonDetailRequests = TMDBMatchTaskCoalescer<String, TMDBSeasonDetails?>()
    private let structureRequests = TMDBMatchTaskCoalescer<String, TMDBAnimeStructureMatch?>()
    private let movieDetailRequests = TMDBMatchTaskCoalescer<Int, TMDBMovieDetails?>()

    init(
        cacheStore: CacheStore,
        session: URLSession = .custom,
        cacheManager: MetadataCacheManager = MetadataCacheManager(),
        overrideStore: TMDBOverrideStore = .shared,
        aniListClient: AniListClient? = nil
    ) {
        self.cacheStore = cacheStore
        self.session = session
        self.cacheManager = cacheManager
        self.overrideStore = overrideStore
        self.aniListClient = aniListClient
        let bundleKey = Bundle.main.object(forInfoDictionaryKey: "TMDB_API_KEY") as? String
        let defaultsKey = UserDefaults.standard.string(forKey: "TMDB_API_KEY")
        self.apiKey = (bundleKey?.isEmpty == false) ? bundleKey : defaultsKey
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        self.dateFormatter = formatter
    }

    static func cacheKey(
        mediaId: Int,
        preferredSeasonNumber: Int?,
        firstEpisodeNumber: Int?,
        expectedEpisodeCount: Int?,
        maxEpisodeNumber: Int?
    ) -> String {
        "tmdb:match:v10:\(mediaId):preferred:\(preferredSeasonNumber ?? 0):first:\(firstEpisodeNumber ?? 1):count:\(expectedEpisodeCount ?? 0):max:\(maxEpisodeNumber ?? 0)"
    }

    func matchShowAndSeason(
        media: AniListMedia,
        franchiseStartYear: Int? = nil,
        firstEpisodeNumber: Int? = nil,
        preferredSeasonNumber: Int? = nil,
        expectedEpisodeCount: Int? = nil,
        maxEpisodeNumber: Int? = nil
    ) async -> TMDBSeasonMatch? {
        let resolved = await resolveShowAndSeason(
            media: media,
            franchiseStartYear: franchiseStartYear,
            firstEpisodeNumber: firstEpisodeNumber,
            preferredSeasonNumber: preferredSeasonNumber,
            expectedEpisodeCount: expectedEpisodeCount,
            maxEpisodeNumber: maxEpisodeNumber
        )
        guard let resolved else { return nil }
        return TMDBSeasonMatch(
            showId: resolved.showId,
            mediaType: resolved.mediaType,
            seasonNumber: resolved.seasonNumber,
            episodeOffset: resolved.episodeOffset
        )
    }

    func resolveShowAndSeason(
        media: AniListMedia,
        franchiseStartYear: Int? = nil,
        firstEpisodeNumber: Int? = nil,
        preferredSeasonNumber: Int? = nil,
        expectedEpisodeCount: Int? = nil,
        maxEpisodeNumber: Int? = nil
    ) async -> TMDBResolvedMatch? {
        guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else { return nil }

        if let overrideMatch = manualOverride(for: media.id) {
            return TMDBResolvedMatch(
                showId: overrideMatch.showId,
                mediaType: overrideMatch.mediaType ?? "tv",
                seasonNumber: overrideMatch.seasonNumber,
                episodeOffset: overrideMatch.episodeOffset,
                confidence: 1.0,
                reason: "manual-override"
            )
        }

        let preferredSeason = preferredSeasonNumber ?? TitleMatcher.extractSeasonNumber(from: media.title.best)
        let cacheKey = Self.cacheKey(
            mediaId: media.id,
            preferredSeasonNumber: preferredSeason,
            firstEpisodeNumber: firstEpisodeNumber,
            expectedEpisodeCount: expectedEpisodeCount,
            maxEpisodeNumber: maxEpisodeNumber
        )

        if let cached = cacheManager.load(aniListId: media.id),
           isCachedMetadataUsable(
                cached,
                firstEpisodeNumber: firstEpisodeNumber,
                preferredSeasonNumber: preferredSeason,
                expectedEpisodeCount: expectedEpisodeCount,
                maxEpisodeNumber: maxEpisodeNumber
           ) {
            return TMDBResolvedMatch(
                showId: cached.showId,
                mediaType: "tv",
                seasonNumber: cached.seasonNumber,
                episodeOffset: cached.episodeOffset,
                confidence: 0.95,
                reason: "disk-cache"
            )
        }

        switch cachedSeasonMatch(forKey: cacheKey) {
        case .hit(let cachedResult):
            return cachedResult
        case .negative:
            return nil
        case .missing:
            break
        }

        return await matchRequests.value(for: cacheKey) { [self] in
            await Self.requestLimiter.run {
                if let cached = self.cacheManager.load(aniListId: media.id),
                   self.isCachedMetadataUsable(
                        cached,
                        firstEpisodeNumber: firstEpisodeNumber,
                        preferredSeasonNumber: preferredSeason,
                        expectedEpisodeCount: expectedEpisodeCount,
                        maxEpisodeNumber: maxEpisodeNumber
                   ) {
                    return TMDBResolvedMatch(
                        showId: cached.showId,
                        mediaType: "tv",
                        seasonNumber: cached.seasonNumber,
                        episodeOffset: cached.episodeOffset,
                        confidence: 0.95,
                        reason: "disk-cache"
                    )
                }

                switch self.cachedSeasonMatch(forKey: cacheKey) {
                case .hit(let cachedResult):
                    return cachedResult
                case .negative:
                    return nil
                case .missing:
                    break
                }

                let titles = await self.candidateTitles(for: media)
                let startYear = franchiseStartYear ?? media.startDate?.year ?? media.seasonYear
                guard let target = await self.findTarget(media: media, titles: titles, startYear: startYear),
                      let show = await self.fetchShowSummary(showId: target.id, mediaType: target.mediaType, apiKey: apiKey) else {
                    self.writeNegativeSeasonMatchCache(forKey: cacheKey)
                    return nil
                }

                let structured = await self.resolveAnimeStructure(
                    media: media,
                    showIdOverride: target.id,
                    mediaTypeOverride: target.mediaType,
                    showOverride: show
                )

                let selection = structured.map {
                    SelectedSeason(
                        seasonNumber: $0.currentSegment.tmdbSeasonNumber,
                        episodeOffset: $0.currentSegment.episodeOffset,
                        confidence: 0.99,
                        reason: $0.reason
                    )
                } ?? self.selectSeason(
                    media: media,
                    show: show,
                    preferredSeasonNumber: preferredSeason,
                    firstEpisodeNumber: firstEpisodeNumber,
                    expectedEpisodeCount: expectedEpisodeCount,
                    maxEpisodeNumber: maxEpisodeNumber
                )

                guard let selection else {
                    self.writeNegativeSeasonMatchCache(forKey: cacheKey)
                    return nil
                }

                let resolved = TMDBResolvedMatch(
                    showId: show.showId,
                    mediaType: show.mediaType,
                    seasonNumber: selection.seasonNumber,
                    episodeOffset: selection.episodeOffset,
                    confidence: selection.confidence,
                    reason: selection.reason
                )

                if show.mediaType == "tv",
                   let seasonDetails = await self.fetchSeasonDetails(
                    aniListId: media.id,
                    showId: resolved.showId,
                    seasonNumber: resolved.seasonNumber
                ) {
                    self.cacheManager.save(
                        TMDBCachedMetadata(
                            aniListId: media.id,
                            showId: resolved.showId,
                            seasonNumber: resolved.seasonNumber,
                            episodeOffset: resolved.episodeOffset,
                            cachedAt: Date(),
                            seasonDetails: seasonDetails
                        )
                    )
                }

                if let data = try? JSONEncoder().encode(resolved) {
                    self.cacheStore.writeJSON(data, forKey: cacheKey)
                }

                AppLog.debug(
                    .matching,
                    "tmdb resolved match mediaId=\(media.id) showId=\(resolved.showId) season=\(resolved.seasonNumber) offset=\(resolved.episodeOffset) reason=\(resolved.reason)"
                )
                return resolved
            }
        }
    }

    func resolveAnimeStructure(media: AniListMedia) async -> TMDBAnimeStructureMatch? {
        let requestKey = "tmdb:structure:v6:\(media.id)"
        if let cached = cacheStore.readJSON(forKey: requestKey, maxAge: Self.structureCacheTTL),
           let decoded = try? JSONDecoder().decode(TMDBAnimeStructureMatch.self, from: cached) {
            return decoded
        }

                let resolved = await structureRequests.value(for: requestKey) { [self] in
            await resolveAnimeStructure(
                media: media,
                showIdOverride: nil,
                mediaTypeOverride: nil,
                showOverride: nil
            )
        }

        if let resolved, let data = try? JSONEncoder().encode(resolved) {
            cacheStore.writeJSON(data, forKey: requestKey)
        }
        return resolved
    }

    func resolveShowId(media: AniListMedia) async -> Int? {
        await resolveArtworkTarget(media: media)?.id
    }

    func resolveArtworkTarget(media: AniListMedia) async -> TMDBSearchResult? {
        if let overrideMatch = manualOverride(for: media.id) {
            return TMDBSearchResult(
                id: overrideMatch.showId,
                mediaType: overrideMatch.mediaType ?? "tv",
                title: overrideMatch.showTitle ?? media.title.best,
                posterURL: nil,
                firstAirYear: media.startDate?.year ?? media.seasonYear
            )
        }
        let startYear = media.startDate?.year ?? media.seasonYear
        let directTitles = Array(normalizedCandidateTitleSet(from: [media]))
        if let direct = await findTarget(media: media, titles: directTitles, startYear: startYear) {
            return direct
        }
        let titles = await candidateTitles(for: media)
        return await findTarget(media: media, titles: titles, startYear: startYear)
    }

    private func resolveAnimeStructure(
        media: AniListMedia,
        showIdOverride: Int? = nil,
        mediaTypeOverride: String? = nil,
        showOverride: TMDBShowSummary? = nil
    ) async -> TMDBAnimeStructureMatch? {
        guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else { return nil }

        let showId: Int
        let mediaType: String
        if let showIdOverride {
            showId = showIdOverride
            mediaType = mediaTypeOverride ?? "tv"
        } else if let overrideMatch = manualOverride(for: media.id) {
            showId = overrideMatch.showId
            mediaType = overrideMatch.mediaType ?? "tv"
        } else {
            guard let target = await resolveArtworkTarget(media: media) else {
                return nil
            }
            showId = target.id
            mediaType = target.mediaType
        }

        let show: TMDBShowSummary?
        if let showOverride {
            show = showOverride
        } else {
            show = await fetchShowSummary(showId: showId, mediaType: mediaType, apiKey: apiKey)
        }

        guard let show else {
            return nil
        }

        let absoluteEpisodes = await flattenAbsoluteEpisodes(show: show)
        guard !absoluteEpisodes.isEmpty else {
            return nil
        }

        if let overrideMatch = manualOverride(for: media.id),
           overrideMatch.showId == show.showId,
           (overrideMatch.mediaType ?? show.mediaType) == show.mediaType,
           let currentSegment = buildManualOverrideSegment(
                overrideMatch: overrideMatch,
                media: media,
                show: show,
                absoluteEpisodes: absoluteEpisodes
           ) {
            return TMDBAnimeStructureMatch(
                showId: show.showId,
                mediaType: show.mediaType,
                showTitle: show.title,
                absoluteEpisodes: absoluteEpisodes,
                segments: [currentSegment],
                currentSegment: currentSegment,
                reason: "manual-override"
            )
        }

        guard let franchise = await buildLunaFranchise(for: media, show: show) else {
            return nil
        }

        let fittedCurrent = fitCurrentNode(
            media: media,
            franchise: franchise,
            onto: absoluteEpisodes,
            show: show
        )
        let fullSegments = mapFranchise(franchise, onto: absoluteEpisodes, show: show)
        let currentSegment = fittedCurrent ?? fullSegments?.first(where: { $0.mediaId == media.id })
        guard let currentSegment else { return nil }
        let segments = fullSegments ?? [currentSegment]

        return TMDBAnimeStructureMatch(
            showId: show.showId,
            mediaType: show.mediaType,
            showTitle: show.title,
            absoluteEpisodes: absoluteEpisodes,
            segments: segments,
            currentSegment: currentSegment,
            reason: fittedCurrent?.reason ?? "soupy-luna-franchise-fallback"
        )
    }

    private func buildManualOverrideSegment(
        overrideMatch: TMDBManualOverride,
        media: AniListMedia,
        show: TMDBShowSummary,
        absoluteEpisodes: [AbsoluteTMDBEpisode]
    ) -> AniListTMDBSegment? {
        if show.mediaType == "movie" {
            guard let first = absoluteEpisodes.first else { return nil }
            return AniListTMDBSegment(
                mediaId: media.id,
                displayLabel: overrideMatch.seasonLabel ?? "Movie",
                episodeCount: 1,
                tmdbSeasonNumber: first.seasonNumber,
                episodeOffset: 0,
                absoluteStart: 1,
                absoluteEnd: 1,
                posterSeasonNumber: first.seasonNumber,
                reason: "manual-override"
            )
        }

        let seasonEpisodes = absoluteEpisodes.filter { $0.seasonNumber == overrideMatch.seasonNumber }
        guard !seasonEpisodes.isEmpty else { return nil }

        let startInSeason = min(max(overrideMatch.episodeOffset, 0), max(seasonEpisodes.count - 1, 0))
        let requestedCount = max(media.episodes ?? (seasonEpisodes.count - startInSeason), 1)
        let availableCount = max(seasonEpisodes.count - startInSeason, 1)
        let episodeCount = min(requestedCount, availableCount)
        guard episodeCount > 0 else { return nil }

        let firstSeasonEpisode = seasonEpisodes[startInSeason]
        let absoluteStart = firstSeasonEpisode.absoluteNumber
        let absoluteEnd = min(absoluteStart + episodeCount - 1, absoluteEpisodes.count)

        return AniListTMDBSegment(
            mediaId: media.id,
            displayLabel: overrideMatch.seasonLabel ?? "Season \(overrideMatch.seasonNumber)",
            episodeCount: episodeCount,
            tmdbSeasonNumber: overrideMatch.seasonNumber,
            episodeOffset: startInSeason,
            absoluteStart: absoluteStart,
            absoluteEnd: absoluteEnd,
            posterSeasonNumber: overrideMatch.seasonNumber,
            reason: "manual-override"
        )
    }

    func fetchSeasonDetails(aniListId: Int, showId: Int, seasonNumber: Int) async -> TMDBSeasonDetails? {
        if let cached = cacheManager.load(aniListId: aniListId),
           cached.showId == showId,
           cached.seasonNumber == seasonNumber,
           let details = cached.seasonDetails {
            return details
        }
        return await fetchSeasonDetails(showId: showId, seasonNumber: seasonNumber)
    }

    func manualOverride(for aniListId: Int) -> TMDBManualOverride? {
        overrideStore.override(for: aniListId)
    }

    func saveManualOverride(
        aniListId: Int,
        showId: Int,
        mediaType: String = "tv",
        seasonNumber: Int,
        episodeOffset: Int = 0,
        showTitle: String? = nil,
        seasonLabel: String? = nil
    ) async {
        let overrideMatch = TMDBManualOverride(
            aniListId: aniListId,
            showId: showId,
            mediaType: mediaType,
            seasonNumber: seasonNumber,
            episodeOffset: episodeOffset,
            showTitle: showTitle,
            seasonLabel: seasonLabel,
            updatedAt: Date().timeIntervalSince1970
        )
        overrideStore.save(overrideMatch)
        if let details = await fetchSeasonDetails(showId: showId, seasonNumber: seasonNumber) {
            cacheManager.save(
                TMDBCachedMetadata(
                    aniListId: aniListId,
                    showId: showId,
                    seasonNumber: seasonNumber,
                    episodeOffset: episodeOffset,
                    cachedAt: Date(),
                    seasonDetails: details
                )
            )
        }
    }

    func clearManualOverride(aniListId: Int) {
        overrideStore.clear(aniListId: aniListId)
        cacheManager.clear(aniListId: aniListId)
    }

    func searchShows(query: String) async -> [TMDBSearchResult] {
        guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let queries = TitleMatcher.buildQueries(from: trimmed)
        var resultsById: [String: TMDBSearchResult] = [:]

        for query in queries where !query.isEmpty {
            for mediaType in ["tv", "movie"] {
                var components = URLComponents(string: "https://api.themoviedb.org/3/search/\(mediaType)")!
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
                    let rows = root?["results"] as? [[String: Any]] ?? []
                    for row in rows {
                        if mediaType == "movie" && !isLikelyAnimeMovie(row) {
                            continue
                        }
                        guard let id = row["id"] as? Int else { continue }
                        let title = mediaType == "movie"
                            ? (row["title"] as? String ?? row["original_title"] as? String ?? "Unknown")
                            : (row["name"] as? String ?? row["original_name"] as? String ?? "Unknown")
                        let posterPath = row["poster_path"] as? String
                        let year = yearFrom(mediaType == "movie" ? row["release_date"] as? String : row["first_air_date"] as? String)
                        resultsById["\(mediaType):\(id)"] = TMDBSearchResult(
                            id: id,
                            mediaType: mediaType,
                            title: title,
                            posterURL: posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w185\($0)") },
                            firstAirYear: year
                        )
                    }
                } catch {
                    continue
                }
            }
        }

        return resultsById.values.sorted { lhs, rhs in
            if lhs.firstAirYear == rhs.firstAirYear {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return (lhs.firstAirYear ?? 0) > (rhs.firstAirYear ?? 0)
        }
    }

    func fetchSeasonChoices(for media: AniListMedia, showId: Int, mediaType: String = "tv") async -> [TMDBSeasonChoice] {
        guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else { return [] }
        guard let summary = await fetchShowSummary(showId: showId, mediaType: mediaType, apiKey: apiKey) else { return [] }
        if let structured = await resolveAnimeStructure(media: media, showIdOverride: showId, mediaTypeOverride: mediaType, showOverride: summary) {
            let structuredChoices = structured.segments.map { segment in
                TMDBSeasonChoice(
                    showId: showId,
                    mediaType: mediaType,
                    showTitle: structured.showTitle,
                    tmdbSeasonNumber: segment.tmdbSeasonNumber,
                    episodeOffset: segment.episodeOffset,
                    displayEpisodeCount: segment.episodeCount,
                    displayLabel: segment.displayLabel,
                    isSynthetic: true,
                    mappedAniListMediaId: segment.mediaId,
                    mappingReason: segment.reason,
                    name: segment.displayLabel,
                    airYear: nil
                )
            }
            if !structuredChoices.isEmpty {
                return structuredChoices
            }
        }
        let rawChoices = summary.seasons
            .filter { !$0.isSpecial }
            .map { season in
                TMDBSeasonChoice(
                    showId: showId,
                    mediaType: mediaType,
                    showTitle: summary.title,
                    tmdbSeasonNumber: season.seasonNumber,
                    episodeOffset: 0,
                    displayEpisodeCount: season.episodeCount,
                    displayLabel: season.name ?? "Season \(season.seasonNumber)",
                    isSynthetic: false,
                    mappedAniListMediaId: nil,
                    mappingReason: nil,
                    name: season.name ?? "Season \(season.seasonNumber)",
                    airYear: yearFrom(season.airDateString)
                )
            }
        if mediaType == "movie" {
            return [
                TMDBSeasonChoice(
                    showId: showId,
                    mediaType: mediaType,
                    showTitle: summary.title,
                    tmdbSeasonNumber: 1,
                    episodeOffset: 0,
                    displayEpisodeCount: max(media.episodes ?? 1, 1),
                    displayLabel: "Movie",
                    isSynthetic: true,
                    mappedAniListMediaId: media.id,
                    mappingReason: "movie-target",
                    name: "Movie",
                    airYear: summary.seasons.first.flatMap { yearFrom($0.airDateString) }
                )
            ]
        }
        if let syntheticChoices = await syntheticSeasonChoices(for: media, show: summary),
           !syntheticChoices.isEmpty {
            return syntheticChoices
        }
        return rawChoices
    }

    func fetchSeasonDetails(showId: Int, seasonNumber: Int) async -> TMDBSeasonDetails? {
        let requestKey = "\(showId):\(seasonNumber)"
        return await seasonDetailRequests.value(for: requestKey) { [self] in
            guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else { return nil }
            guard let url = URL(string: "https://api.themoviedb.org/3/tv/\(showId)/season/\(seasonNumber)?api_key=\(apiKey)") else {
                return nil
            }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    return nil
                }
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let posterPath = root?["poster_path"] as? String
                let posterURL = posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/original\($0)") }
                let rows = root?["episodes"] as? [[String: Any]] ?? []
                let episodes = rows.compactMap { row -> TMDBSeasonDetails.Episode? in
                    let number = row["episode_number"] as? Int ?? 0
                    let title = row["name"] as? String
                    let summary = row["overview"] as? String
                    let airDate = row["air_date"] as? String
                    let runtimeMinutes = (row["runtime"] as? Int) ?? (row["runtime"] as? [Int])?.first
                    let still = row["still_path"] as? String
                    let rating = row["vote_average"] as? Double
                    guard number > 0 else { return nil }
                    return TMDBSeasonDetails.Episode(
                        number: number,
                        title: title,
                        summary: summary,
                        airDate: airDate,
                        runtimeMinutes: runtimeMinutes,
                        stillURL: still.flatMap { URL(string: "https://image.tmdb.org/t/p/w780\($0)") },
                        rating: rating
                    )
                }
                return TMDBSeasonDetails(posterURL: posterURL, episodes: episodes)
            } catch {
                return nil
            }
        }
    }

    private func fetchMovieDetails(movieId: Int, apiKey: String) async -> TMDBMovieDetails? {
        return await movieDetailRequests.value(for: movieId) { [self] in
            guard let url = URL(string: "https://api.themoviedb.org/3/movie/\(movieId)?api_key=\(apiKey)") else {
                return nil
            }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    return nil
                }
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let title = root?["title"] as? String ?? root?["original_title"] as? String ?? "Unknown"
                let summary = root?["overview"] as? String
                let releaseDate = root?["release_date"] as? String
                let runtime = root?["runtime"] as? Int
                let posterURL = (root?["poster_path"] as? String).flatMap { URL(string: "https://image.tmdb.org/t/p/original\($0)") }
                let backdropURL = (root?["backdrop_path"] as? String).flatMap { URL(string: "https://image.tmdb.org/t/p/w780\($0)") }
                let rating = root?["vote_average"] as? Double
                return TMDBMovieDetails(
                    title: title,
                    summary: summary,
                    releaseDate: releaseDate,
                    runtimeMinutes: runtime,
                    posterURL: posterURL,
                    backdropURL: backdropURL,
                    rating: rating
                )
            } catch {
                return nil
            }
        }
    }

    private func isCachedMetadataUsable(
        _ cached: TMDBCachedMetadata,
        firstEpisodeNumber: Int?,
        preferredSeasonNumber: Int?,
        expectedEpisodeCount: Int?,
        maxEpisodeNumber: Int?
    ) -> Bool {
        if let preferredSeasonNumber, preferredSeasonNumber > 0, cached.seasonNumber != preferredSeasonNumber {
            return false
        }
        if let expectedEpisodeCount, expectedEpisodeCount > 0,
           let maxEpisodeNumber, maxEpisodeNumber >= expectedEpisodeCount + 5,
           cached.episodeOffset == 0 {
            return false
        }
        if let firstEpisodeNumber, firstEpisodeNumber > 1, cached.episodeOffset == 0 {
            return false
        }
        return true
    }

    private func cachedSeasonMatch(forKey key: String) -> TMDBMatchCacheResult {
        if let cached = cacheStore.readJSON(forKey: key, maxAge: Self.matchCacheTTL),
           let decoded = try? JSONDecoder().decode(TMDBResolvedMatch.self, from: cached) {
            return .hit(decoded)
        }
        if let cached = cacheStore.readJSON(forKey: key, maxAge: Self.negativeMatchCacheTTL),
           let negative = try? JSONDecoder().decode(TMDBSeasonMatchNegativeCacheEntry.self, from: cached),
           negative.missing {
            return .negative
        }
        return .missing
    }

    private func writeNegativeSeasonMatchCache(forKey key: String) {
        let entry = TMDBSeasonMatchNegativeCacheEntry(missing: true)
        if let data = try? JSONEncoder().encode(entry) {
            cacheStore.writeJSON(data, forKey: key)
        }
    }

    private func findTarget(media: AniListMedia, titles: [String], startYear: Int?) async -> TMDBSearchResult? {
        if let malId = media.idMal,
           let target = await findByMAL(malId: malId) {
            return target
        }
        return await searchShow(titles: titles, startYear: startYear, preferMovie: isMovieLike(media))
    }

    private func findByMAL(malId: Int) async -> TMDBSearchResult? {
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
                return TMDBSearchResult(
                    id: id,
                    mediaType: "tv",
                    title: tv["name"] as? String ?? tv["original_name"] as? String ?? "Unknown",
                    posterURL: (tv["poster_path"] as? String).flatMap { URL(string: "https://image.tmdb.org/t/p/w185\($0)") },
                    firstAirYear: yearFrom(tv["first_air_date"] as? String)
                )
            }
            if let movie = (root?["movie_results"] as? [[String: Any]])?.first(where: { isLikelyAnimeMovie($0) }),
               let id = movie["id"] as? Int {
                return TMDBSearchResult(
                    id: id,
                    mediaType: "movie",
                    title: movie["title"] as? String ?? movie["original_title"] as? String ?? "Unknown",
                    posterURL: (movie["poster_path"] as? String).flatMap { URL(string: "https://image.tmdb.org/t/p/w185\($0)") },
                    firstAirYear: yearFrom(movie["release_date"] as? String)
                )
            }
            return nil
        } catch {
            return nil
        }
    }

    private func searchShow(titles: [String], startYear: Int?, preferMovie: Bool) async -> TMDBSearchResult? {
        guard let apiKey else { return nil }
        let sanitizedTitles = titles
            .map(TitleSanitizer.sanitize)
            .filter { !$0.isEmpty }
        guard !sanitizedTitles.isEmpty else { return nil }

        let queries = Array(Set(sanitizedTitles.flatMap { TitleMatcher.buildQueries(from: $0) }))
        let normalizedTargets = sanitizedTitles
            .map(TitleMatcher.cleanTitle)
            .filter { !$0.isEmpty }
        guard !normalizedTargets.isEmpty else { return nil }

        var best: TMDBSearchResult?
        var bestScore = -1.0
        let mediaTypes = preferMovie ? ["movie", "tv"] : ["tv"]
        for query in queries {
            for mediaType in mediaTypes {
                var components = URLComponents(string: "https://api.themoviedb.org/3/search/\(mediaType)")!
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
                        if mediaType == "movie" && !isLikelyAnimeMovie(row) {
                            continue
                        }
                        guard let id = row["id"] as? Int else { continue }
                        let name = mediaType == "movie"
                            ? (row["title"] as? String ?? row["original_title"] as? String ?? "")
                            : (row["name"] as? String ?? row["original_name"] as? String ?? "")
                        let normalizedName = TitleMatcher.cleanTitle(name)
                        let titleScore = normalizedTargets
                            .map { TitleMatcher.diceCoefficient(normalizedName, $0) }
                            .max() ?? 0.0

                        let dateString = mediaType == "movie"
                            ? (row["release_date"] as? String)
                            : (row["first_air_date"] as? String)
                        let yearScore: Double
                        if let startYear, let year = yearFrom(dateString) {
                            yearScore = 1.0 - min(Double(abs(startYear - year)) / 3.0, 1.0)
                        } else {
                            yearScore = 0.5
                        }

                        let typeBias = mediaType == "movie" ? (preferMovie ? 1.0 : 0.7) : (preferMovie ? 0.7 : 1.0)
                        let score = (0.6 * titleScore) + (0.22 * yearScore) + (0.18 * typeBias)
                        if score > bestScore {
                            bestScore = score
                            best = TMDBSearchResult(
                                id: id,
                                mediaType: mediaType,
                                title: name,
                                posterURL: (row["poster_path"] as? String).flatMap { URL(string: "https://image.tmdb.org/t/p/w185\($0)") },
                                firstAirYear: yearFrom(dateString)
                            )
                        }
                    }
                } catch {
                    continue
                }
            }
        }
        return best
    }

    private func candidateTitles(for media: AniListMedia) async -> [String] {
        var titles = normalizedCandidateTitleSet(from: [media])

        if let aniListClient {
            var queue: [AniListMedia] = [media]
            var visited: Set<Int> = []
            var franchiseMedia: [AniListMedia] = []

            while !queue.isEmpty && visited.count < 20 {
                let current = queue.removeFirst()
                guard visited.insert(current.id).inserted else { continue }
                franchiseMedia.append(current)

                let relations = (try? await aniListClient.relationsGraph(mediaId: current.id)) ?? []
                for edge in relations where ["PREQUEL", "SEQUEL"].contains(edge.relationType.uppercased()) {
                    if !visited.contains(edge.media.id) {
                        queue.append(edge.media)
                    }
                }
            }

            titles.formUnion(normalizedCandidateTitleSet(from: franchiseMedia))
        }

        return Array(titles).sorted()
    }

    private func normalizedCandidateTitleSet(from mediaItems: [AniListMedia]) -> Set<String> {
        var titles: Set<String> = []
        for item in mediaItems {
            let rawTitles = [
                item.title.english,
                item.title.romaji,
                item.title.native,
                item.title.best
            ].compactMap { value -> String? in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                    return nil
                }
                return value
            }

            for title in rawTitles {
                titles.insert(title)
                let strippedSeason = TitleMatcher.stripSeasonMarkers(title)
                if !strippedSeason.isEmpty {
                    titles.insert(strippedSeason)
                }
                let strippedFinal = TitleMatcher.stripFinalSeasonMarkers(title)
                if !strippedFinal.isEmpty {
                    titles.insert(strippedFinal)
                }
                let strippedFinalSeason = TitleMatcher.stripSeasonMarkers(strippedFinal)
                if !strippedFinalSeason.isEmpty {
                    titles.insert(strippedFinalSeason)
                }
            }
        }
        return titles
    }

    private func fetchShowSummary(showId: Int, mediaType: String, apiKey: String) async -> TMDBShowSummary? {
        if mediaType == "movie" {
            guard let movie = await fetchMovieDetails(movieId: showId, apiKey: apiKey) else { return nil }
            return TMDBShowSummary(
                showId: showId,
                mediaType: "movie",
                title: movie.title,
                numberOfEpisodes: 1,
                seasons: [
                    TMDBSeasonInfo(seasonNumber: 1, episodeCount: 1, airDateString: movie.releaseDate, name: "Movie", isSpecial: false)
                ]
            )
        }
        guard let url = URL(string: "https://api.themoviedb.org/3/tv/\(showId)?api_key=\(apiKey)") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let title = root?["name"] as? String ?? root?["original_name"] as? String ?? ""
            let total = root?["number_of_episodes"] as? Int ?? 0
            let seasons = (root?["seasons"] as? [[String: Any]] ?? [])
                .compactMap { TMDBSeasonInfo(from: $0) }
                .filter { $0.seasonNumber > 0 }
                .sorted { $0.seasonNumber < $1.seasonNumber }
            return TMDBShowSummary(showId: showId, mediaType: "tv", title: title, numberOfEpisodes: total, seasons: seasons)
        } catch {
            return nil
        }
    }

    private func selectSeason(
        media: AniListMedia,
        show: TMDBShowSummary,
        preferredSeasonNumber: Int?,
        firstEpisodeNumber: Int?,
        expectedEpisodeCount: Int?,
        maxEpisodeNumber: Int?
    ) -> SelectedSeason? {
        let seasons = show.seasons
        guard !seasons.isEmpty else { return nil }

        let explicitSeasonMarker = TitleMatcher.extractSeasonMarkerNumber(from: media.title.best)
        let explicitPartMarker = TitleMatcher.extractPartMarkerNumber(from: media.title.best)
        let hasFinalSeasonMarker = TitleMatcher.hasFinalSeasonMarker(media.title.best)
        let targetDate = date(from: media.startDate)
        let targetYear = media.startDate?.year ?? media.seasonYear
        let rangeMatch = cumulativeRangeMatch(
            seasons: seasons,
            expectedEpisodeCount: expectedEpisodeCount ?? media.episodes ?? 0,
            firstEpisodeNumber: firstEpisodeNumber,
            maxEpisodeNumber: maxEpisodeNumber
        )
        let dateMatch = nearestSeasonByAirDate(seasons: seasons, targetDate: targetDate)
        let yearMatch = nearestSeasonByYear(seasons: seasons, targetYear: targetYear)
        let nameMatch = nearestSeasonByName(seasons: seasons, targetTitle: media.title.best)

        if let explicitSeasonMarker, explicitSeasonMarker > 0 {
            guard seasons.contains(where: { $0.seasonNumber == explicitSeasonMarker }) else {
                return nil
            }
            if hasHardRangeConflict(
                explicitSeasonMarker,
                rangeMatch: rangeMatch,
                firstEpisodeNumber: firstEpisodeNumber,
                expectedEpisodeCount: expectedEpisodeCount,
                maxEpisodeNumber: maxEpisodeNumber
            ) {
                return nil
            }
            
            // If we have a part marker > 1, don't assume offset 0 unless range match confirms it.
            // This allows the franchise mapping to take over and find the correct offset.
            if let explicitPartMarker, explicitPartMarker > 1, rangeMatch?.seasonNumber != explicitSeasonMarker {
                return selectPartOrCourSeason(
                    seasons: seasons,
                    rangeMatch: rangeMatch,
                    dateMatch: dateMatch,
                    yearMatch: yearMatch,
                    partMarker: explicitPartMarker,
                    explicitSeasonNumber: explicitSeasonMarker
                )
            }
            
            let offset = rangeMatch?.seasonNumber == explicitSeasonMarker ? (rangeMatch?.offset ?? 0) : 0
            return SelectedSeason(
                seasonNumber: explicitSeasonMarker,
                episodeOffset: offset,
                confidence: 0.98,
                reason: "explicit-season-marker"
            )
        }

        if hasFinalSeasonMarker {
            return selectFinalSeason(
                seasons: seasons,
                rangeMatch: rangeMatch,
                dateMatch: dateMatch,
                yearMatch: yearMatch,
                partMarker: explicitPartMarker
            )
        }

        if let nameMatch {
            return SelectedSeason(
                seasonNumber: nameMatch.seasonNumber,
                episodeOffset: 0,
                confidence: nameMatch.score,
                reason: "season-name-match"
            )
        }

        if let explicitPartMarker, explicitPartMarker > 0 {
            return selectPartOrCourSeason(
                seasons: seasons,
                rangeMatch: rangeMatch,
                dateMatch: dateMatch,
                yearMatch: yearMatch,
                partMarker: explicitPartMarker
            )
        }

        if let rangeMatch {
            return SelectedSeason(
                seasonNumber: rangeMatch.seasonNumber,
                episodeOffset: rangeMatch.offset,
                confidence: 0.9,
                reason: "episode-number-range"
            )
        }

        if let dateMatch {
            return SelectedSeason(
                seasonNumber: dateMatch.seasonNumber,
                episodeOffset: 0,
                confidence: dateMatch.score,
                reason: "first-air-date"
            )
        }

        if let yearMatch {
            return SelectedSeason(
                seasonNumber: yearMatch.seasonNumber,
                episodeOffset: 0,
                confidence: yearMatch.score,
                reason: "season-year"
            )
        }

        return SelectedSeason(
            seasonNumber: seasons[0].seasonNumber,
            episodeOffset: 0,
            confidence: 0.55,
            reason: "first-season-fallback"
        )
    }

    private func selectFinalSeason(
        seasons: [TMDBSeasonInfo],
        rangeMatch: SeasonRangeMatch?,
        dateMatch: (seasonNumber: Int, score: Double)?,
        yearMatch: (seasonNumber: Int, score: Double)?,
        partMarker: Int?
    ) -> SelectedSeason? {
        let mainSeasons = seasons.filter { !$0.isSpecial }
        let latestMainSeason = (mainSeasons.isEmpty ? seasons : mainSeasons)
            .max(by: { $0.seasonNumber < $1.seasonNumber })

        guard let latestMainSeason else { return nil }

        if let partMarker, partMarker > 0 {
            if let rangeMatch {
                if rangeMatch.seasonNumber == latestMainSeason.seasonNumber {
                    return SelectedSeason(
                        seasonNumber: latestMainSeason.seasonNumber,
                        episodeOffset: rangeMatch.offset,
                        confidence: 0.97,
                        reason: "final-season-part"
                    )
                }
            }

            // For higher parts, if no range match, we might be a later season or needing offset
            if partMarker > 1 {
                // Check if there is a season that specifically mentions this part in its name
                let partSearch = "Part \(partMarker)"
                if let namedMatch = seasons.first(where: { ($0.name ?? "").contains(partSearch) }) {
                     return SelectedSeason(
                        seasonNumber: namedMatch.seasonNumber,
                        episodeOffset: 0,
                        confidence: 0.92,
                        reason: "final-season-named-part"
                    )
                }
                return nil
            }

            if let dateMatch, dateMatch.seasonNumber == latestMainSeason.seasonNumber, dateMatch.score >= 0.78 {
                return SelectedSeason(
                    seasonNumber: latestMainSeason.seasonNumber,
                    episodeOffset: 0,
                    confidence: dateMatch.score,
                    reason: "final-season-part"
                )
            }

            if let yearMatch, yearMatch.seasonNumber == latestMainSeason.seasonNumber, yearMatch.score >= 0.82 {
                return SelectedSeason(
                    seasonNumber: latestMainSeason.seasonNumber,
                    episodeOffset: 0,
                    confidence: yearMatch.score,
                    reason: "final-season-part"
                )
            }

            return nil
        }

        return SelectedSeason(
            seasonNumber: latestMainSeason.seasonNumber,
            episodeOffset: 0,
            confidence: 0.9,
            reason: "final-season"
        )
    }

    private func selectPartOrCourSeason(
        seasons: [TMDBSeasonInfo],
        rangeMatch: SeasonRangeMatch?,
        dateMatch: (seasonNumber: Int, score: Double)?,
        yearMatch: (seasonNumber: Int, score: Double)?,
        partMarker: Int,
        explicitSeasonNumber: Int? = nil
    ) -> SelectedSeason? {
        if let explicitSeasonNumber {
            let season = seasons.first { $0.seasonNumber == explicitSeasonNumber }
            if let rangeMatch, rangeMatch.seasonNumber == explicitSeasonNumber {
                return SelectedSeason(
                    seasonNumber: explicitSeasonNumber,
                    episodeOffset: rangeMatch.offset,
                    confidence: 0.96,
                    reason: "part-cour-with-season-range"
                )
            }
            if let dateMatch, dateMatch.seasonNumber == explicitSeasonNumber {
                return SelectedSeason(
                    seasonNumber: explicitSeasonNumber,
                    episodeOffset: 0,
                    confidence: dateMatch.score,
                    reason: "part-cour-with-season-date"
                )
            }
            if let yearMatch, yearMatch.seasonNumber == explicitSeasonNumber {
                return SelectedSeason(
                    seasonNumber: explicitSeasonNumber,
                    episodeOffset: 0,
                    confidence: yearMatch.score,
                    reason: "part-cour-with-season-year"
                )
            }
            // If we have an explicit season but no range/date match, we might be a part of it.
            // Returning nil here allows the franchise logic to try fitting it.
            return nil
        }

        if seasons.count == 1, let onlySeason = seasons.first {
            // For split-cour in a single season, if no range match, we need franchise logic.
            if partMarker > 1 && rangeMatch == nil {
                return nil
            }
            return SelectedSeason(
                seasonNumber: onlySeason.seasonNumber,
                episodeOffset: rangeMatch?.offset ?? 0,
                confidence: 0.84,
                reason: "single-season-split-cour"
            )
        }

        if let rangeMatch {
            return SelectedSeason(
                seasonNumber: rangeMatch.seasonNumber,
                episodeOffset: rangeMatch.offset,
                confidence: 0.96,
                reason: "part-cour-episode-range"
            )
        }

        // If part > 1 and no range match, avoid offset 0.
        if partMarker > 1 {
            return nil
        }

        if let dateMatch, dateMatch.score >= 0.78 {
            return SelectedSeason(
                seasonNumber: dateMatch.seasonNumber,
                episodeOffset: 0,
                confidence: dateMatch.score,
                reason: "part-cour-first-air-date"
            )
        }

        if let yearMatch, yearMatch.score >= 0.82 {
            return SelectedSeason(
                seasonNumber: yearMatch.seasonNumber,
                episodeOffset: 0,
                confidence: yearMatch.score,
                reason: "part-cour-season-year"
            )
        }

        if partMarker == 1, let firstSeason = seasons.first {
            return SelectedSeason(
                seasonNumber: firstSeason.seasonNumber,
                episodeOffset: 0,
                confidence: 0.62,
                reason: "part-cour-first-season-fallback"
            )
        }

        return nil
    }

    private func hasHardRangeConflict(
        _ explicitSeasonNumber: Int,
        rangeMatch: SeasonRangeMatch?,
        firstEpisodeNumber: Int?,
        expectedEpisodeCount: Int?,
        maxEpisodeNumber: Int?
    ) -> Bool {
        guard let rangeMatch else { return false }
        guard rangeMatch.seasonNumber != explicitSeasonNumber else { return false }

        let firstNumber = firstEpisodeNumber ?? 1
        let lastNumber = maxEpisodeNumber ?? firstNumber
        let expected = expectedEpisodeCount ?? 0
        let looksGlobal = firstNumber > 1 || (expected > 0 && lastNumber >= expected + 5)
        return looksGlobal
    }

    private func cumulativeRangeMatch(
        seasons: [TMDBSeasonInfo],
        expectedEpisodeCount: Int,
        firstEpisodeNumber: Int?,
        maxEpisodeNumber: Int?
    ) -> SeasonRangeMatch? {
        let firstNumber = max(firstEpisodeNumber ?? 1, 1)
        let lastNumber = max(maxEpisodeNumber ?? firstNumber, firstNumber)
        let looksGlobal = (expectedEpisodeCount > 0 && lastNumber >= expectedEpisodeCount + 5) || firstNumber > 1
        guard looksGlobal else { return nil }

        var cursor = 1
        for season in seasons {
            let start = cursor
            let end = cursor + max(season.episodeCount - 1, 0)
            if firstNumber >= start && firstNumber <= end {
                return SeasonRangeMatch(
                    seasonNumber: season.seasonNumber,
                    offset: start - 1
                )
            }
            if lastNumber >= start && lastNumber <= end {
                return SeasonRangeMatch(
                    seasonNumber: season.seasonNumber,
                    offset: start - 1
                )
            }
            cursor = end + 1
        }
        return nil
    }

    private func nearestSeasonByAirDate(seasons: [TMDBSeasonInfo], targetDate: Date?) -> (seasonNumber: Int, score: Double)? {
        guard let targetDate else { return nil }
        let matches = seasons.compactMap { season -> (Int, Double)? in
            guard let airDate = dateFromSeason(season.airDateString) else { return nil }
            let days = abs(Int(airDate.timeIntervalSince(targetDate) / 86400))
            guard days <= 180 else { return nil }
            let score = max(0.6, 1.0 - (Double(days) / 180.0))
            return (season.seasonNumber, score)
        }
        return matches.max(by: { $0.1 < $1.1 }).map { ($0.0, $0.1) }
    }

    private func nearestSeasonByYear(seasons: [TMDBSeasonInfo], targetYear: Int?) -> (seasonNumber: Int, score: Double)? {
        guard let targetYear else { return nil }
        let matches = seasons.compactMap { season -> (Int, Double)? in
            guard let seasonYear = yearFrom(season.airDateString) else { return nil }
            let score = 1.0 - min(Double(abs(targetYear - seasonYear)) / 4.0, 0.45)
            return (season.seasonNumber, score)
        }
        return matches.max(by: { $0.1 < $1.1 }).map { ($0.0, $0.1) }
    }

    private func nearestSeasonByName(seasons: [TMDBSeasonInfo], targetTitle: String) -> (seasonNumber: Int, score: Double)? {
        let cleanedTarget = TitleMatcher.cleanTitle(targetTitle)
        guard !cleanedTarget.isEmpty else { return nil }
        
        let matches = seasons.compactMap { season -> (Int, Double)? in
            guard let name = season.name, !name.isEmpty else { return nil }
            let cleanedName = TitleMatcher.cleanTitle(name)
            guard !cleanedName.isEmpty else { return nil }
            
            let score = TitleMatcher.diceCoefficient(cleanedTarget, cleanedName)
            guard score >= 0.7 else { return nil }
            return (season.seasonNumber, score)
        }
        return matches.max(by: { $0.1 < $1.1 }).map { ($0.0, $0.1) }
    }

    private func date(from fuzzy: AniListFuzzyDate?) -> Date? {
        guard let fuzzy, let year = fuzzy.year else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = fuzzy.month ?? 1
        components.day = fuzzy.day ?? 1
        return Calendar(identifier: .gregorian).date(from: components)
    }

    private func yearFrom(_ dateString: String?) -> Int? {
        guard let dateString, let date = dateFormatter.date(from: dateString) else { return nil }
        return Calendar(identifier: .gregorian).component(.year, from: date)
    }

    private func dateFromSeason(_ airDate: String?) -> Date? {
        guard let airDate else { return nil }
        return dateFormatter.date(from: airDate)
    }

    private func isMovieLike(_ media: AniListMedia) -> Bool {
        let format = (media.format ?? "").uppercased()
        if format.contains("MOVIE") { return true }
        let title = media.title.best.lowercased()
        return title.contains("movie") || title.contains("film")
    }

    private func isLikelyAnimeMovie(_ row: [String: Any]) -> Bool {
        let genreIDs = row["genre_ids"] as? [Int] ?? []
        guard genreIDs.contains(16) else { return false }

        let language = ((row["original_language"] as? String) ?? "").lowercased()
        let allowedLanguages = Set(["ja", "ko", "zh", "zh-cn", "zh-tw"])
        if allowedLanguages.contains(language) {
            return true
        }

        let title = ((row["title"] as? String) ?? (row["original_title"] as? String) ?? "").lowercased()
        let overview = ((row["overview"] as? String) ?? "").lowercased()
        return title.contains("anime") || overview.contains("anime")
    }

    private func syntheticSeasonChoices(for media: AniListMedia, show: TMDBShowSummary) async -> [TMDBSeasonChoice]? {
        guard let aniListClient else { return nil }

        let relevantSeasons = show.seasons.filter { !$0.isSpecial && $0.episodeCount > 0 }
        guard !relevantSeasons.isEmpty else { return nil }

        let relations = (try? await aniListClient.relationsGraph(mediaId: media.id)) ?? []
        let segments = buildAniListSegments(current: media, relations: relations)
        guard segments.count >= 2 else { return nil }

        guard let mapped = mapSegments(segments, onto: relevantSeasons, show: show) else {
            return nil
        }

        let exactlyMatchesRawSeasons =
            mapped.count == relevantSeasons.count &&
            zip(mapped, relevantSeasons).allSatisfy { choice, season in
                choice.tmdbSeasonNumber == season.seasonNumber &&
                choice.episodeOffset == 0 &&
                choice.displayEpisodeCount == season.episodeCount
            }

        return exactlyMatchesRawSeasons ? nil : mapped
    }

    private func buildLunaFranchise(
        for media: AniListMedia,
        show: TMDBShowSummary
    ) async -> [AniListSegment]? {
        guard let aniListClient else { return nil }

        var discovered: [Int: AniListSegment] = [:]
        var queue: [AniListMedia] = [media]
        var visited: Set<Int> = []

        func insert(_ item: AniListMedia, relationType: String?) {
            let hasCount = (item.episodes ?? 0) > 0
            let markerHint =
                TitleMatcher.extractSeasonMarkerNumber(from: item.title.best) != nil ||
                TitleMatcher.extractPartMarkerNumber(from: item.title.best) != nil ||
                TitleMatcher.hasFinalSeasonMarker(item.title.best)
            guard hasCount || item.id == media.id || markerHint else { return }
            discovered[item.id] = AniListSegment(
                media: item,
                relationType: relationType,
                sortSeasonNumber: TitleMatcher.extractSeasonMarkerNumber(from: item.title.best),
                sortPartNumber: TitleMatcher.extractPartMarkerNumber(from: item.title.best),
                hasFinalSeasonMarker: TitleMatcher.hasFinalSeasonMarker(item.title.best),
                displayLabel: syntheticDisplayLabel(for: item, relativeTo: media, fallbackIndex: discovered.count + 1)
            )
        }

        insert(media, relationType: "CURRENT")

        while !queue.isEmpty && visited.count < 24 {
            let current = queue.removeFirst()
            guard visited.insert(current.id).inserted else { continue }

            let relationType: String? = current.id == media.id ? "CURRENT" : discovered[current.id]?.relationType
            insert(current, relationType: relationType)

            let relations = (try? await aniListClient.relationsGraph(mediaId: current.id)) ?? []
            for edge in relations {
                let relation = edge.relationType.uppercased()
                guard ["PREQUEL", "SEQUEL"].contains(relation) else { continue }
                insert(edge.media, relationType: relation)
                if !visited.contains(edge.media.id) {
                    queue.append(edge.media)
                }
            }
        }

        let tmdbEpisodeTotal = max(
            show.numberOfEpisodes,
            show.seasons.filter { !$0.isSpecial }.reduce(0) { $0 + $1.episodeCount }
        )
        let recovered = await recoverOrphanedFranchiseEntries(
            for: media,
            known: Array(discovered.values.map(\.media)),
            targetEpisodeTotal: tmdbEpisodeTotal
        )
        for item in recovered {
            insert(item, relationType: "ORPHAN")
        }

        let ordered = discovered.values.sorted(by: compareSegments)
        return ordered.isEmpty ? nil : ordered
    }

    private func recoverOrphanedFranchiseEntries(
        for media: AniListMedia,
        known: [AniListMedia],
        targetEpisodeTotal: Int
    ) async -> [AniListMedia] {
        guard let aniListClient else { return [] }

        let knownTotal = known.compactMap(\.episodes).reduce(0, +)
        guard targetEpisodeTotal > 0, knownTotal > 0, knownTotal + 2 < targetEpisodeTotal else {
            return []
        }

        var baseTitles = normalizedCandidateTitleSet(from: known + [media]).map {
            TitleMatcher.cleanTitle(TitleMatcher.stripSeasonMarkers(TitleMatcher.stripFinalSeasonMarkers($0)))
        }.filter { !$0.isEmpty }
        baseTitles = Array(Set(baseTitles))
        guard !baseTitles.isEmpty else { return [] }

        var seenIds = Set(known.map(\.id))
        var recovered: [AniListMedia] = []
        let currentYear = media.startDate?.year ?? media.seasonYear

        for query in baseTitles.prefix(4) {
            let results = (try? await aniListClient.searchAnime(query: query)) ?? []
            let ranked = results
                .filter { candidate in
                    let hasEpisodes = (candidate.episodes ?? 0) > 0
                    let hasMarker =
                        TitleMatcher.extractSeasonMarkerNumber(from: candidate.title.best) != nil ||
                        TitleMatcher.extractPartMarkerNumber(from: candidate.title.best) != nil ||
                        TitleMatcher.hasFinalSeasonMarker(candidate.title.best)
                    guard hasEpisodes || hasMarker else { return false }
                    guard !seenIds.contains(candidate.id) else { return false }
                    return true
                }
                .map { candidate -> (AniListMedia, Double) in
                    let normalizedCandidate = TitleMatcher.cleanTitle(
                        TitleMatcher.stripSeasonMarkers(
                            TitleMatcher.stripFinalSeasonMarkers(candidate.title.best)
                        )
                    )
                    let titleScore = baseTitles
                        .map { TitleMatcher.diceCoefficient(normalizedCandidate, $0) }
                        .max() ?? 0.0
                    let candidateYear = candidate.startDate?.year ?? candidate.seasonYear
                    let yearScore: Double
                    if let currentYear, let candidateYear {
                        yearScore = 1.0 - min(Double(abs(candidateYear - currentYear)) / 8.0, 1.0)
                    } else {
                        yearScore = 0.5
                    }
                    let sequelSignal = (
                        TitleMatcher.extractSeasonMarkerNumber(from: candidate.title.best) != nil ||
                        TitleMatcher.extractPartMarkerNumber(from: candidate.title.best) != nil ||
                        TitleMatcher.hasFinalSeasonMarker(candidate.title.best)
                    ) ? 1.0 : 0.45
                    let score = (0.62 * titleScore) + (0.2 * yearScore) + (0.18 * sequelSignal)
                    return (candidate, score)
                }
                .filter { $0.1 >= 0.72 }
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    return (lhs.0.startDate?.year ?? lhs.0.seasonYear ?? 0) < (rhs.0.startDate?.year ?? rhs.0.seasonYear ?? 0)
                }

            for (candidate, _) in ranked {
                guard seenIds.insert(candidate.id).inserted else { continue }
                recovered.append(candidate)
                let recoveredTotal = recovered.compactMap(\.episodes).reduce(0, +)
                if knownTotal + recoveredTotal >= targetEpisodeTotal {
                    return recovered
                }
            }
        }

        return recovered
    }

    private func mapFranchise(
        _ franchise: [AniListSegment],
        onto absoluteEpisodes: [AbsoluteTMDBEpisode],
        show: TMDBShowSummary
    ) -> [AniListTMDBSegment]? {
        guard !franchise.isEmpty, !absoluteEpisodes.isEmpty else { return nil }

        var mapped: [AniListTMDBSegment] = []
        var cursor = 0

        for (index, segment) in franchise.enumerated() {
            let episodeCount = inferredEpisodeCount(
                for: segment,
                index: index,
                franchise: franchise,
                cursor: cursor,
                totalEpisodes: absoluteEpisodes.count
            )
            guard episodeCount > 0 else { continue }

            let start = cursor
            let end = cursor + episodeCount - 1
            guard start < absoluteEpisodes.count else { break }
            guard end < absoluteEpisodes.count else { break }

            let startEpisode = absoluteEpisodes[start]
            let endEpisode = absoluteEpisodes[end]
            let reason = startEpisode.seasonNumber == endEpisode.seasonNumber
                ? "luna-absolute-season-aligned"
                : "luna-absolute-cross-season"

            mapped.append(
                AniListTMDBSegment(
                    mediaId: segment.media.id,
                    displayLabel: segment.displayLabel ?? "Season \(index + 1)",
                    episodeCount: episodeCount,
                    tmdbSeasonNumber: startEpisode.seasonNumber,
                    episodeOffset: max(0, startEpisode.episodeNumber - 1),
                    absoluteStart: start + 1,
                    absoluteEnd: end + 1,
                    posterSeasonNumber: startEpisode.seasonNumber,
                    reason: reason
                )
            )

            cursor += episodeCount
        }

        return mapped.isEmpty ? nil : mapped
    }

    private func fitCurrentNode(
        media: AniListMedia,
        franchise: [AniListSegment],
        onto absoluteEpisodes: [AbsoluteTMDBEpisode],
        show: TMDBShowSummary
    ) -> AniListTMDBSegment? {
        guard let currentIndex = franchise.firstIndex(where: { $0.media.id == media.id }) else { return nil }
        let current = franchise[currentIndex]
        let currentCount = inferredEpisodeCount(
            for: current,
            index: currentIndex,
            franchise: franchise,
            cursor: 0,
            totalEpisodes: absoluteEpisodes.count
        )
        guard currentCount > 0 else { return nil }

        let seasons = show.seasons.filter { !$0.isSpecial && $0.episodeCount > 0 }
        let explicitSeason = TitleMatcher.extractSeasonMarkerNumber(from: media.title.best)
        let explicitPart = TitleMatcher.extractPartMarkerNumber(from: media.title.best)
        let hasFinalSeason = TitleMatcher.hasFinalSeasonMarker(media.title.best)

        if let anchoredSeason = anchoredSeasonForCurrentNode(media: media, show: show, episodeCount: currentCount),
           let anchoredStart = startIndexForSeason(
                anchoredSeason.seasonNumber,
                in: absoluteEpisodes,
                offset: anchoredSeason.episodeOffset
           ),
           anchoredStart >= 0,
           anchoredStart + currentCount <= absoluteEpisodes.count,
           (explicitSeason != nil || explicitPart != nil || hasFinalSeason) {
            return buildCurrentSlice(
                segment: current,
                startIndex: anchoredStart,
                episodeCount: currentCount,
                absoluteEpisodes: absoluteEpisodes,
                fallbackIndex: currentIndex + 1,
                reason: anchoredSeason.reason
            )
        }

        let knownBefore = franchise.prefix(currentIndex).compactMap(\.media.episodes).filter { $0 > 0 }.reduce(0, +)
        let knownAfter = franchise.dropFirst(currentIndex + 1).compactMap(\.media.episodes).filter { $0 > 0 }.reduce(0, +)
        let minStart = knownBefore
        let maxStart = absoluteEpisodes.count - knownAfter - currentCount
        guard maxStart >= minStart, minStart >= 0 else { return nil }

        if minStart == maxStart {
            return buildCurrentSlice(
                segment: current,
                startIndex: minStart,
                episodeCount: currentCount,
                absoluteEpisodes: absoluteEpisodes,
                fallbackIndex: currentIndex + 1,
                reason: "current-node-neighbor-fit"
            )
        }

        if let explicitSeason, explicitSeason > 1, !seasons.contains(where: { $0.seasonNumber == explicitSeason }) {
            return nil
        }

        var candidates: [(start: Int, score: Double, reason: String)] = []

        if let explicitSeason,
           let start = startIndexForSeason(
                explicitSeason,
                in: absoluteEpisodes,
                offset: 0
           ),
           start >= minStart,
           start <= maxStart {
            candidates.append((start, 0.99, "current-node-explicit-season"))
        }

        if let anchoredSeason = anchoredSeasonForCurrentNode(media: media, show: show, episodeCount: currentCount),
           let start = startIndexForSeason(
                anchoredSeason.seasonNumber,
                in: absoluteEpisodes,
                offset: anchoredSeason.episodeOffset
           ),
           start >= minStart,
           start <= maxStart {
            candidates.append((start, anchoredSeason.confidence, anchoredSeason.reason))
        }

        if minStart == 0 {
            candidates.append((minStart, 0.74, "current-node-prefix-start"))
        }
        if maxStart == minStart {
            candidates.append((maxStart, 0.74, "current-node-fixed-range"))
        } else if currentIndex == franchise.count - 1 {
            candidates.append((maxStart, 0.76, "current-node-suffix-fit"))
        }

        let best = candidates
            .filter { candidate in
                candidate.start >= 0 && candidate.start + currentCount <= absoluteEpisodes.count
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.start < rhs.start
            }
            .first

        if let best {
            return buildCurrentSlice(
                segment: current,
                startIndex: best.start,
                episodeCount: currentCount,
                absoluteEpisodes: absoluteEpisodes,
                fallbackIndex: currentIndex + 1,
                reason: best.reason
            )
        }

        return nil
    }

    private func anchoredSeasonForCurrentNode(
        media: AniListMedia,
        show: TMDBShowSummary,
        episodeCount: Int
    ) -> SelectedSeason? {
        selectSeason(
            media: media,
            show: show,
            preferredSeasonNumber: TitleMatcher.extractSeasonNumber(from: media.title.best),
            firstEpisodeNumber: nil,
            expectedEpisodeCount: episodeCount,
            maxEpisodeNumber: episodeCount
        )
    }

    private func startIndexForSeason(
        _ seasonNumber: Int,
        in absoluteEpisodes: [AbsoluteTMDBEpisode],
        offset: Int
    ) -> Int? {
        guard let seasonStart = absoluteEpisodes.firstIndex(where: { $0.seasonNumber == seasonNumber }) else {
            return nil
        }
        return seasonStart + max(0, offset)
    }

    private func buildCurrentSlice(
        segment: AniListSegment,
        startIndex: Int,
        episodeCount: Int,
        absoluteEpisodes: [AbsoluteTMDBEpisode],
        fallbackIndex: Int,
        reason: String
    ) -> AniListTMDBSegment? {
        guard startIndex >= 0, startIndex < absoluteEpisodes.count else { return nil }
        let endIndex = startIndex + episodeCount - 1
        guard endIndex >= startIndex, endIndex < absoluteEpisodes.count else { return nil }

        let startEpisode = absoluteEpisodes[startIndex]
        return AniListTMDBSegment(
            mediaId: segment.media.id,
            displayLabel: segment.displayLabel ?? "Season \(fallbackIndex)",
            episodeCount: episodeCount,
            tmdbSeasonNumber: startEpisode.seasonNumber,
            episodeOffset: max(0, startEpisode.episodeNumber - 1),
            absoluteStart: startIndex + 1,
            absoluteEnd: endIndex + 1,
            posterSeasonNumber: startEpisode.seasonNumber,
            reason: reason
        )
    }

    private func inferredEpisodeCount(
        for segment: AniListSegment,
        index: Int,
        franchise: [AniListSegment],
        cursor: Int,
        totalEpisodes: Int
    ) -> Int {
        if let count = segment.media.episodes, count > 0 {
            return count
        }
        let remaining = max(0, totalEpisodes - cursor)
        guard remaining > 0 else { return 0 }
        let knownAfter = franchise.dropFirst(index + 1).compactMap(\.media.episodes).filter { $0 > 0 }.reduce(0, +)
        let inferred = max(remaining - knownAfter, 0)
        return inferred > 0 ? inferred : (segment.media.id == franchise.last?.media.id ? remaining : 0)
    }

    private func flattenAbsoluteEpisodes(show: TMDBShowSummary) async -> [AbsoluteTMDBEpisode] {
        if show.mediaType == "movie" {
            guard let apiKey, let movie = await fetchMovieDetails(movieId: show.showId, apiKey: apiKey) else { return [] }
            return [
                AbsoluteTMDBEpisode(
                    absoluteNumber: 1,
                    seasonNumber: 1,
                    episodeNumber: 1,
                    title: movie.title,
                    summary: movie.summary,
                    airDate: movie.releaseDate,
                    runtimeMinutes: movie.runtimeMinutes,
                    stillURL: movie.backdropURL ?? movie.posterURL,
                    rating: movie.rating
                )
            ]
        }
        let seasons = show.seasons.filter { !$0.isSpecial && $0.episodeCount > 0 }
        guard !seasons.isEmpty else { return [] }

        var flattened: [AbsoluteTMDBEpisode] = []
        var absoluteNumber = 1

        for season in seasons {
            guard let details = await fetchSeasonDetails(showId: show.showId, seasonNumber: season.seasonNumber) else {
                return []
            }
            for episode in details.episodes.sorted(by: { $0.number < $1.number }) {
                flattened.append(
                    AbsoluteTMDBEpisode(
                        absoluteNumber: absoluteNumber,
                        seasonNumber: season.seasonNumber,
                        episodeNumber: episode.number,
                        title: episode.title,
                        summary: episode.summary,
                        airDate: episode.airDate,
                        runtimeMinutes: episode.runtimeMinutes,
                        stillURL: episode.stillURL,
                        rating: episode.rating
                    )
                )
                absoluteNumber += 1
            }
        }

        return flattened
    }

    private func buildAniListSegments(current media: AniListMedia, relations: [AniListRelationEdge]) -> [AniListSegment] {
        var deduped: [Int: AniListSegment] = [:]

        func insert(_ item: AniListMedia, relationType: String?) {
            guard let episodeCount = item.episodes, episodeCount > 0 else { return }
            deduped[item.id] = AniListSegment(
                media: item,
                relationType: relationType,
                sortSeasonNumber: TitleMatcher.extractSeasonMarkerNumber(from: item.title.best),
                sortPartNumber: TitleMatcher.extractPartMarkerNumber(from: item.title.best),
                hasFinalSeasonMarker: TitleMatcher.hasFinalSeasonMarker(item.title.best),
                displayLabel: syntheticDisplayLabel(for: item, relativeTo: media, fallbackIndex: deduped.count + 1)
            )
        }

        insert(media, relationType: "CURRENT")
        for edge in relations {
            let relation = edge.relationType.uppercased()
            guard ["PREQUEL", "SEQUEL"].contains(relation) else { continue }
            insert(edge.media, relationType: relation)
        }

        return deduped.values.sorted(by: compareSegments)
    }

    private func compareSegments(_ lhs: AniListSegment, _ rhs: AniListSegment) -> Bool {
        if let leftDate = date(from: lhs.media.startDate), let rightDate = date(from: rhs.media.startDate), leftDate != rightDate {
            return leftDate < rightDate
        }
        if let leftYear = lhs.media.startDate?.year ?? lhs.media.seasonYear,
           let rightYear = rhs.media.startDate?.year ?? rhs.media.seasonYear,
           leftYear != rightYear {
            return leftYear < rightYear
        }
        if relationRank(lhs.relationType) != relationRank(rhs.relationType) {
            return relationRank(lhs.relationType) < relationRank(rhs.relationType)
        }
        if let leftSeason = lhs.sortSeasonNumber, let rightSeason = rhs.sortSeasonNumber, leftSeason != rightSeason {
            return leftSeason < rightSeason
        }
        if lhs.sortSeasonNumber != nil, rhs.sortSeasonNumber == nil {
            return false
        }
        if lhs.sortSeasonNumber == nil, rhs.sortSeasonNumber != nil {
            return true
        }
        if let leftPart = lhs.sortPartNumber, let rightPart = rhs.sortPartNumber, leftPart != rightPart {
            return leftPart < rightPart
        }
        return lhs.media.id < rhs.media.id
    }

    private func relationRank(_ relationType: String?) -> Int {
        switch relationType?.uppercased() {
        case "PREQUEL":
            return 0
        case "CURRENT":
            return 1
        case "SEQUEL":
            return 2
        default:
            return 3
        }
    }

    private func mapSegments(
        _ segments: [AniListSegment],
        onto seasons: [TMDBSeasonInfo],
        show: TMDBShowSummary
    ) -> [TMDBSeasonChoice]? {
        var mapped: [TMDBSeasonChoice] = []
        var seasonIndex = 0
        var offsetWithinSeason = 0

        for (index, segment) in segments.enumerated() {
            guard let episodeCount = segment.media.episodes, episodeCount > 0 else { return nil }

            while seasonIndex < seasons.count, offsetWithinSeason >= seasons[seasonIndex].episodeCount {
                seasonIndex += 1
                offsetWithinSeason = 0
            }

            guard seasonIndex < seasons.count else { return nil }
            let tmdbSeason = seasons[seasonIndex]
            let remaining = tmdbSeason.episodeCount - offsetWithinSeason
            guard remaining >= episodeCount else { return nil }

            let mappingReason = offsetWithinSeason == 0 && tmdbSeason.episodeCount == episodeCount
                ? "aniList-season-aligned"
                : "aniList-synthetic-split"

            mapped.append(
                TMDBSeasonChoice(
                    showId: show.showId,
                    mediaType: show.mediaType,
                    showTitle: show.title,
                    tmdbSeasonNumber: tmdbSeason.seasonNumber,
                    episodeOffset: offsetWithinSeason,
                    displayEpisodeCount: episodeCount,
                    displayLabel: segment.displayLabel ?? "Season \(index + 1)",
                    isSynthetic: true,
                    mappedAniListMediaId: segment.media.id,
                    mappingReason: mappingReason,
                    name: segment.displayLabel ?? "Season \(index + 1)",
                    airYear: segment.media.startDate?.year ?? segment.media.seasonYear
                )
            )

            offsetWithinSeason += episodeCount
            if offsetWithinSeason == tmdbSeason.episodeCount {
                seasonIndex += 1
                offsetWithinSeason = 0
            }
        }

        return mapped
    }

    private func syntheticDisplayLabel(for item: AniListMedia, relativeTo current: AniListMedia, fallbackIndex: Int) -> String {
        let title = item.title.best
        if TitleMatcher.hasFinalSeasonMarker(title) {
            if let partNumber = TitleMatcher.extractPartMarkerNumber(from: title) {
                return "Final Season Part \(partNumber)"
            }
            return "Final Season"
        }
        if let seasonNumber = TitleMatcher.extractSeasonMarkerNumber(from: title) {
            return "Season \(seasonNumber)"
        }
        if let courNumber = TitleMatcher.extractCourMarkerNumber(from: title) {
            return "Cour \(courNumber)"
        }
        if let partNumber = TitleMatcher.extractPartOnlyMarkerNumber(from: title) {
            return "Part \(partNumber)"
        }
        if item.id == current.id {
            return current.title.best
        }
        return "Season \(fallbackIndex)"
    }
}

private struct TMDBShowSummary {
    let showId: Int
    let mediaType: String
    let title: String
    let numberOfEpisodes: Int
    let seasons: [TMDBSeasonInfo]
}

private struct TMDBSeasonInfo {
    let seasonNumber: Int
    let episodeCount: Int
    let airDateString: String?
    let name: String?
    let isSpecial: Bool

    init(seasonNumber: Int, episodeCount: Int, airDateString: String?, name: String?, isSpecial: Bool) {
        self.seasonNumber = seasonNumber
        self.episodeCount = episodeCount
        self.airDateString = airDateString
        self.name = name
        self.isSpecial = isSpecial
    }

    init?(from dict: [String: Any]) {
        guard let seasonNumber = dict["season_number"] as? Int else { return nil }
        self.seasonNumber = seasonNumber
        self.episodeCount = dict["episode_count"] as? Int ?? 0
        self.airDateString = dict["air_date"] as? String
        self.name = dict["name"] as? String
        self.isSpecial = dict["season_type"] as? String == "specials"
    }
}

private struct SeasonRangeMatch {
    let seasonNumber: Int
    let offset: Int
}

private struct SelectedSeason {
    let seasonNumber: Int
    let episodeOffset: Int
    let confidence: Double
    let reason: String
}

private struct AniListSegment {
    let media: AniListMedia
    let relationType: String?
    let sortSeasonNumber: Int?
    let sortPartNumber: Int?
    let hasFinalSeasonMarker: Bool
    let displayLabel: String?
}
