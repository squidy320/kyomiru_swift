import Foundation

struct IMDbMetadata: Equatable, Codable {
    let imdbID: String
    let title: String
    let year: String?
    let posterURL: URL?
    let backdropURL: URL?
}

final class MetadataService {
    private let session: URLSession
    private let cacheStore: CacheStore
    private let apiKey: String?

    init(cacheStore: CacheStore, session: URLSession = .custom) {
        self.cacheStore = cacheStore
        self.session = session
        self.apiKey = Bundle.main.object(forInfoDictionaryKey: "OMDB_API_KEY") as? String
    }

    func fetchIMDbMetadata(for media: AniListMedia) async -> IMDbMetadata? {
        let cacheKey = "imdb:\(media.id)"
        if let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 60 * 24),
           let decoded = try? JSONDecoder().decode(IMDbMetadata.self, from: cached) {
            return decoded
        }

        guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else {
            AppLog.error(.network, "omdb api key missing")
            return nil
        }

        let title = media.title.english ?? media.title.romaji ?? media.title.native ?? media.title.best
        guard let imdbID = await resolveIMDbID(title: title, year: media.seasonYear, apiKey: apiKey) else {
            return nil
        }

        guard let details = await fetchIMDbDetails(imdbID: imdbID, apiKey: apiKey) else {
            return nil
        }

        if let data = try? JSONEncoder().encode(details) {
            cacheStore.writeJSON(data, forKey: cacheKey)
        }
        return details
    }

    func posterURL(for media: AniListMedia) async -> URL? {
        let meta = await fetchIMDbMetadata(for: media)
        return meta?.posterURL
    }

    func backdropURL(for media: AniListMedia) async -> URL? {
        let meta = await fetchIMDbMetadata(for: media)
        return meta?.backdropURL ?? meta?.posterURL
    }

    func manualMatch(local: MediaItem, remoteId: String) async -> Bool {
        AppLog.debug(.matching, "manual match local=\(local.title) remote=\(remoteId)")
        try? await Task.sleep(nanoseconds: 200_000_000)
        return true
    }

    private func resolveIMDbID(title: String, year: Int?, apiKey: String) async -> String? {
        var components = URLComponents(string: "https://www.omdbapi.com/")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "s", value: title),
            URLQueryItem(name: "type", value: "series")
        ]
        if let year {
            items.append(URLQueryItem(name: "y", value: String(year)))
        }
        components.queryItems = items
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let result = try JSONDecoder().decode(OmdbSearchResponse.self, from: data)
            return result.search?.first?.imdbID
        } catch {
            return nil
        }
    }

    private func fetchIMDbDetails(imdbID: String, apiKey: String) async -> IMDbMetadata? {
        var components = URLComponents(string: "https://www.omdbapi.com/")!
        components.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "i", value: imdbID),
            URLQueryItem(name: "plot", value: "short")
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let details = try JSONDecoder().decode(OmdbTitleResponse.self, from: data)
            guard details.response == "True" else { return nil }
            let posterURL = details.posterURL
            let metadata = IMDbMetadata(
                imdbID: imdbID,
                title: details.title ?? "Unknown",
                year: details.year,
                posterURL: posterURL,
                backdropURL: posterURL
            )
            return metadata
        } catch {
            return nil
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

    init(cacheStore: CacheStore, session: URLSession = .custom) {
        self.cacheStore = cacheStore
        self.session = session
        self.apiKey = Bundle.main.object(forInfoDictionaryKey: "TMDB_API_KEY") as? String
    }

    func ratingsForSeason(media: AniListMedia, seasonNumber: Int = 1) async -> [Int: Double] {
        let cacheKey = "tmdb:ratings:\(media.id):season:\(seasonNumber)"
        if let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 60 * 12),
           let decoded = try? JSONDecoder().decode([Int: Double].self, from: cached) {
            return decoded
        }

        guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else {
            AppLog.error(.network, "tmdb api key missing")
            return [:]
        }

        guard let tvId = await resolveTMDBShowId(media: media, apiKey: apiKey) else {
            return [:]
        }

        guard let url = URL(string: "https://api.themoviedb.org/3/tv/\(tvId)/season/\(seasonNumber)?api_key=\(apiKey)") else {
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
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/tv")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: title)
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
}

struct TrendingItem: Identifiable, Equatable, Codable {
    let id: Int
    let title: String
    let backdropURL: URL?
    let logoURL: URL?
    let imdbId: String?
}

final class TrendingService {
    private let session: URLSession
    private let cacheStore: CacheStore
    private let apiKey: String?
    private let imageBase = "https://image.tmdb.org/t/p/original"

    init(cacheStore: CacheStore, session: URLSession = .custom) {
        self.cacheStore = cacheStore
        self.session = session
        self.apiKey = Bundle.main.object(forInfoDictionaryKey: "TMDB_API_KEY") as? String
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
                let imdbId = await fetchImdbId(tvId: id, apiKey: apiKey)
                let logo = await fetchBestLogo(tvId: id, apiKey: apiKey)
                items.append(TrendingItem(id: id, title: name, backdropURL: backdrop, logoURL: logo, imdbId: imdbId))
            }

            if let data = try? JSONEncoder().encode(items) {
                cacheStore.writeJSON(data, forKey: cacheKey)
            }
            return items
        } catch {
            return []
        }
    }

    private func fetchImdbId(tvId: Int, apiKey: String) async -> String? {
        guard let url = URL(string: "https://api.themoviedb.org/3/tv/\(tvId)/external_ids?api_key=\(apiKey)") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return root?["imdb_id"] as? String
        } catch {
            return nil
        }
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
}

final class EpisodeMetadataService {
    enum Provider: String {
        case kitsu
        case tmdb
    }

    private let session: URLSession
    private let cacheStore: CacheStore
    private let provider: Provider
    private let tmdbKey: String?

    init(cacheStore: CacheStore, provider: Provider = .kitsu, session: URLSession = .custom) {
        self.cacheStore = cacheStore
        self.session = session
        self.provider = provider
        self.tmdbKey = Bundle.main.object(forInfoDictionaryKey: "TMDB_API_KEY") as? String
    }

    func fetchEpisodes(for media: AniListMedia, episodes: [SoraEpisode]) async -> [Int: EpisodeMetadata] {
        let cacheKey = "episode-meta:\(provider.rawValue):\(media.id)"
        if let cached = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 60 * 12),
           let decoded = try? JSONDecoder().decode([Int: EpisodeMetadata].self, from: cached) {
            return decoded
        }

        let mapped: [Int: EpisodeMetadata]
        switch provider {
        case .kitsu:
            mapped = await fetchFromKitsu(media: media)
        case .tmdb:
            let primary = await fetchFromTMDB(media: media, seasonNumber: 1)
            mapped = primary.isEmpty ? await fetchFromKitsu(media: media) : primary
        }

        if let data = try? JSONEncoder().encode(mapped) {
            cacheStore.writeJSON(data, forKey: cacheKey)
        }
        return mapped
    }

    private func fetchFromKitsu(media: AniListMedia) async -> [Int: EpisodeMetadata] {
        let title = media.title.english ?? media.title.romaji ?? media.title.native ?? media.title.best
        let animeId = await resolveKitsuAnimeId(malId: media.idMal, title: title)
        guard let animeId else { return [:] }
        return await fetchKitsuEpisodes(animeId: animeId)
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

    private func fetchFromTMDB(media: AniListMedia, seasonNumber: Int) async -> [Int: EpisodeMetadata] {
        guard let tmdbKey, !tmdbKey.isEmpty, tmdbKey != "CHANGE_ME" else { return [:] }
        let title = media.title.english ?? media.title.romaji ?? media.title.native ?? media.title.best
        guard let showId = await resolveTMDBShowId(title: title) else { return [:] }
        return await fetchTMDBSeason(showId: showId, seasonNumber: seasonNumber)
    }

    private func resolveTMDBShowId(title: String) async -> Int? {
        guard let tmdbKey else { return nil }
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/tv")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: tmdbKey),
            URLQueryItem(name: "query", value: title)
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
}

private struct OmdbSearchResponse: Decodable {
    let search: [OmdbSearchItem]?
    let response: String?

    private enum CodingKeys: String, CodingKey {
        case search = "Search"
        case response = "Response"
    }
}

private struct OmdbSearchItem: Decodable {
    let imdbID: String
    private enum CodingKeys: String, CodingKey {
        case imdbID = "imdbID"
    }
}

private struct OmdbTitleResponse: Decodable {
    let title: String?
    let year: String?
    let poster: String?
    let response: String?

    private enum CodingKeys: String, CodingKey {
        case title = "Title"
        case year = "Year"
        case poster = "Poster"
        case response = "Response"
    }

    var posterURL: URL? {
        guard let poster, poster != "N/A" else { return nil }
        return URL(string: poster)
    }
}
