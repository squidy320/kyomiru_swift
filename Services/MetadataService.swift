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
    let title: String
    let posterURL: URL?
    let backdropURL: URL?
    let logoURL: URL?
}

private struct TMDBMetadataNegativeCacheEntry: Codable {
    let missing: Bool
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
        let cacheKey = "tmdb:media:v4:\(media.id)"
        switch cachedMetadata(forKey: cacheKey) {
        case .hit(let cachedResult):
            return cachedResult
        case .negative:
            return nil
        case .missing:
            break
        }

        return await metadataRequests.value(for: media.id) { [self] in
            await Self.requestLimiter.run {
                switch cachedMetadata(forKey: cacheKey) {
                case .hit(let cachedResult):
                    return cachedResult
                case .negative:
                    return nil
                case .missing:
                    break
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
        let preferredSeasonNumber = TitleMatcher.extractSeasonNumber(from: media.title.best)
        guard let match = await tmdbMatcher.resolveShowAndSeason(
            media: media,
            franchiseStartYear: franchiseStartYear,
            firstEpisodeNumber: nil,
            preferredSeasonNumber: preferredSeasonNumber,
            expectedEpisodeCount: media.episodes,
            maxEpisodeNumber: media.episodes
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
            let posterURL = posterPath.flatMap { tmdbImageURL(path: $0, size: "w342") }
            let backdropURL = backdropPath.flatMap { tmdbImageURL(path: $0, size: "w780") }
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

        let preferredSeasonNumber = TitleMatcher.extractSeasonNumber(from: media.title.best)
        guard let match = await tmdbMatcher.matchShowAndSeason(
            media: media,
            franchiseStartYear: media.startDate?.year ?? media.seasonYear,
            firstEpisodeNumber: firstEpisodeNumber,
            preferredSeasonNumber: preferredSeasonNumber,
            expectedEpisodeCount: media.episodes,
            maxEpisodeNumber: firstEpisodeNumber
        ) else {
            return [:]
        }

        let targetSeason = match.seasonNumber
        let episodeOffset = match.episodeOffset

        let cacheKey = "tmdb:ratings:v4:\(media.id):season:\(targetSeason):offset:\(episodeOffset)"
        if let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 60 * 12),
           let decoded = try? JSONDecoder().decode([Int: Double].self, from: cached) {
            return decoded
        }

        guard let url = URL(string: "https://api.themoviedb.org/3/tv/\(match.showId)/season/\(targetSeason)?api_key=\(apiKey)") else {
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
            let firstEpisodeNumber = episodes.map(\.number).min()
            let maxEpisodeNumber = episodes.map(\.number).max() ?? 0
            let globalNumbering = maxEpisodeNumber >= desiredCount + 5 && maxEpisodeNumber > 0
            let maxKey = globalNumbering ? ":max:\(maxEpisodeNumber)" : ""
            let preferredSeason = TitleMatcher.extractSeasonNumber(from: media.title.best)

            var seasonNumber: Int?
            var episodeOffset: Int = 0
            if let cachedMeta = cacheManager.load(aniListId: media.id) {
                seasonNumber = cachedMeta.seasonNumber
                episodeOffset = cachedMeta.episodeOffset
            } else if let cachedMatch = cacheStore.readJSON(
                forKey: TMDBMatchingService.cacheKey(
                    mediaId: media.id,
                    preferredSeasonNumber: preferredSeason,
                    firstEpisodeNumber: firstEpisodeNumber,
                    expectedEpisodeCount: desiredCount,
                    maxEpisodeNumber: maxEpisodeNumber
                )
            ),
                      let decoded = try? JSONDecoder().decode(TMDBResolvedMatch.self, from: cachedMatch) {
                seasonNumber = decoded.seasonNumber
                episodeOffset = decoded.episodeOffset
            }

            guard let seasonNumber else { return nil }
            let offsetKey = episodeOffset != 0 ? ":offset:\(episodeOffset)" : ""
            let cacheKey = "episode-meta:tmdb:v7:\(media.id):season:\(seasonNumber):count:\(desiredCount)\(maxKey)\(offsetKey)"
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
            let preferredSeason = TitleMatcher.extractSeasonNumber(from: media.title.best)
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
            let cacheKey = "episode-meta:tmdb:v7:\(media.id):season:\(seasonNumber):count:\(desiredCount)\(maxKey)\(offsetKey)"
            if accepted, let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 60 * 12),
               let decoded = try? JSONDecoder().decode([Int: EpisodeMetadata].self, from: cached) {
                return decoded
            }
            if accepted, !primary.isEmpty {
                mapped = primary
                if let data = try? JSONEncoder().encode(mapped) {
                    cacheStore.writeJSON(data, forKey: cacheKey)
                }
            } else {
                let aniListFallback = await fetchFromAniListStreaming(media: media)
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
        let franchiseStartYear = media.startDate?.year ?? media.seasonYear
        guard let match = await tmdbMatcher.matchShowAndSeason(
            media: media,
            franchiseStartYear: franchiseStartYear,
            firstEpisodeNumber: firstEpisodeNumber,
            preferredSeasonNumber: preferredSeason,
            expectedEpisodeCount: desiredCount,
            maxEpisodeNumber: maxEpisodeNumber,
        ) else {
            return ([:], preferredSeason ?? 1, 0, false, "no-canonical-match")
        }

        let data = await fetchTMDBSeason(showId: match.showId, seasonNumber: match.seasonNumber)
        let mapped = match.episodeOffset == 0 ? data : applyEpisodeOffset(data, offset: match.episodeOffset)
        return (mapped, match.seasonNumber, match.episodeOffset, !mapped.isEmpty, mapped.isEmpty ? "empty-season" : nil)
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
}
