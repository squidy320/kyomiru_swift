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

struct TMDBMetadata: Equatable, Codable {
    let tmdbId: Int
    let title: String
    let posterURL: URL?
    let backdropURL: URL?
    let logoURL: URL?
}

private struct TMDBMetadataNegativeCacheEntry: Codable {
    let missing: Bool
}

final class MetadataService {
    private static let metadataCacheTTL: TimeInterval = 60 * 60 * 24
    private static let negativeMetadataCacheTTL: TimeInterval = 60 * 30
    private let session: URLSession
    private let cacheStore: CacheStore
    private let apiKey: String?
    private let imageBase = "https://image.tmdb.org/t/p/original"
    private let metadataRequests = TMDBTaskCoalescer<Int, TMDBMetadata?>()
    private let tmdbMatcher: TMDBMatchingService

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

    func fetchTMDBMetadata(for media: AniListMedia) async -> TMDBMetadata? {
        let cacheKey = "tmdb:media:v2:\(media.id)"
        if let cachedResult = cachedMetadata(forKey: cacheKey) {
            return cachedResult
        }

        return await metadataRequests.value(for: media.id) { [self] in
            if let cachedResult = cachedMetadata(forKey: cacheKey) {
                return cachedResult
            }

            guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else {
                AppLog.error(.network, "tmdb api key missing")
                return nil
            }

            guard let details = await fetchSeasonAwareTMDBMetadata(for: media, apiKey: apiKey) else {
                writeNegativeMetadataCache(forKey: cacheKey)
                return nil
            }
            if let data = try? JSONEncoder().encode(details) {
                cacheStore.writeJSON(data, forKey: cacheKey)
            }
            return details
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

    func logoURL(for media: AniListMedia) async -> URL? {
        let meta = await fetchTMDBMetadata(for: media)
        return meta?.logoURL
    }

    func manualMatch(local: MediaItem, remoteId: String) async -> Bool {
        AppLog.debug(.matching, "manual match local=\(local.title) remote=\(remoteId)")
        try? await Task.sleep(nanoseconds: 200_000_000)
        return true
    }

    private func fetchSeasonAwareTMDBMetadata(for media: AniListMedia, apiKey: String) async -> TMDBMetadata? {
        let franchiseStartYear = media.startDate?.year ?? media.seasonYear
        let preferredSeasonNumber = TitleMatcher.extractSeasonMarkerNumber(from: media.title.best)
        guard let match = await tmdbMatcher.resolveShowAndSeason(
            media: media,
            franchiseStartYear: franchiseStartYear,
            firstEpisodeNumber: nil,
            preferredSeasonNumber: preferredSeasonNumber
        ) else {
            AppLog.debug(.matching, "tmdb metadata unresolved mediaId=\(media.id)")
            return nil
        }

        guard let details = await fetchTMDBDetails(showId: match.showId, apiKey: apiKey) else {
            return nil
        }
        let seasonPosterURL = await tmdbMatcher.fetchSeasonDetails(
            aniListId: media.id,
            showId: match.showId,
            seasonNumber: match.seasonNumber
        )?.posterURL
        return TMDBMetadata(
            tmdbId: details.tmdbId,
            title: details.title,
            posterURL: seasonPosterURL ?? details.posterURL,
            backdropURL: details.backdropURL,
            logoURL: details.logoURL
        )
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

    private func fetchTMDBDetails(showId: Int, apiKey: String) async -> TMDBMetadata? {
        guard let url = URL(string: "https://api.themoviedb.org/3/tv/\(showId)?api_key=\(apiKey)") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let title = root?["name"] as? String ?? root?["original_name"] as? String ?? "Unknown"
            let posterPath = root?["poster_path"] as? String
            let backdropPath = root?["backdrop_path"] as? String
            let posterURL = posterPath.flatMap { URL(string: "\(imageBase)\($0)") }
            let backdropURL = backdropPath.flatMap { URL(string: "\(imageBase)\($0)") }
            let logoURL = await fetchBestLogo(showId: showId, apiKey: apiKey)
            return TMDBMetadata(
                tmdbId: showId,
                title: title,
                posterURL: posterURL,
                backdropURL: backdropURL,
                logoURL: logoURL
            )
        } catch {
            return nil
        }
    }

    private func fetchBestLogo(showId: Int, apiKey: String) async -> URL? {
        guard let url = URL(string: "https://api.themoviedb.org/3/tv/\(showId)/images?api_key=\(apiKey)") else {
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

    private func yearFrom(_ dateString: String?) -> Int? {
        guard let dateString, dateString.count >= 4 else { return nil }
        return Int(dateString.prefix(4))
    }

    private func cachedMetadata(forKey key: String) -> TMDBMetadata?? {
        if let cached = cacheStore.readJSON(forKey: key, maxAge: Self.metadataCacheTTL),
           let decoded = try? JSONDecoder().decode(TMDBMetadata.self, from: cached) {
            return decoded
        }
        if let cached = cacheStore.readJSON(forKey: key, maxAge: Self.negativeMetadataCacheTTL),
           let negative = try? JSONDecoder().decode(TMDBMetadataNegativeCacheEntry.self, from: cached),
           negative.missing {
            return nil
        }
        return nil
    }

    private func writeNegativeMetadataCache(forKey key: String) {
        let entry = TMDBMetadataNegativeCacheEntry(missing: true)
        if let data = try? JSONEncoder().encode(entry) {
            cacheStore.writeJSON(data, forKey: key)
        }
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

        var targetSeason = seasonNumber
        var episodeOffset = 0
        if let match = await tmdbMatcher.matchShowAndSeason(
            media: media,
            franchiseStartYear: media.startDate?.year ?? media.seasonYear,
            firstEpisodeNumber: firstEpisodeNumber
        ) {
            targetSeason = match.seasonNumber
            episodeOffset = match.episodeOffset
        }

        let cacheKey = "tmdb:ratings:\(media.id):season:\(targetSeason):offset:\(episodeOffset)"
        if let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 60 * 12),
           let decoded = try? JSONDecoder().decode([Int: Double].self, from: cached) {
            return decoded
        }

        guard let tvId = await resolveTMDBShowId(media: media, apiKey: apiKey) else {
            return [:]
        }

        guard let url = URL(string: "https://api.themoviedb.org/3/tv/\(tvId)/season/\(targetSeason)?api_key=\(apiKey)") else {
            return [:]
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return [:]
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rows = root?["episodes"] as? [[String: Any]] ?? []
            var map: [Int: Double] = [:]
            for row in rows {
                let number = row["episode_number"] as? Int ?? 0
                let vote = row["vote_average"] as? Double ?? 0
                if number > 0 {
                    map[number] = vote
                }
            }
            if episodeOffset != 0 {
                map = applyEpisodeOffset(map, offset: episodeOffset)
            }
            if let data = try? JSONEncoder().encode(map) {
                cacheStore.writeJSON(data, forKey: cacheKey)
            }
            return map
        } catch {
            return [:]
        }
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
    }

    private let session: URLSession
    private let cacheStore: CacheStore
    private let provider: Provider
    private let aniListClient: AniListClient
    private let tmdbMatcher: TMDBMatchingService
    private let tmdbKey: String?
    private let cacheManager: MetadataCacheManager

    init(
        cacheStore: CacheStore,
        aniListClient: AniListClient,
        provider: Provider = .kitsu,
        session: URLSession = .custom,
        tmdbMatcher: TMDBMatchingService? = nil
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
    }

    func cachedEpisodes(for media: AniListMedia, episodes: [SoraEpisode]) -> [Int: EpisodeMetadata]? {
        switch provider {
        case .kitsu:
            let cacheKey = "episode-meta:kitsu:\(media.id)"
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

            var seasonNumber: Int?
            var episodeOffset: Int = 0
            if let cachedMeta = cacheManager.load(aniListId: media.id) {
                seasonNumber = cachedMeta.seasonNumber
                episodeOffset = cachedMeta.episodeOffset
            } else if let cachedMatch = cacheStore.readJSON(forKey: "tmdb:match:v2:\(media.id)"),
                      let decoded = try? JSONDecoder().decode(TMDBResolvedMatch.self, from: cachedMatch) {
                seasonNumber = decoded.seasonNumber
                episodeOffset = decoded.episodeOffset
            }

            guard let seasonNumber else { return nil }
            let offsetKey = episodeOffset != 0 ? ":offset:\(episodeOffset)" : ""
            let cacheKey = "episode-meta:tmdb:\(media.id):season:\(seasonNumber):count:\(desiredCount)\(maxKey)\(offsetKey)"
            if let cached = cacheStore.readJSON(forKey: cacheKey),
               let decoded = try? JSONDecoder().decode([Int: EpisodeMetadata].self, from: cached) {
                return decoded
            }
            return nil
        }
    }

    func fetchEpisodes(for media: AniListMedia, episodes: [SoraEpisode]) async -> [Int: EpisodeMetadata] {
        let mapped: [Int: EpisodeMetadata]
        switch provider {
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
        case .tmdb:
            let desiredCount = episodes.isEmpty ? (media.episodes ?? 0) : episodes.count
            let maxEpisodeNumber = episodes.map(\.number).max() ?? 0
            let preferredSeason = TitleMatcher.extractSeasonMarkerNumber(from: media.title.best)
            let firstEpisodeNumber = episodes.map(\.number).min()
            let (primary, seasonNumber, episodeOffset, accepted, rejectReason) = await fetchFromTMDB(
                media: media,
                preferredSeason: preferredSeason,
                desiredCount: desiredCount,
                maxEpisodeNumber: maxEpisodeNumber,
                firstEpisodeNumber: firstEpisodeNumber
            )
            let globalNumbering = maxEpisodeNumber >= desiredCount + 5 && maxEpisodeNumber > 0
            let maxKey = globalNumbering ? ":max:\(maxEpisodeNumber)" : ""
            let offsetKey = episodeOffset != 0 ? ":offset:\(episodeOffset)" : ""
            let cacheKey = "episode-meta:tmdb:\(media.id):season:\(seasonNumber):count:\(desiredCount)\(maxKey)\(offsetKey)"
            if accepted, let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 60 * 12),
               let decoded = try? JSONDecoder().decode([Int: EpisodeMetadata].self, from: cached) {
                return decoded
            }
            let aniListFallback = await fetchFromAniListStreaming(media: media)
            if accepted, !primary.isEmpty {
                mapped = mergeEpisodeMetadata(primary: primary, fallback: aniListFallback)
                if let data = try? JSONEncoder().encode(mapped) {
                    cacheStore.writeJSON(data, forKey: cacheKey)
                }
            } else {
                if let reason = rejectReason {
                    AppLog.debug(.matching, "tmdb season rejected mediaId=\(media.id) reason=\(reason)")
                }
                mapped = aniListFallback.isEmpty ? await fetchFromKitsu(media: media) : aniListFallback
            }
        }
        return mapped
    }

    private func mergeEpisodeMetadata(
        primary: [Int: EpisodeMetadata],
        fallback: [Int: EpisodeMetadata]
    ) -> [Int: EpisodeMetadata] {
        guard !fallback.isEmpty else { return primary }
        var result = primary
        for (number, fallbackMeta) in fallback {
            if let current = result[number] {
                let needsTitle = isGenericEpisodeTitle(current.title)
                let needsThumb = current.thumbnailURL == nil
                if needsTitle || needsThumb {
                    let merged = EpisodeMetadata(
                        number: number,
                        title: needsTitle ? fallbackMeta.title : current.title,
                        summary: current.summary,
                        airDate: current.airDate,
                        runtimeMinutes: current.runtimeMinutes,
                        thumbnailURL: needsThumb ? fallbackMeta.thumbnailURL : current.thumbnailURL
                    )
                    result[number] = merged
                }
            } else {
                result[number] = fallbackMeta
            }
        }
        return result
    }

    private func isGenericEpisodeTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.lowercased().hasPrefix("episode ")
    }

    private func fetchFromKitsu(media: AniListMedia) async -> [Int: EpisodeMetadata] {
        let title = media.title.english ?? media.title.romaji ?? media.title.native ?? media.title.best
        let animeId = await resolveKitsuAnimeId(malId: media.idMal, title: title)
        guard let animeId else { return [:] }
        return await fetchKitsuEpisodes(animeId: animeId)
    }

    private func fetchFromAniListStreaming(media: AniListMedia) async -> [Int: EpisodeMetadata] {
        let cacheKey = "episode-meta:anilist:\(media.id)"
        if let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 60 * 6),
           let decoded = try? JSONDecoder().decode([Int: EpisodeMetadata].self, from: cached) {
            return decoded
        }
        guard let episodes = try? await aniListClient.streamingEpisodes(mediaId: media.id) else {
            return [:]
        }
        var result: [Int: EpisodeMetadata] = [:]
        for episode in episodes {
            guard let number = episode.episodeNumber, number > 0 else { continue }
            let meta = EpisodeMetadata(
                number: number,
                title: episode.title,
                summary: nil,
                airDate: nil,
                runtimeMinutes: nil,
                thumbnailURL: episode.thumbnailURL
            )
            result[number] = meta
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
    ) async -> ([Int: EpisodeMetadata], Int, Int, Bool, String?) {
        guard let tmdbKey, !tmdbKey.isEmpty, tmdbKey != "CHANGE_ME" else {
            return ([:], preferredSeason ?? 1, 0, false, "missing-key")
        }
        let title = media.title.english ?? media.title.romaji ?? media.title.native ?? media.title.best
        let relationContext = await buildRelationContext(
            media: media,
            tmdbTitle: title,
            tmdbTotalEpisodes: desiredCount,
            desiredCount: desiredCount
        )
        let franchiseStartYear = relationContext?.chain.compactMap(\.seasonYear).min()
            ?? media.startDate?.year
            ?? media.seasonYear

        if let match = await tmdbMatcher.matchShowAndSeason(
            media: media,
            franchiseStartYear: franchiseStartYear,
            firstEpisodeNumber: firstEpisodeNumber
        ) {
            let data = await fetchTMDBSeason(showId: match.showId, seasonNumber: match.seasonNumber)
            let mapped = match.episodeOffset == 0 ? data : applyEpisodeOffset(data, offset: match.episodeOffset)
            return (mapped, match.seasonNumber, match.episodeOffset, !mapped.isEmpty, mapped.isEmpty ? "empty-season" : nil)
        }

        guard let showId = await resolveTMDBShowId(media: media, title: title) else {
            return ([:], preferredSeason ?? 1, 0, false, "show-id-missing")
        }
        guard let showDetails = await fetchTMDBShowDetails(showId: showId) else {
            return ([:], preferredSeason ?? 1, 0, false, "show-details-missing")
        }

        let relationSeason = relationContext?.seasonIndex
        let selection = selectTMDBSeason(
            showDetails: showDetails,
            media: media,
            preferredSeason: preferredSeason,
            desiredCount: desiredCount,
            maxEpisodeNumber: maxEpisodeNumber,
            relationSeason: relationSeason
        )
        guard selection.accepted else {
            return ([:], selection.seasonNumber, 0, false, selection.rejectReason)
        }
        let data = await fetchTMDBSeason(showId: showId, seasonNumber: selection.seasonNumber)
        return (data, selection.seasonNumber, 0, !data.isEmpty, data.isEmpty ? "empty-season" : nil)
    }

    private func resolveTMDBShowId(media: AniListMedia, title: String) async -> Int? {
        if let malId = media.idMal,
           let byMal = await findByMAL(malId: malId) {
            return byMal
        }
        return await searchTMDB(title: title)
    }

    private func findByMAL(malId: Int) async -> Int? {
        guard let tmdbKey else { return nil }
        var components = URLComponents(string: "https://api.themoviedb.org/3/find/\(malId)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: tmdbKey),
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

    private func searchTMDB(title: String) async -> Int? {
        guard let tmdbKey else { return nil }
        let sanitized = TitleSanitizer.sanitize(title)
        let queries = TitleMatcher.buildQueries(from: sanitized)
        let normalizedTarget = TitleMatcher.cleanTitle(sanitized)
        var bestId: Int?
        var bestScore = 0.0
        for query in queries {
            var components = URLComponents(string: "https://api.themoviedb.org/3/search/tv")!
            components.queryItems = [
                URLQueryItem(name: "api_key", value: tmdbKey),
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
                    let score = TitleMatcher.diceCoefficient(
                        TitleMatcher.cleanTitle(name),
                        normalizedTarget
                    )
                    if score > bestScore {
                        bestScore = score
                        bestId = id
                    }
                }
            } catch {
                continue
            }
        }
        return bestId
    }

    private func selectTMDBSeason(
        showDetails: TMDBShowDetails,
        media: AniListMedia,
        preferredSeason: Int?,
        desiredCount: Int,
        maxEpisodeNumber: Int,
        relationSeason: Int?
    ) -> SeasonSelectionResult {
        var candidates = showDetails.seasons.filter { $0.seasonNumber > 0 }
        if candidates.isEmpty {
            return SeasonSelectionResult(
                seasonNumber: relationSeason ?? preferredSeason ?? 1,
                accepted: false,
                rejectReason: "no-seasons"
            )
        }

        let title = media.title.best
        let titleClean = TitleMatcher.cleanTitle(title)
        let preferred = preferredSeason
        let targetYear = media.seasonYear
        let desired = desiredCount
        let maxEpisode = maxEpisodeNumber
        let globalNumbering = maxEpisode >= desired + 5 && maxEpisode > 0
        let titleLower = title.lowercased()
        let wantsFinal = titleLower.contains("final")
        let wantsPart = titleLower.contains("part")
        let wantsCour = titleLower.contains("cour")

        let normalizedTitle = TitleMatcher.cleanTitle(title)
        let isTunedTitle = normalizedTitle.contains("attack on titan")
            || normalizedTitle.contains("demon slayer")
            || normalizedTitle.contains("fire force")
            || normalizedTitle.contains("fruits basket")

        var rangeMatchSeason: Int?
        var ranges: [(season: Int, start: Int, end: Int)] = []
        if globalNumbering {
            var cursor = 1
            for season in candidates.sorted(by: { $0.seasonNumber < $1.seasonNumber }) {
                let start = cursor
                let end = cursor + max(season.episodeCount, 0) - 1
                ranges.append((season: season.seasonNumber, start: start, end: end))
                if maxEpisode >= start && maxEpisode <= end {
                    rangeMatchSeason = season.seasonNumber
                }
                cursor = end + 1
            }
            let rangesText = ranges
                .map { "S\($0.season)=\($0.start)-\($0.end)" }
                .joined(separator: ",")
            AppLog.debug(
                .network,
                "tmdb season ranges mediaId=\(media.id) maxEp=\(maxEpisode) desired=\(desired) ranges=[\(rangesText)] match=\(rangeMatchSeason ?? 0)"
            )
        }

        AppLog.debug(
            .network,
            "tmdb season global-numbering mediaId=\(media.id) maxEp=\(maxEpisode) desired=\(desired) detected=\(globalNumbering)"
        )

        var relationAligned = true
        if let relationSeason {
            let aligned = candidates.filter { $0.seasonNumber == relationSeason }
            if aligned.isEmpty {
                relationAligned = false
            } else {
                candidates = aligned
            }
        }

        var best: (season: SeasonInfo, score: Double, confidence: Double, rejectReason: String?)?
        for season in candidates {
            let countMismatch: Bool
            if desired > 0 {
                let delta = Double(abs(season.episodeCount - desired))
                let ratio = delta / Double(max(desired, 1))
                countMismatch = ratio > 0.4
            } else {
                countMismatch = false
            }
            let epScore: Double
            if desired > 0 {
                let delta = abs(season.episodeCount - desired)
                epScore = 1.0 - min(Double(delta) / Double(max(desired, 1)), 1.0)
            } else {
                epScore = 0.5
            }

            let yearScore: Double
            if let targetYear, let airYear = season.airYear {
                let delta = abs(airYear - targetYear)
                yearScore = 1.0 - min(Double(delta) / 3.0, 1.0)
            } else {
                yearScore = 0.5
            }

            let nameClean = TitleMatcher.cleanTitle(season.name ?? "")
            let titleScore = TitleMatcher.diceCoefficient(nameClean, titleClean)

            var markerScore = 0.0
            if let preferred, season.seasonNumber == preferred {
                markerScore += 0.8
            } else if preferred != nil {
                markerScore -= 0.18
            }
            let seasonLower = (season.name ?? "").lowercased()
            if wantsFinal, seasonLower.contains("final") { markerScore += 0.2 }
            if wantsPart, seasonLower.contains("part") { markerScore += 0.2 }
            if wantsCour, seasonLower.contains("cour") { markerScore += 0.2 }
            if let rangeMatchSeason, rangeMatchSeason == season.seasonNumber {
                markerScore += 0.6
            }
            if let relationSeason, relationSeason == season.seasonNumber {
                markerScore += 1.2
            }

            let titleWeight = isTunedTitle ? 0.25 : 0.35
            let yearWeight = isTunedTitle ? 0.3 : 0.2
            let epWeight = 0.25
            let relationWeight = 0.1
            let rangeWeight = 0.1

            let relationScore = relationSeason == season.seasonNumber ? 1.0 : 0.0
            let rangeScore = rangeMatchSeason == season.seasonNumber ? 1.0 : 0.0
            var confidence = (titleWeight * titleScore)
                + (epWeight * epScore)
                + (yearWeight * yearScore)
                + (relationWeight * relationScore)
                + (rangeWeight * rangeScore)
            confidence = min(max(confidence, 0.0), 1.0)

            let score = (0.45 * epScore) + (0.25 * yearScore) + (0.2 * titleScore) + markerScore
            AppLog.debug(
                .network,
                "tmdb season score mediaId=\(media.id) season=\(season.seasonNumber) ep=\(season.episodeCount) year=\(season.airYear ?? 0) epScore=\(String(format: "%.2f", epScore)) yearScore=\(String(format: "%.2f", yearScore)) titleScore=\(String(format: "%.2f", titleScore)) marker=\(String(format: "%.2f", markerScore)) total=\(String(format: "%.2f", score))"
            )
            let rejectReason: String?
            if countMismatch {
                rejectReason = "count-mismatch"
            } else {
                rejectReason = nil
            }
            if best == nil || score > best!.score {
                best = (season, score, confidence, rejectReason)
            }
        }

        let chosen = best?.season.seasonNumber ?? relationSeason ?? preferredSeason ?? 1
        let confidence = best?.confidence ?? 0.0
        let strictThreshold = 0.72
        let overrideThreshold = 0.85
        let hasHardReject = best?.rejectReason != nil
        let accepted: Bool
        let rejectReason: String?
        let confidenceText = String(format: "%.2f", confidence)
        if !relationAligned {
            if confidence >= overrideThreshold && !hasHardReject {
                accepted = true
                rejectReason = nil
                AppLog.debug(.matching, "tmdb season override accept mediaId=\(media.id) confidence=\(confidenceText) relationAligned=false")
            } else {
                accepted = false
                rejectReason = "relation-mismatch"
                AppLog.debug(.matching, "tmdb season override reject mediaId=\(media.id) confidence=\(confidenceText) relationAligned=false")
            }
        } else {
            accepted = confidence >= strictThreshold && !hasHardReject
            rejectReason = accepted ? nil : (best?.rejectReason ?? "low-confidence")
        }
        AppLog.debug(
            .network,
            "tmdb season select mediaId=\(media.id) chosen=\(chosen) preferred=\(preferredSeason ?? 0) relation=\(relationSeason ?? 0) desired=\(desiredCount) confidence=\(String(format: "%.2f", confidence)) accepted=\(accepted)"
        )
        return SeasonSelectionResult(
            seasonNumber: chosen,
            accepted: accepted,
            rejectReason: rejectReason
        )
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

    private func fetchTMDBShowDetails(showId: Int) async -> TMDBShowDetails? {
        guard let tmdbKey else { return nil }
        guard let url = URL(string: "https://api.themoviedb.org/3/tv/\(showId)?api_key=\(tmdbKey)") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let seasons = (root?["seasons"] as? [[String: Any]] ?? [])
                .compactMap { SeasonInfo(from: $0) }
            let total = root?["number_of_episodes"] as? Int ?? 0
            let name = root?["name"] as? String ?? root?["original_name"] as? String
            return TMDBShowDetails(name: name, numberOfEpisodes: total, seasons: seasons)
        } catch {
            return nil
        }
    }

    private func buildRelationContext(
        media: AniListMedia,
        tmdbTitle: String,
        tmdbTotalEpisodes: Int,
        desiredCount: Int
    ) async -> RelationContext? {
        let base = await resolveAniListBaseMedia(
            media: media,
            tmdbTitle: tmdbTitle,
            tmdbTotalEpisodes: tmdbTotalEpisodes,
            desiredCount: desiredCount
        )
        let chain = await buildRelationsChain(root: base)
        if chain.isEmpty {
            return nil
        }
        let recovered = await recoverOrphansIfNeeded(
            chain: chain,
            base: base,
            tmdbTotalEpisodes: tmdbTotalEpisodes
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
        desiredCount: Int
    ) async -> AniListMedia {
        var candidates: [AniListMedia] = [media]
        let queries = TitleMatcher.buildQueries(from: tmdbTitle)
        for query in queries {
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
        let corrected = await applyOvaCorrectionIfNeeded(
            base: best,
            desiredCount: desiredCount,
            tmdbTotalEpisodes: tmdbTotalEpisodes
        )
        if corrected.id != best.id {
            AppLog.debug(.matching, "relations ova correction base=\(best.id) -> \(corrected.id)")
        }
        return corrected
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
            if episodeTarget > 0, let eps = candidate.episodes, eps > 0 {
                let delta = abs(eps - episodeTarget)
                epScore = 1.0 - min(Double(delta) / Double(max(episodeTarget, 1)), 1.0)
            } else {
                epScore = 0.5
            }
            let yearScore: Double
            if let baseYear, let candidateYear = candidate.seasonYear {
                yearScore = 1.0 - min(Double(abs(candidateYear - baseYear)) / 3.0, 1.0)
            } else {
                yearScore = 0.5
            }
            let score = (0.6 * titleScore) + (0.25 * epScore) + (0.15 * yearScore)
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
        tmdbTotalEpisodes: Int
    ) async -> AniListMedia {
        let allowedFormats: Set<String> = ["TV", "ONA", "TV_SHORT"]
        let episodeTarget = tmdbTotalEpisodes > 0 ? tmdbTotalEpisodes : desiredCount
        let baseEpisodes = base.episodes ?? 0
        let looksLikeOva = (base.format.map { !allowedFormats.contains($0) } ?? false)
            || (episodeTarget > 0 && baseEpisodes > 0 && baseEpisodes < max(2, episodeTarget / 2))
        guard looksLikeOva else { return base }
        guard let edges = try? await aniListClient.relationsGraph(mediaId: base.id) else { return base }
        let candidates = edges.filter { edge in
            ["PARENT", "SOURCE", "PREQUEL"].contains(edge.relationType)
        }.map(\.media)
        let filtered = candidates.filter { media in
            guard let format = media.format else { return false }
            return allowedFormats.contains(format)
        }
        let best = filtered.max { (lhs, rhs) in
            let l = lhs.episodes ?? 0
            let r = rhs.episodes ?? 0
            return l < r
        }
        return best ?? base
    }

    private func buildRelationsChain(root: AniListMedia) async -> [AniListMedia] {
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
        tmdbTotalEpisodes: Int
    ) async -> [AniListMedia] {
        guard tmdbTotalEpisodes > 0 else { return chain }
        let totalEpisodes = chain.reduce(0) { $0 + ($1.episodes ?? 0) }
        guard totalEpisodes < Int(Double(tmdbTotalEpisodes) * 0.7) else { return chain }
        AppLog.debug(.matching, "relations orphan recovery start base=\(base.id) tmdbTotal=\(tmdbTotalEpisodes) chainTotal=\(totalEpisodes)")
        let allowedFormats: Set<String> = ["TV", "ONA", "TV_SHORT"]
        var visited = Set(chain.map(\.id))
        var recovered = chain
        let queries = TitleMatcher.buildQueries(from: base.title.best)
        for query in queries {
            if let results = try? await aniListClient.searchAnime(query: query) {
                for candidate in results {
                    if visited.contains(candidate.id) { continue }
                    guard let format = candidate.format, allowedFormats.contains(format) else { continue }
                    let titleScore = TitleMatcher.diceCoefficient(
                        TitleMatcher.cleanTitle(candidate.title.best),
                        TitleMatcher.cleanTitle(base.title.best)
                    )
                    let yearDelta: Int?
                    if let baseYear = base.seasonYear, let candidateYear = candidate.seasonYear {
                        yearDelta = abs(candidateYear - baseYear)
                    } else {
                        yearDelta = nil
                    }
                    if titleScore < 0.55 && (yearDelta ?? 0) > 4 { continue }
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
        if let index = chain.firstIndex(where: { $0.id == target.id }) {
            return index + 1
        }
        var best: (index: Int, score: Double)?
        let targetTitle = TitleMatcher.cleanTitle(target.title.best)
        for (idx, item) in chain.enumerated() {
            let score = TitleMatcher.diceCoefficient(
                TitleMatcher.cleanTitle(item.title.best),
                targetTitle
            )
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

private struct SeasonInfo {
    let seasonNumber: Int
    let episodeCount: Int
    let airYear: Int?
    let name: String?
    let airDateString: String?

    init?(from dict: [String: Any]) {
        guard let seasonNumber = dict["season_number"] as? Int else { return nil }
        self.seasonNumber = seasonNumber
        self.episodeCount = dict["episode_count"] as? Int ?? 0
        self.name = dict["name"] as? String
        let airDate = dict["air_date"] as? String
        self.airDateString = airDate
        if let airDate, airDate.count >= 4 {
            let yearString = String(airDate.prefix(4))
            self.airYear = Int(yearString)
        } else {
            self.airYear = nil
        }
    }
}

private struct TMDBShowDetails {
    let name: String?
    let numberOfEpisodes: Int
    let seasons: [SeasonInfo]
}

private struct RelationContext {
    let base: AniListMedia
    let chain: [AniListMedia]
    let seasonIndex: Int?
}

private struct SeasonSelectionResult {
    let seasonNumber: Int
    let accepted: Bool
    let rejectReason: String?
}

// OMDb response structs removed; TMDB is the single metadata source.
