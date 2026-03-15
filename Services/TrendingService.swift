import Foundation

struct TrendingItem: Identifiable, Equatable {
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
