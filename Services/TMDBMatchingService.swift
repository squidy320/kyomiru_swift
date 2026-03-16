import Foundation

struct TMDBSeasonMatch: Equatable, Codable {
    let showId: Int
    let seasonNumber: Int
    let episodeOffset: Int
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

final class TMDBMatchingService {
    private let session: URLSession
    private let cacheStore: CacheStore
    private let cacheManager: MetadataCacheManager
    private let apiKey: String?
    private let dateFormatter: DateFormatter

    init(cacheStore: CacheStore, session: URLSession = .custom, cacheManager: MetadataCacheManager = MetadataCacheManager()) {
        self.cacheStore = cacheStore
        self.session = session
        self.cacheManager = cacheManager
        self.apiKey = Bundle.main.object(forInfoDictionaryKey: "TMDB_API_KEY") as? String
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        self.dateFormatter = formatter
    }

    func matchShowAndSeason(
        media: AniListMedia,
        franchiseStartYear: Int? = nil,
        firstEpisodeNumber: Int? = nil
    ) async -> TMDBSeasonMatch? {
        guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else { return nil }
        let cacheKey = "tmdb:match:\(media.id)"
        if let cached = cacheManager.load(aniListId: media.id) {
            if let firstEpisodeNumber, firstEpisodeNumber > 1, cached.episodeOffset == 0 {
                AppLog.debug(.matching, "tmdb match cache bypass mediaId=\(media.id) reason=offset-zero firstEp=\(firstEpisodeNumber)")
            } else {
                return TMDBSeasonMatch(
                    showId: cached.showId,
                    seasonNumber: cached.seasonNumber,
                    episodeOffset: cached.episodeOffset
                )
            }
        }
        if let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 60 * 12),
           let decoded = try? JSONDecoder().decode(TMDBSeasonMatch.self, from: cached) {
            if let firstEpisodeNumber, firstEpisodeNumber > 1, decoded.episodeOffset == 0 {
                AppLog.debug(.matching, "tmdb match cache bypass mediaId=\(media.id) reason=offset-zero-cache firstEp=\(firstEpisodeNumber)")
            } else {
                return decoded
            }
        }

        let title = media.title.english ?? media.title.romaji ?? media.title.native ?? media.title.best
        let startYear = franchiseStartYear
            ?? media.startDate?.year
            ?? media.seasonYear
        guard let showId = await findShowId(title: title, startYear: startYear) else { return nil }
        let aniFirstEpisode = max(firstEpisodeNumber ?? 1, 1)
        guard let seasonMatch = await matchSeason(showId: showId, media: media, aniFirstEpisode: aniFirstEpisode) else { return nil }
        let match = TMDBSeasonMatch(
            showId: showId,
            seasonNumber: seasonMatch.seasonNumber,
            episodeOffset: seasonMatch.episodeOffset
        )
        if let seasonDetails = await fetchSeasonDetails(
            aniListId: media.id,
            showId: showId,
            seasonNumber: seasonMatch.seasonNumber
        ) {
            let cachedMeta = TMDBCachedMetadata(
                aniListId: media.id,
                showId: showId,
                seasonNumber: seasonMatch.seasonNumber,
                episodeOffset: seasonMatch.episodeOffset,
                cachedAt: Date(),
                seasonDetails: seasonDetails
            )
            cacheManager.save(cachedMeta)
        }
        if let data = try? JSONEncoder().encode(match) {
            cacheStore.writeJSON(data, forKey: cacheKey)
        }
        return match
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

    private func findShowId(title: String, startYear: Int?) async -> Int? {
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
                        yearScore = year == startYear ? 1.0 : 0.0
                    } else {
                        yearScore = 0.5
                    }

                    if let startYear, let year = yearFrom(firstAirDate),
                       abs(year - startYear) > 1, titleScore < 0.9 {
                        continue
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

    private func matchSeason(showId: Int, media: AniListMedia, aniFirstEpisode: Int) async -> TMDBSeasonMatch? {
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
            if seasons.isEmpty { return nil }

            let aniDate = date(from: media.startDate)
            if let aniDate {
                if let deepMatch = await deepEpisodeMatch(showId: showId, targetDate: aniDate) {
                    let offset = aniFirstEpisode - deepMatch.episodeNumber
                    return TMDBSeasonMatch(
                        showId: showId,
                        seasonNumber: deepMatch.seasonNumber,
                        episodeOffset: offset
                    )
                }

                let within14 = seasons.compactMap { season -> (TMDBSeasonInfo, Int)? in
                    guard let airDate = dateFromSeason(season.airDateString) else { return nil }
                    let days = abs(Int(airDate.timeIntervalSince(aniDate) / 86400))
                    return days <= 14 ? (season, days) : nil
                }
                if let best = within14.min(by: { $0.1 < $1.1 }) {
                    return TMDBSeasonMatch(showId: showId, seasonNumber: best.0.seasonNumber, episodeOffset: 0)
                }
            }

            if let episodes = media.episodes, episodes > 0 {
                let best = seasons.min { lhs, rhs in
                    abs(lhs.episodeCount - episodes) < abs(rhs.episodeCount - episodes)
                }
                if let best {
                    return TMDBSeasonMatch(showId: showId, seasonNumber: best.seasonNumber, episodeOffset: 0)
                }
            }
            if let first = seasons.first {
                return TMDBSeasonMatch(showId: showId, seasonNumber: first.seasonNumber, episodeOffset: 0)
            }
            return nil
        } catch {
            return nil
        }
    }

    private func date(from fuzzy: AniListFuzzyDate?) -> Date? {
        guard let fuzzy, let year = fuzzy.year else { return nil }
        let month = fuzzy.month ?? 1
        let day = fuzzy.day ?? 1
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return Calendar(identifier: .gregorian).date(from: comps)
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
                        let epNumber = episode["episode_number"] as? Int ?? 0
                        return (season.seasonNumber, max(epNumber, 1))
                    }
                }
            }
        } catch {
            return nil
        }
        return nil
    }
}

private struct TMDBSeasonInfo {
    let seasonNumber: Int
    let episodeCount: Int
    let airDateString: String?

    init?(from dict: [String: Any]) {
        guard let seasonNumber = dict["season_number"] as? Int else { return nil }
        self.seasonNumber = seasonNumber
        self.episodeCount = dict["episode_count"] as? Int ?? 0
        self.airDateString = dict["air_date"] as? String
    }
}
