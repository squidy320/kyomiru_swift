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
