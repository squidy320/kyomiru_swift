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

final class TMDBMatchingService {
    private static let matchCacheTTL: TimeInterval = 60 * 60 * 12
    private static let negativeMatchCacheTTL: TimeInterval = 60 * 30

    private let session: URLSession
    private let cacheStore: CacheStore
    private let cacheManager: MetadataCacheManager
    private let aniListClient: AniListClient?
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
        self.aniListClient = aniListClient
        let bundleKey = Bundle.main.object(forInfoDictionaryKey: "TMDB_API_KEY") as? String
        let defaultsKey = UserDefaults.standard.string(forKey: "TMDB_API_KEY")
        self.apiKey = (bundleKey?.isEmpty == false) ? bundleKey : defaultsKey
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        self.dateFormatter = formatter
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

        let cacheKey = "tmdb:match:v5:\(media.id):preferred:\(preferredSeasonNumber ?? 0):first:\(firstEpisodeNumber ?? 1):count:\(expectedEpisodeCount ?? 0):max:\(maxEpisodeNumber ?? 0)"
        if let cached = cacheManager.load(aniListId: media.id),
           isCachedMetadataUsable(
            cached,
            firstEpisodeNumber: firstEpisodeNumber,
            preferredSeasonNumber: preferredSeasonNumber,
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
        if let cachedResult = cachedSeasonMatch(forKey: cacheKey) {
            return cachedResult
        }

        return await matchRequests.value(for: cacheKey) { [self] in
            if let cached = cacheManager.load(aniListId: media.id),
               isCachedMetadataUsable(
                cached,
                firstEpisodeNumber: firstEpisodeNumber,
                preferredSeasonNumber: preferredSeasonNumber,
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
            if let cachedResult = cachedSeasonMatch(forKey: cacheKey) {
                return cachedResult
            }

            let title = media.title.english ?? media.title.romaji ?? media.title.native ?? media.title.best
            let startYear = franchiseStartYear ?? media.startDate?.year ?? media.seasonYear

            guard let showId = await findShowId(media: media, title: title, startYear: startYear),
                  let show = await fetchShowSummary(showId: showId, apiKey: apiKey) else {
                writeNegativeSeasonMatchCache(forKey: cacheKey)
                return nil
            }

            let desiredCount = expectedEpisodeCount ?? media.episodes ?? 0
            let relationContext = await buildRelationContext(
                media: media,
                tmdbTitle: show.title,
                tmdbTotalEpisodes: show.numberOfEpisodes,
                desiredCount: desiredCount
            )
            let aniFirstEpisode = max(firstEpisodeNumber ?? 1, 1)
            guard let resolved = await scoreSeasonMatch(
                media: media,
                show: show,
                relationContext: relationContext,
                aniFirstEpisode: aniFirstEpisode,
                preferredSeasonNumber: preferredSeasonNumber,
                expectedEpisodeCount: expectedEpisodeCount,
                maxEpisodeNumber: maxEpisodeNumber
            ) else {
                writeNegativeSeasonMatchCache(forKey: cacheKey)
                return nil
            }

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
            return resolved
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
        if let firstEpisodeNumber, firstEpisodeNumber > 1, cached.episodeOffset == 0 {
            return false
        }
        if let expectedEpisodeCount, expectedEpisodeCount > 0,
           let maxEpisodeNumber, maxEpisodeNumber >= expectedEpisodeCount + 5,
           cached.episodeOffset == 0 {
            return false
        }
        return true
    }

    private func cachedSeasonMatch(forKey key: String) -> TMDBResolvedMatch?? {
        if let cached = cacheStore.readJSON(forKey: key, maxAge: Self.matchCacheTTL),
           let decoded = try? JSONDecoder().decode(TMDBResolvedMatch.self, from: cached) {
            return decoded
        }
        if let cached = cacheStore.readJSON(forKey: key, maxAge: Self.negativeMatchCacheTTL),
           let negative = try? JSONDecoder().decode(TMDBSeasonMatchNegativeCacheEntry.self, from: cached),
           negative.missing {
            return nil
        }
        return nil
    }

    private func writeNegativeSeasonMatchCache(forKey key: String) {
        let entry = TMDBSeasonMatchNegativeCacheEntry(missing: true)
        if let data = try? JSONEncoder().encode(entry) {
            cacheStore.writeJSON(data, forKey: key)
        }
    }

    private func findShowId(media: AniListMedia, title: String, startYear: Int?) async -> Int? {
        if let malId = media.idMal,
           let showId = await findByMAL(malId: malId) {
            return showId
        }
        return await searchShow(title: title, startYear: startYear)
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

    private func searchShow(title: String, startYear: Int?) async -> Int? {
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
                    if let startYear, let year = yearFrom(firstAirDate) {
                        yearScore = 1.0 - min(Double(abs(startYear - year)) / 3.0, 1.0)
                    } else {
                        yearScore = 0.5
                    }

                    if let startYear, let year = yearFrom(firstAirDate),
                       abs(year - startYear) > 2, titleScore < 0.9 {
                        continue
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
            return TMDBShowSummary(showId: showId, title: title, numberOfEpisodes: total, seasons: seasons)
        } catch {
            return nil
        }
    }

    private func scoreSeasonMatch(
        media: AniListMedia,
        show: TMDBShowSummary,
        relationContext: RelationContext?,
        aniFirstEpisode: Int,
        preferredSeasonNumber: Int?,
        expectedEpisodeCount: Int?,
        maxEpisodeNumber: Int?
    ) async -> TMDBResolvedMatch? {
        let seasons = show.seasons
        guard !seasons.isEmpty else { return nil }

        let intent = TitleIntent(title: media.title.best)
        let desiredCount = expectedEpisodeCount ?? media.episodes ?? 0
        let targetYear = media.startDate?.year ?? media.seasonYear
        let normalizedTitle = TitleMatcher.cleanTitle(TitleMatcher.stripSeasonMarkers(media.title.best))
        let relationSeason = relationContext?.seasonIndex
        let rangeMatch = cumulativeRangeMatch(
            seasons: seasons,
            expectedEpisodeCount: desiredCount,
            maxEpisodeNumber: maxEpisodeNumber,
            firstEpisodeNumber: aniFirstEpisode
        )
        let aniDate = date(from: media.startDate)
        let deepMatch = aniDate == nil ? nil : await deepEpisodeMatch(showId: show.showId, targetDate: aniDate!)
        let airDateMatch = nearestSeasonByAirDate(seasons: seasons, targetDate: aniDate)

        let ranked = seasons.map { season -> RankedSeason in
            let yearScore = scoreSeasonYear(season, targetYear: targetYear)
            let episodeScore = scoreEpisodeCount(season, expectedEpisodeCount: desiredCount)
            let titleScore = scoreSeasonTitle(season, normalizedTargetTitle: normalizedTitle)
            let relationScore = scoreRelationMatch(season, relationSeason: relationSeason)
            let rangeScore = season.seasonNumber == rangeMatch?.seasonNumber ? 1.0 : 0.0
            let airDateScore = season.seasonNumber == airDateMatch?.seasonNumber ? airDateMatch?.score ?? 0.0 : 0.0
            let deepDateScore = season.seasonNumber == deepMatch?.seasonNumber ? 1.0 : 0.0
            let markerBonus = scoreTitleIntent(intent, season: season, preferredSeasonNumber: preferredSeasonNumber)

            let hardMismatch = desiredCount > 0
                && episodeScore < 0.25
                && relationScore == 0
                && rangeScore == 0
                && deepDateScore == 0

            let weighted = (0.24 * yearScore)
                + (0.20 * episodeScore)
                + (0.10 * titleScore)
                + (0.20 * relationScore)
                + (0.16 * rangeScore)
                + (0.05 * airDateScore)
                + (0.05 * deepDateScore)
                + markerBonus

            var confidence = (0.26 * yearScore)
                + (0.22 * episodeScore)
                + (0.16 * relationScore)
                + (0.16 * rangeScore)
                + (0.08 * titleScore)
                + (0.06 * airDateScore)
                + (0.06 * deepDateScore)
            if markerBonus > 0 {
                confidence += min(markerBonus * 0.25, 0.08)
            }
            if hardMismatch {
                confidence -= 0.22
            }
            confidence = min(max(confidence, 0.0), 0.99)

            let reason: String
            if season.seasonNumber == deepMatch?.seasonNumber {
                reason = "deep-episode-date"
            } else if season.seasonNumber == relationSeason {
                reason = "relation-chain"
            } else if season.seasonNumber == rangeMatch?.seasonNumber {
                reason = "global-range"
            } else if season.seasonNumber == airDateMatch?.seasonNumber {
                reason = "season-air-date"
            } else if intent.trueSeasonMarker != nil && !intent.hasSplitMarker && season.seasonNumber == intent.trueSeasonMarker {
                reason = "preferred-season-marker"
            } else if markerBonus > 0.18 {
                reason = "split-title-hint"
            } else {
                reason = "season-score"
            }

            AppLog.debug(
                .matching,
                "tmdb season score mediaId=\(media.id) season=\(season.seasonNumber) year=\(String(format: "%.2f", yearScore)) ep=\(String(format: "%.2f", episodeScore)) relation=\(String(format: "%.2f", relationScore)) range=\(String(format: "%.2f", rangeScore)) air=\(String(format: "%.2f", airDateScore)) deep=\(String(format: "%.2f", deepDateScore)) title=\(String(format: "%.2f", titleScore)) marker=\(String(format: "%.2f", markerBonus)) confidence=\(String(format: "%.2f", confidence))"
            )

            return RankedSeason(
                season: season,
                score: weighted,
                confidence: confidence,
                reason: reason,
                hardMismatch: hardMismatch
            )
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.season.seasonNumber < rhs.season.seasonNumber
        }

        guard let best = ranked.first else { return nil }
        let secondScore = ranked.dropFirst().first?.score ?? 0.0
        let scoreMargin = best.score - secondScore
        let hasHardEvidence = best.reason == "deep-episode-date"
            || best.reason == "relation-chain"
            || best.reason == "global-range"
            || best.reason == "season-air-date"
            || best.reason == "preferred-season-marker"

        let accepted = !best.hardMismatch && (
            best.confidence >= 0.74
            || (hasHardEvidence && best.confidence >= 0.60)
            || (scoreMargin >= 0.18 && best.confidence >= 0.58)
        )

        AppLog.debug(
            .matching,
            "tmdb resolved match mediaId=\(media.id) season=\(best.season.seasonNumber) confidence=\(String(format: "%.2f", best.confidence)) margin=\(String(format: "%.2f", scoreMargin)) accepted=\(accepted) reason=\(best.reason)"
        )

        guard accepted else { return nil }

        let episodeOffset: Int
        if let deepMatch, deepMatch.seasonNumber == best.season.seasonNumber {
            episodeOffset = aniFirstEpisode - deepMatch.episodeNumber
        } else {
            episodeOffset = 0
        }

        return TMDBResolvedMatch(
            showId: show.showId,
            seasonNumber: best.season.seasonNumber,
            episodeOffset: episodeOffset,
            confidence: best.confidence,
            reason: best.reason
        )
    }

    private func scoreSeasonYear(_ season: TMDBSeasonInfo, targetYear: Int?) -> Double {
        if let targetYear, let seasonYear = yearFrom(season.airDateString) {
            return 1.0 - min(Double(abs(targetYear - seasonYear)) / 3.0, 1.0)
        }
        return 0.5
    }

    private func scoreEpisodeCount(_ season: TMDBSeasonInfo, expectedEpisodeCount: Int) -> Double {
        guard expectedEpisodeCount > 0 else { return 0.5 }
        let delta = abs(season.episodeCount - expectedEpisodeCount)
        return 1.0 - min(Double(delta) / Double(max(expectedEpisodeCount, 1)), 1.0)
    }

    private func scoreSeasonTitle(_ season: TMDBSeasonInfo, normalizedTargetTitle: String) -> Double {
        let seasonTitle = TitleMatcher.cleanTitle(TitleMatcher.stripSeasonMarkers(season.name ?? ""))
        guard !seasonTitle.isEmpty else { return 0.5 }
        return TitleMatcher.diceCoefficient(seasonTitle, normalizedTargetTitle)
    }

    private func scoreRelationMatch(_ season: TMDBSeasonInfo, relationSeason: Int?) -> Double {
        guard let relationSeason else { return 0.0 }
        let delta = abs(season.seasonNumber - relationSeason)
        switch delta {
        case 0: return 1.0
        case 1: return 0.4
        default: return 0.0
        }
    }

    private func scoreTitleIntent(
        _ intent: TitleIntent,
        season: TMDBSeasonInfo,
        preferredSeasonNumber: Int?
    ) -> Double {
        var score = 0.0
        let name = (season.name ?? "").lowercased()

        if let preferredSeasonNumber, preferredSeasonNumber > 0 {
            if season.seasonNumber == preferredSeasonNumber {
                score += intent.hasSplitMarker ? 0.14 : 0.28
            } else if !intent.hasSplitMarker {
                score -= 0.10
            }
        }

        if intent.wantsFinal, name.contains("final") {
            score += 0.18
        }
        if intent.wantsPart, name.contains("part") {
            score += 0.10
        }
        if intent.wantsCour, name.contains("cour") {
            score += 0.10
        }
        if let partMarker = intent.partMarker, partMarker > 1 {
            if name.contains("part \(partMarker)") || name.contains("cour \(partMarker)") {
                score += 0.16
            } else if name.contains("part") || name.contains("cour") {
                score -= 0.05
            }
        }

        return score
    }

    private func cumulativeRangeMatch(
        seasons: [TMDBSeasonInfo],
        expectedEpisodeCount: Int,
        maxEpisodeNumber: Int?,
        firstEpisodeNumber: Int
    ) -> (seasonNumber: Int, start: Int, end: Int)? {
        let maxEpisode = maxEpisodeNumber ?? firstEpisodeNumber
        let looksGlobal = (expectedEpisodeCount > 0 && maxEpisode >= expectedEpisodeCount + 5) || firstEpisodeNumber > 1
        guard looksGlobal else { return nil }

        var cursor = 1
        for season in seasons.sorted(by: { $0.seasonNumber < $1.seasonNumber }) {
            let start = cursor
            let end = cursor + max(season.episodeCount - 1, 0)
            if maxEpisode >= start && maxEpisode <= end {
                return (season.seasonNumber, start, end)
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
            guard days <= 45 else { return nil }
            let score = max(0.0, 1.0 - (Double(days) / 45.0))
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

    private func deepEpisodeMatch(showId: Int, targetDate: Date) async -> (seasonNumber: Int, episodeNumber: Int)? {
        guard let apiKey else { return nil }
        guard let url = URL(string: "https://api.themoviedb.org/3/tv/\(showId)?api_key=\(apiKey)") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let seasons = (root?["seasons"] as? [[String: Any]] ?? [])
                .compactMap { TMDBSeasonInfo(from: $0) }
                .filter { $0.seasonNumber > 0 }
            for season in seasons {
                guard let seasonURL = URL(string: "https://api.themoviedb.org/3/tv/\(showId)/season/\(season.seasonNumber)?api_key=\(apiKey)") else {
                    continue
                }
                let (seasonData, seasonResponse) = try await session.data(from: seasonURL)
                guard let seasonHttp = seasonResponse as? HTTPURLResponse, (200..<300).contains(seasonHttp.statusCode) else {
                    continue
                }
                let seasonRoot = try JSONSerialization.jsonObject(with: seasonData) as? [String: Any]
                let episodes = seasonRoot?["episodes"] as? [[String: Any]] ?? []
                for episode in episodes {
                    guard let airDateString = episode["air_date"] as? String,
                          let airDate = dateFormatter.date(from: airDateString) else {
                        continue
                    }
                    let days = abs(Int(airDate.timeIntervalSince(targetDate) / 86400))
                    if days <= 7 {
                        let episodeNumber = max(episode["episode_number"] as? Int ?? 0, 1)
                        return (season.seasonNumber, episodeNumber)
                    }
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private func buildRelationContext(
        media: AniListMedia,
        tmdbTitle: String,
        tmdbTotalEpisodes: Int,
        desiredCount: Int
    ) async -> RelationContext? {
        guard let aniListClient else { return nil }
        let base = await resolveAniListBaseMedia(
            media: media,
            tmdbTitle: tmdbTitle,
            tmdbTotalEpisodes: tmdbTotalEpisodes,
            desiredCount: desiredCount,
            aniListClient: aniListClient
        )
        let chain = await buildRelationsChain(root: base, aniListClient: aniListClient)
        guard !chain.isEmpty else { return nil }
        let recovered = await recoverOrphansIfNeeded(
            chain: chain,
            base: base,
            tmdbTotalEpisodes: tmdbTotalEpisodes,
            aniListClient: aniListClient
        )
        let ordered = orderRelationChain(recovered)
        let index = relationSeasonIndex(chain: ordered, target: media)
        AppLog.debug(.matching, "relations chain built base=\(base.id) count=\(ordered.count) index=\(index ?? 0)")
        return RelationContext(base: base, chain: ordered, seasonIndex: index)
    }

    private func resolveAniListBaseMedia(
        media: AniListMedia,
        tmdbTitle: String,
        tmdbTotalEpisodes: Int,
        desiredCount: Int,
        aniListClient: AniListClient
    ) async -> AniListMedia {
        var candidates: [AniListMedia] = [media]
        for query in TitleMatcher.buildQueries(from: tmdbTitle) {
            if let results = try? await aniListClient.searchAnime(query: query) {
                candidates.append(contentsOf: results)
            }
        }
        let deduped = Dictionary(grouping: candidates, by: \.id).compactMap { $0.value.first }
        let best = pickBestAniListCandidate(
            candidates: deduped,
            tmdbTitle: tmdbTitle,
            tmdbTotalEpisodes: tmdbTotalEpisodes,
            desiredCount: desiredCount,
            baseYear: media.seasonYear
        )
        return await applyOvaCorrectionIfNeeded(
            base: best,
            desiredCount: desiredCount,
            tmdbTotalEpisodes: tmdbTotalEpisodes,
            aniListClient: aniListClient
        )
    }

    private func pickBestAniListCandidate(
        candidates: [AniListMedia],
        tmdbTitle: String,
        tmdbTotalEpisodes: Int,
        desiredCount: Int,
        baseYear: Int?
    ) -> AniListMedia {
        let targetTitle = TitleMatcher.cleanTitle(tmdbTitle)
        var best = candidates.first
        var bestScore = -Double.infinity
        for candidate in candidates {
            let titleScore = TitleMatcher.diceCoefficient(
                TitleMatcher.cleanTitle(candidate.title.best),
                targetTitle
            )
            let episodeTarget = tmdbTotalEpisodes > 0 ? tmdbTotalEpisodes : desiredCount
            let epScore: Double
            if episodeTarget > 0, let episodes = candidate.episodes, episodes > 0 {
                let delta = abs(episodes - episodeTarget)
                epScore = 1.0 - min(Double(delta) / Double(max(episodeTarget, 1)), 1.0)
            } else {
                epScore = 0.5
            }
            let yearScore: Double
            if let baseYear, let candidateYear = candidate.startDate?.year ?? candidate.seasonYear {
                yearScore = 1.0 - min(Double(abs(candidateYear - baseYear)) / 3.0, 1.0)
            } else {
                yearScore = 0.5
            }
            let formatScore: Double
            if let format = candidate.format {
                formatScore = ["TV", "ONA", "TV_SHORT"].contains(format) ? 1.0 : 0.2
            } else {
                formatScore = 0.4
            }
            let score = (0.52 * titleScore) + (0.24 * epScore) + (0.16 * yearScore) + (0.08 * formatScore)
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best ?? candidates.first!
    }

    private func applyOvaCorrectionIfNeeded(
        base: AniListMedia,
        desiredCount: Int,
        tmdbTotalEpisodes: Int,
        aniListClient: AniListClient
    ) async -> AniListMedia {
        let allowedFormats: Set<String> = ["TV", "ONA", "TV_SHORT"]
        let episodeTarget = tmdbTotalEpisodes > 0 ? tmdbTotalEpisodes : desiredCount
        let baseEpisodes = base.episodes ?? 0
        let looksLikeOva = (base.format.map { !allowedFormats.contains($0) } ?? false)
            || (episodeTarget > 0 && baseEpisodes > 0 && baseEpisodes < max(2, episodeTarget / 2))
        guard looksLikeOva else { return base }
        guard let edges = try? await aniListClient.relationsGraph(mediaId: base.id) else { return base }
        let candidates = edges
            .filter { ["PARENT", "SOURCE", "PREQUEL"].contains($0.relationType) }
            .map(\.media)
            .filter { media in
                guard let format = media.format else { return false }
                return allowedFormats.contains(format)
            }
        let corrected = candidates.max { lhs, rhs in
            (lhs.episodes ?? 0) < (rhs.episodes ?? 0)
        }
        return corrected ?? base
    }

    private func buildRelationsChain(root: AniListMedia, aniListClient: AniListClient) async -> [AniListMedia] {
        let allowedFormats: Set<String> = ["TV", "ONA", "TV_SHORT"]
        let allowedRelations: Set<String> = ["SEQUEL", "PREQUEL", "SEASON"]
        var visited: Set<Int> = [root.id]
        var queue: [(AniListMedia, Int)] = [(root, 0)]
        var collected: [AniListMedia] = [root]
        let maxDepth = 2
        let maxNodes = 25

        while !queue.isEmpty && collected.count < maxNodes {
            let (current, depth) = queue.removeFirst()
            if depth >= maxDepth { continue }
            guard let edges = try? await aniListClient.relationsGraph(mediaId: current.id) else { continue }
            for edge in edges where allowedRelations.contains(edge.relationType) {
                let media = edge.media
                if visited.contains(media.id) { continue }
                visited.insert(media.id)
                if let format = media.format, allowedFormats.contains(format) {
                    collected.append(media)
                    queue.append((media, depth + 1))
                }
            }
        }
        return collected
    }

    private func recoverOrphansIfNeeded(
        chain: [AniListMedia],
        base: AniListMedia,
        tmdbTotalEpisodes: Int,
        aniListClient: AniListClient
    ) async -> [AniListMedia] {
        guard tmdbTotalEpisodes > 0 else { return chain }
        let totalEpisodes = chain.reduce(0) { $0 + ($1.episodes ?? 0) }
        guard totalEpisodes < Int(Double(tmdbTotalEpisodes) * 0.7) else { return chain }

        var visited = Set(chain.map(\.id))
        var recovered = chain
        for query in TitleMatcher.buildQueries(from: base.title.best) {
            if let results = try? await aniListClient.searchAnime(query: query) {
                for candidate in results {
                    if visited.contains(candidate.id) { continue }
                    guard let format = candidate.format, ["TV", "ONA", "TV_SHORT"].contains(format) else { continue }
                    let titleScore = TitleMatcher.diceCoefficient(
                        TitleMatcher.cleanTitle(candidate.title.best),
                        TitleMatcher.cleanTitle(base.title.best)
                    )
                    let baseYear = base.startDate?.year ?? base.seasonYear
                    let candidateYear = candidate.startDate?.year ?? candidate.seasonYear
                    let yearDelta = (baseYear != nil && candidateYear != nil) ? abs(baseYear! - candidateYear!) : 0
                    if titleScore < 0.55 && yearDelta > 4 { continue }
                    visited.insert(candidate.id)
                    recovered.append(candidate)
                }
            }
        }
        return recovered
    }

    private func orderRelationChain(_ chain: [AniListMedia]) -> [AniListMedia] {
        chain.sorted { lhs, rhs in
            let leftDate = sortDate(for: lhs)
            let rightDate = sortDate(for: rhs)
            if leftDate != rightDate { return leftDate < rightDate }
            return lhs.title.best < rhs.title.best
        }
    }

    private func sortDate(for media: AniListMedia) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = media.startDate?.year ?? media.seasonYear ?? 9999
        components.month = media.startDate?.month ?? 1
        components.day = media.startDate?.day ?? 1
        return components.date ?? Date.distantFuture
    }

    private func relationSeasonIndex(chain: [AniListMedia], target: AniListMedia) -> Int? {
        if let exact = chain.firstIndex(where: { $0.id == target.id }) {
            return exact + 1
        }

        var best: (index: Int, score: Double)?
        let targetTitle = TitleMatcher.cleanTitle(target.title.best)
        for (idx, item) in chain.enumerated() {
            let titleScore = TitleMatcher.diceCoefficient(
                TitleMatcher.cleanTitle(item.title.best),
                targetTitle
            )
            let targetDate = sortDate(for: target)
            let itemDate = sortDate(for: item)
            let dateScore = targetDate == .distantFuture || itemDate == .distantFuture
                ? 0.0
                : max(0.0, 1.0 - min(abs(itemDate.timeIntervalSince(targetDate)) / Double(86400 * 365 * 3), 1.0))
            let score = (0.75 * titleScore) + (0.25 * dateScore)
            if score > (best?.score ?? 0.0) {
                best = (idx, score)
            }
        }
        if let best, best.score >= 0.72 {
            return best.index + 1
        }
        return nil
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

    init?(from dict: [String: Any]) {
        guard let seasonNumber = dict["season_number"] as? Int else { return nil }
        self.seasonNumber = seasonNumber
        self.episodeCount = dict["episode_count"] as? Int ?? 0
        self.airDateString = dict["air_date"] as? String
        self.name = dict["name"] as? String
    }
}

private struct RelationContext {
    let base: AniListMedia
    let chain: [AniListMedia]
    let seasonIndex: Int?
}

private struct RankedSeason {
    let season: TMDBSeasonInfo
    let score: Double
    let confidence: Double
    let reason: String
    let hardMismatch: Bool
}

private struct TitleIntent {
    let trueSeasonMarker: Int?
    let partMarker: Int?
    let wantsFinal: Bool
    let wantsPart: Bool
    let wantsCour: Bool

    var hasSplitMarker: Bool {
        partMarker != nil || wantsPart || wantsCour || wantsFinal
    }

    init(title: String) {
        let lower = title.lowercased()
        self.trueSeasonMarker = TitleMatcher.extractSeasonMarkerNumber(from: title)
        self.partMarker = TitleMatcher.extractPartMarkerNumber(from: title)
        self.wantsFinal = lower.contains("final")
        self.wantsPart = lower.contains("part")
        self.wantsCour = lower.contains("cour")
    }
}
