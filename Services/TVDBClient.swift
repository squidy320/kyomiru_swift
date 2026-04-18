import Foundation

private actor TVDBTokenStore {
    private var token: String?
    private var inFlight: Task<String?, Never>?

    func value(start: @escaping @Sendable () async -> String?) async -> String? {
        if let token {
            return token
        }
        if let inFlight {
            return await inFlight.value
        }

        let task = Task {
            await start()
        }
        inFlight = task
        let resolved = await task.value
        token = resolved
        inFlight = nil
        return resolved
    }

    func clear() {
        token = nil
    }
}

struct TVDBSearchHit {
    let id: Int
    let mediaType: String
    let title: String
    let imageURL: URL?
    let year: Int?
}

struct TVDBSeasonSummary {
    let id: Int
    let number: Int
    let name: String?
    let airDate: String?
    let episodeCount: Int
    let isSpecial: Bool
    let typeName: String?
}

struct TVDBEpisodeRecord {
    let number: Int
    let title: String?
    let summary: String?
    let airDate: String?
    let runtimeMinutes: Int?
    let imageURL: URL?
    let rating: Double?
}

struct TVDBSeriesRecord {
    let id: Int
    let title: String
    let airDate: String?
    let seasons: [TVDBSeasonSummary]
    let posterURL: URL?
    let backdropURL: URL?
    let logoURL: URL?
}

struct TVDBMovieRecord {
    let id: Int
    let title: String
    let summary: String?
    let releaseDate: String?
    let runtimeMinutes: Int?
    let posterURL: URL?
    let backdropURL: URL?
    let logoURL: URL?
    let rating: Double?
}

struct TVDBSeasonRecord {
    let id: Int
    let number: Int
    let name: String?
    let posterURL: URL?
    let episodes: [TVDBEpisodeRecord]
}

final class TVDBClient {
    private let session: URLSession
    private let apiKey: String?
    private let pin: String?
    private let tokens = TVDBTokenStore()

    init(session: URLSession = .custom, apiKey: String?, pin: String? = nil) {
        self.session = session
        self.apiKey = apiKey
        self.pin = pin
    }

    func search(query: String, type: String? = nil) async -> [TVDBSearchHit] {
        var items = [URLQueryItem(name: "query", value: query)]
        if let type {
            items.append(URLQueryItem(name: "type", value: type))
        }
        guard let rows = await requestArray(path: "/search", queryItems: items) else { return [] }
        return rows.compactMap(parseSearchHit(from:))
    }

    func searchRemoteID(_ remoteID: String) async -> TVDBSearchHit? {
        guard let rows = await requestArray(path: "/search/remoteid/\(remoteID)") else { return nil }
        return rows.compactMap(parseSearchHit(from:)).first
    }

    func fetchSeries(_ id: Int) async -> TVDBSeriesRecord? {
        guard let root = await requestObject(path: "/series/\(id)/extended") else { return nil }
        return parseSeries(from: root)
    }

    func fetchMovie(_ id: Int) async -> TVDBMovieRecord? {
        guard let root = await requestObject(path: "/movies/\(id)/extended") else { return nil }
        return parseMovie(from: root)
    }

    func fetchSeason(_ id: Int) async -> TVDBSeasonRecord? {
        guard let root = await requestObject(path: "/seasons/\(id)/extended") else { return nil }
        return parseSeason(from: root)
    }

    private func requestObject(path: String, queryItems: [URLQueryItem] = []) async -> [String: Any]? {
        guard let payload = await request(path: path, queryItems: queryItems) else { return nil }
        return payload as? [String: Any]
    }

    private func requestArray(path: String, queryItems: [URLQueryItem] = []) async -> [[String: Any]]? {
        guard let payload = await request(path: path, queryItems: queryItems) else { return nil }
        return payload as? [[String: Any]]
    }

    private func request(path: String, queryItems: [URLQueryItem]) async -> Any? {
        guard let token = await authenticatedToken() else { return nil }
        guard let url = buildURL(path: path, queryItems: queryItems) else { return nil }

        if let payload = await perform(url: url, token: token) {
            return payload
        }

        await tokens.clear()
        guard let refreshed = await authenticatedToken() else { return nil }
        return await perform(url: url, token: refreshed)
    }

    private func perform(url: URL, token: String) async -> Any? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard (200..<300).contains(http.statusCode) else { return nil }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return root?["data"]
        } catch {
            return nil
        }
    }

    private func authenticatedToken() async -> String? {
        await tokens.value { [session, apiKey, pin] in
            guard let apiKey, !apiKey.isEmpty, apiKey != "CHANGE_ME" else { return nil }
            guard let url = URL(string: "https://api4.thetvdb.com/v4/login") else { return nil }

            var body: [String: Any] = ["apikey": apiKey]
            if let pin, !pin.isEmpty, pin != "CHANGE_ME" {
                body["pin"] = pin
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    return nil
                }
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let data = root?["data"] as? [String: Any]
                return data?["token"] as? String
            } catch {
                return nil
            }
        }
    }

    private func buildURL(path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: "https://api4.thetvdb.com/v4\(path)")
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        return components?.url
    }

    private func parseSearchHit(from row: [String: Any]) -> TVDBSearchHit? {
        guard let id = int(in: row, keys: ["tvdb_id", "id", "objectID"]) else { return nil }
        let mediaType = normalizedMediaType(from: row)
        let title = string(in: row, keys: ["name", "title", "slug"]) ?? "Unknown"
        let imageURL = url(in: row, keys: ["image_url", "image", "thumbnail"])
        let year = int(in: row, keys: ["year"]) ?? yearFrom(string(in: row, keys: ["first_air_time", "firstAired", "releaseDate"]))
        return TVDBSearchHit(id: id, mediaType: mediaType, title: title, imageURL: imageURL, year: year)
    }

    private func parseSeries(from row: [String: Any]) -> TVDBSeriesRecord? {
        guard let id = int(in: row, keys: ["id", "tvdb_id"]) else { return nil }
        let title = string(in: row, keys: ["name", "slug"]) ?? "Unknown"
        let airDate = string(in: row, keys: ["firstAired", "first_air_time"])
        let artwork = artworkSelection(from: row)
        let rawSeasons = (row["seasons"] as? [[String: Any]] ?? [])
            .compactMap(parseSeasonSummary(from:))
        let seasons = mergeSeasonSummaries(rawSeasons)
        return TVDBSeriesRecord(
            id: id,
            title: title,
            airDate: airDate,
            seasons: seasons,
            posterURL: artwork.poster ?? url(in: row, keys: ["image", "image_url"]),
            backdropURL: artwork.backdrop,
            logoURL: artwork.logo
        )
    }

    private func parseMovie(from row: [String: Any]) -> TVDBMovieRecord? {
        guard let id = int(in: row, keys: ["id", "tvdb_id"]) else { return nil }
        let artwork = artworkSelection(from: row)
        return TVDBMovieRecord(
            id: id,
            title: string(in: row, keys: ["name", "title", "slug"]) ?? "Unknown",
            summary: string(in: row, keys: ["overview"]),
            releaseDate: string(in: row, keys: ["firstAired", "releaseDate"]),
            runtimeMinutes: int(in: row, keys: ["runtime"]),
            posterURL: artwork.poster ?? url(in: row, keys: ["image", "image_url"]),
            backdropURL: artwork.backdrop,
            logoURL: artwork.logo,
            rating: double(in: row, keys: ["score", "averageRating"])
        )
    }

    private func parseSeason(from row: [String: Any]) -> TVDBSeasonRecord? {
        guard let id = int(in: row, keys: ["id"]) else { return nil }
        let posterURL = artworkSelection(from: row).poster ?? url(in: row, keys: ["image", "image_url"])
        let episodes = (row["episodes"] as? [[String: Any]] ?? [])
            .compactMap(parseEpisode(from:))
            .sorted { $0.number < $1.number }
        return TVDBSeasonRecord(
            id: id,
            number: int(in: row, keys: ["number", "seasonNumber"]) ?? 0,
            name: string(in: row, keys: ["name"]),
            posterURL: posterURL,
            episodes: episodes
        )
    }

    private func parseSeasonSummary(from row: [String: Any]) -> TVDBSeasonSummary? {
        guard let id = int(in: row, keys: ["id"]) else { return nil }
        let number = int(in: row, keys: ["number", "seasonNumber"]) ?? 0
        let typeName = string(in: row["type"] as? [String: Any], keys: ["name"]) ?? string(in: row, keys: ["type"])
        let episodeCount = int(in: row, keys: ["episodeNumber", "episodeCount"]) ?? ((row["episodes"] as? [[String: Any]])?.count ?? 0)
        return TVDBSeasonSummary(
            id: id,
            number: number,
            name: string(in: row, keys: ["name"]),
            airDate: string(in: row, keys: ["firstAired", "year", "aired"]),
            episodeCount: episodeCount,
            isSpecial: number == 0 || (typeName?.localizedCaseInsensitiveContains("special") == true),
            typeName: typeName
        )
    }

    private func parseEpisode(from row: [String: Any]) -> TVDBEpisodeRecord? {
        guard let number = int(in: row, keys: ["number", "airedEpisodeNumber", "episodeNumber"]), number > 0 else {
            return nil
        }
        return TVDBEpisodeRecord(
            number: number,
            title: string(in: row, keys: ["name"]),
            summary: string(in: row, keys: ["overview"]),
            airDate: string(in: row, keys: ["aired", "firstAired"]),
            runtimeMinutes: int(in: row, keys: ["runtime"]),
            imageURL: url(in: row, keys: ["image", "image_url"]),
            rating: double(in: row, keys: ["score"])
        )
    }

    private func mergeSeasonSummaries(_ seasons: [TVDBSeasonSummary]) -> [TVDBSeasonSummary] {
        var byNumber: [Int: TVDBSeasonSummary] = [:]
        for season in seasons {
            let key = season.number
            if let existing = byNumber[key] {
                if rank(season.typeName) > rank(existing.typeName) {
                    byNumber[key] = season
                }
            } else {
                byNumber[key] = season
            }
        }

        return byNumber.values
            .filter { $0.number >= 0 }
            .sorted { lhs, rhs in
                if lhs.number == rhs.number {
                    return rank(lhs.typeName) > rank(rhs.typeName)
                }
                return lhs.number < rhs.number
            }
    }

    private func rank(_ typeName: String?) -> Int {
        let normalized = typeName?.lowercased() ?? ""
        if normalized.contains("aired") { return 4 }
        if normalized.contains("official") { return 3 }
        if normalized.contains("dvd") { return 2 }
        return 1
    }

    private func normalizedMediaType(from row: [String: Any]) -> String {
        if let type = string(in: row, keys: ["type"])?.lowercased() {
            if type.contains("movie") {
                return "movie"
            }
            if type.contains("series") {
                return "tv"
            }
        }
        if let type = string(in: row["type"] as? [String: Any], keys: ["name"])?.lowercased() {
            if type.contains("movie") {
                return "movie"
            }
            if type.contains("series") {
                return "tv"
            }
        }
        return "tv"
    }

    private func artworkSelection(from row: [String: Any]) -> (poster: URL?, backdrop: URL?, logo: URL?) {
        let artworks = row["artworks"] as? [[String: Any]] ?? []
        var poster = url(in: row, keys: ["image", "image_url"])
        var backdrop: URL?
        var logo: URL?

        for artwork in artworks {
            guard let image = url(in: artwork, keys: ["image", "image_url", "thumbnail"]) else { continue }
            let descriptor = [
                string(in: artwork, keys: ["type"]),
                string(in: artwork, keys: ["name"]),
                string(in: artwork["type"] as? [String: Any], keys: ["name"])
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

            if logo == nil, descriptor.contains("logo") {
                logo = image
                continue
            }
            if backdrop == nil && (descriptor.contains("background") || descriptor.contains("banner") || descriptor.contains("fanart")) {
                backdrop = image
                continue
            }
            if poster == nil && descriptor.contains("poster") {
                poster = image
            }
        }

        return (poster, backdrop, logo)
    }

    private func string(in dict: [String: Any]?, keys: [String]) -> String? {
        guard let dict else { return nil }
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func int(in dict: [String: Any]?, keys: [String]) -> Int? {
        guard let dict else { return nil }
        for key in keys {
            if let value = dict[key] as? Int {
                return value
            }
            if let value = dict[key] as? Double {
                return Int(value)
            }
            if let value = dict[key] as? String, let intValue = Int(value) {
                return intValue
            }
        }
        return nil
    }

    private func double(in dict: [String: Any]?, keys: [String]) -> Double? {
        guard let dict else { return nil }
        for key in keys {
            if let value = dict[key] as? Double {
                return value
            }
            if let value = dict[key] as? Int {
                return Double(value)
            }
            if let value = dict[key] as? String, let doubleValue = Double(value) {
                return doubleValue
            }
        }
        return nil
    }

    private func url(in dict: [String: Any]?, keys: [String]) -> URL? {
        guard let string = string(in: dict, keys: keys) else { return nil }
        return URL(string: string)
    }

    private func yearFrom(_ dateString: String?) -> Int? {
        guard let dateString, dateString.count >= 4 else { return nil }
        return Int(dateString.prefix(4))
    }
}
