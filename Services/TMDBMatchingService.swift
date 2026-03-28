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
    let seasonNumber: Int
    let episodeOffset: Int
}

struct TMDBResolvedMatch: Equatable, Codable {
    let showId: Int
    let seasonNumber: Int
    let episodeOffset: Int
    let confidence: Double
    let reason: String
}

struct TMDBSeasonDetails: Equatable, Codable {
    struct Episode: Equatable, Codable {
        let number: Int
        let stillURL: URL?
        let rating: Double?
    }

    let posterURL: URL?
    let episodes: [Episode]
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
    private static let requestLimiter = TMDBMatchRequestLimiter(maxConcurrent: 3)

    private let session: URLSession
    private let cacheStore: CacheStore
    private let cacheManager: MetadataCacheManager
    private let apiKey: String?
    private let dateFormatter: DateFormatter
    private let matchRequests = TMDBMatchTaskCoalescer<String, TMDBResolvedMatch?>()
    private let seasonDetailRequests = TMDBMatchTaskCoalescer<String, TMDBSeasonDetails?>()

    init(
        cacheStore: CacheStore,
        session: URLSession = .custom,
        cacheManager: MetadataCacheManager = MetadataCacheManager(),
        aniListClient: AniListClient? = nil
    ) {
        self.cacheStore = cacheStore
        self.session = session
        self.cacheManager = cacheManager
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
        "tmdb:match:v8:\(mediaId):preferred:\(preferredSeasonNumber ?? 0):first:\(firstEpisodeNumber ?? 1):count:\(expectedEpisodeCount ?? 0):max:\(maxEpisodeNumber ?? 0)"
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

                let titles = candidateTitles(for: media)
                let startYear = franchiseStartYear ?? media.startDate?.year ?? media.seasonYear
                guard let showId = await findShowId(media: media, titles: titles, startYear: startYear),
                      let show = await fetchShowSummary(showId: showId, apiKey: apiKey),
                      let selection = selectSeason(
                            media: media,
                            show: show,
                            preferredSeasonNumber: preferredSeason,
                            firstEpisodeNumber: firstEpisodeNumber,
                            expectedEpisodeCount: expectedEpisodeCount,
                            maxEpisodeNumber: maxEpisodeNumber
                      ) else {
                    writeNegativeSeasonMatchCache(forKey: cacheKey)
                    return nil
                }

                let resolved = TMDBResolvedMatch(
                    showId: show.showId,
                    seasonNumber: selection.seasonNumber,
                    episodeOffset: selection.episodeOffset,
                    confidence: selection.confidence,
                    reason: selection.reason
                )

                if let seasonDetails = await fetchSeasonDetails(
                    aniListId: media.id,
                    showId: resolved.showId,
                    seasonNumber: resolved.seasonNumber
                ) {
                    cacheManager.save(
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
                    cacheStore.writeJSON(data, forKey: cacheKey)
                }

                AppLog.debug(
                    .matching,
                    "tmdb resolved match mediaId=\(media.id) showId=\(resolved.showId) season=\(resolved.seasonNumber) offset=\(resolved.episodeOffset) reason=\(resolved.reason)"
                )
                return resolved
            }
        }
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
                    let still = row["still_path"] as? String
                    let rating = row["vote_average"] as? Double
                    guard number > 0 else { return nil }
                    return TMDBSeasonDetails.Episode(
                        number: number,
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

    private func findShowId(media: AniListMedia, titles: [String], startYear: Int?) async -> Int? {
        if let malId = media.idMal,
           let showId = await findByMAL(malId: malId) {
            return showId
        }
        return await searchShow(titles: titles, startYear: startYear)
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
            return (root?["tv_results"] as? [[String: Any]])?.first?["id"] as? Int
        } catch {
            return nil
        }
    }

    private func searchShow(titles: [String], startYear: Int?) async -> Int? {
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
                    let normalizedName = TitleMatcher.cleanTitle(name)
                    let titleScore = normalizedTargets
                        .map { TitleMatcher.diceCoefficient(normalizedName, $0) }
                        .max() ?? 0.0

                    let firstAirDate = row["first_air_date"] as? String
                    let yearScore: Double
                    if let startYear, let year = yearFrom(firstAirDate) {
                        yearScore = 1.0 - min(Double(abs(startYear - year)) / 3.0, 1.0)
                    } else {
                        yearScore = 0.5
                    }

                    let score = (0.72 * titleScore) + (0.28 * yearScore)
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

    private func candidateTitles(for media: AniListMedia) -> [String] {
        var titles = [
            media.title.english,
            media.title.romaji,
            media.title.native,
            media.title.best
        ].compactMap { value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }
        titles.append(contentsOf: titles.map(TitleMatcher.stripSeasonMarkers))
        titles.append(contentsOf: titles.map(TitleMatcher.stripFinalSeasonMarkers))
        return Array(Set(titles)).sorted()
    }

    private func fetchShowSummary(showId: Int, apiKey: String) async -> TMDBShowSummary? {
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
            return TMDBShowSummary(showId: showId, title: title, numberOfEpisodes: total, seasons: seasons)
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
                if rangeMatch.seasonNumber != latestMainSeason.seasonNumber {
                    return nil
                }
                return SelectedSeason(
                    seasonNumber: latestMainSeason.seasonNumber,
                    episodeOffset: rangeMatch.offset,
                    confidence: 0.97,
                    reason: "final-season-part"
                )
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
        partMarker: Int
    ) -> SelectedSeason? {
        if seasons.count == 1, let onlySeason = seasons.first {
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
}

private struct TMDBShowSummary {
    let showId: Int
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
