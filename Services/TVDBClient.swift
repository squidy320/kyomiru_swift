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

private actor TVDBArtworkTypeStore {
    private var cached: [Int: String]?
    private var inFlight: Task<[Int: String], Never>?

    func value(start: @escaping @Sendable () async -> [Int: String]) async -> [Int: String] {
        if let cached {
            return cached
        }
        if let inFlight {
            return await inFlight.value
        }

        let task = Task {
            await start()
        }
        inFlight = task
        let resolved = await task.value
        cached = resolved
        inFlight = nil
        return resolved
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
    private let artworkTypes = TVDBArtworkTypeStore()

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
        guard let root = await requestObject(path: "/series/\(id)/extended", queryItems: [URLQueryItem(name: "meta", value: "translations")]) else { return nil }
        let artworkTypeNames = await artworkTypeNames()
        return parseSeries(from: root, artworkTypeNames: artworkTypeNames)
    }

    func fetchMovie(_ id: Int) async -> TVDBMovieRecord? {
        guard let root = await requestObject(path: "/movies/\(id)/extended", queryItems: [URLQueryItem(name: "meta", value: "translations")]) else { return nil }
        let artworkTypeNames = await artworkTypeNames()
        return parseMovie(from: root, artworkTypeNames: artworkTypeNames)
    }

    func fetchSeason(_ id: Int) async -> TVDBSeasonRecord? {
        guard let root = await requestObject(path: "/seasons/\(id)/extended", queryItems: [URLQueryItem(name: "meta", value: "translations")]) else { return nil }
        let artworkTypeNames = await artworkTypeNames()
        return parseSeason(from: root, artworkTypeNames: artworkTypeNames)
    }

    /// Fetch episode translations for a specific episode
    /// - Parameters:
    ///   - episodeId: The TVDB episode ID
    ///   - language: ISO 639-1 language code (default: "en" for English)
    /// - Returns: Translation data including name and overview in requested language
    func fetchEpisodeTranslation(_ episodeId: Int, language: String = "en") async -> (name: String?, overview: String?)? {
        guard let root = await requestObject(path: "/episodes/\(episodeId)/translations", queryItems: [URLQueryItem(name: "lang", value: language)]) else {
            // Fallback: try to get it from the extended episode endpoint
            guard let episodeRoot = await requestObject(path: "/episodes/\(episodeId)/extended") else { return nil }
            return (
                name: translatedString(in: episodeRoot, translationKeys: ["nameTranslations", "name"], baseKeys: ["name"]),
                overview: translatedString(in: episodeRoot, translationKeys: ["overviewTranslations", "overview"], baseKeys: ["overview"])
            )
        }

        // Handle the translation response
        if let translations = root["translations"] as? [[String: Any]] {
            // Find English translation first
            let englishTranslation = translations.first(where: { trans in
                let lang = string(in: trans, keys: ["language", "languageCode"])?.lowercased() ?? ""
                return lang == "en" || lang == "eng"
            })

            if let trans = englishTranslation {
                return (
                    name: string(in: trans, keys: ["name", "translatedName"]),
                    overview: string(in: trans, keys: ["overview", "translatedOverview"])
                )
            }

            // Fallback to first available translation if English not found
            if let trans = translations.first {
                return (
                    name: string(in: trans, keys: ["name", "translatedName"]),
                    overview: string(in: trans, keys: ["overview", "translatedOverview"])
                )
            }
        }

        return nil
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
                let payload = root?["data"] as? [String: Any]
                return payload?["token"] as? String
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

    private func artworkTypeNames() async -> [Int: String] {
        await artworkTypes.value { [weak self] in
            guard let self else { return [:] }
            guard let rows = await self.requestArray(path: "/artwork/types") else { return [:] }
            var mapped: [Int: String] = [:]
            for row in rows {
                guard let id = self.int(in: row, keys: ["id"]) else { continue }
                let name = self.string(in: row, keys: ["name", "slug"]) ?? ""
                mapped[id] = name
            }
            return mapped
        }
    }

    private func parseSearchHit(from row: [String: Any]) -> TVDBSearchHit? {
        guard let id = int(in: row, keys: ["tvdb_id", "id", "objectID"]) else { return nil }
        let mediaType = normalizedMediaType(from: row)
        let title = string(in: row, keys: ["name", "title", "slug"]) ?? "Unknown"
        let imageURL = url(in: row, keys: ["image_url", "image", "thumbnail"])
        let year = int(in: row, keys: ["year"]) ?? yearFrom(string(in: row, keys: ["first_air_time", "firstAired", "releaseDate"]))
        return TVDBSearchHit(id: id, mediaType: mediaType, title: title, imageURL: imageURL, year: year)
    }

    private func parseSeries(from row: [String: Any], artworkTypeNames: [Int: String]) -> TVDBSeriesRecord? {
        guard let id = int(in: row, keys: ["id", "tvdb_id"]) else { return nil }
        let title = translatedString(in: row, translationKeys: ["nameTranslations", "name"], baseKeys: ["name", "slug"]) ?? "Unknown"
        let airDate = string(in: row, keys: ["firstAired", "first_air_time", "releaseDate"])
        let artwork = artworkSelection(from: row, artworkTypeNames: artworkTypeNames)
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

    private func parseMovie(from row: [String: Any], artworkTypeNames: [Int: String]) -> TVDBMovieRecord? {
        guard let id = int(in: row, keys: ["id", "tvdb_id"]) else { return nil }
        let artwork = artworkSelection(from: row, artworkTypeNames: artworkTypeNames)
        return TVDBMovieRecord(
            id: id,
            title: translatedString(in: row, translationKeys: ["nameTranslations", "name"], baseKeys: ["name", "title", "slug"]) ?? "Unknown",
            summary: translatedString(in: row, translationKeys: ["overviewTranslations", "overview"], baseKeys: ["overview"]),
            releaseDate: string(in: row, keys: ["firstAired", "releaseDate"]),
            runtimeMinutes: int(in: row, keys: ["runtime"]),
            posterURL: artwork.poster ?? url(in: row, keys: ["image", "image_url"]),
            backdropURL: artwork.backdrop,
            logoURL: artwork.logo,
            rating: double(in: row, keys: ["score", "averageRating"])
        )
    }

    private func parseSeason(from row: [String: Any], artworkTypeNames: [Int: String]) -> TVDBSeasonRecord? {
        guard let id = int(in: row, keys: ["id"]) else { return nil }
        let posterURL = artworkSelection(from: row, artworkTypeNames: artworkTypeNames).poster ?? url(in: row, keys: ["image", "image_url"])
        let episodes = (row["episodes"] as? [[String: Any]] ?? [])
            .compactMap(parseEpisode(from:))
            .sorted { $0.number < $1.number }
        return TVDBSeasonRecord(
            id: id,
            number: int(in: row, keys: ["number", "seasonNumber"]) ?? 0,
            name: translatedString(in: row, translationKeys: ["nameTranslations", "name"], baseKeys: ["name"]),
            posterURL: posterURL,
            episodes: episodes
        )
    }

    private func parseSeasonSummary(from row: [String: Any]) -> TVDBSeasonSummary? {
        guard let id = int(in: row, keys: ["id"]) else { return nil }
        let number = int(in: row, keys: ["number", "seasonNumber"]) ?? 0
        let typeName = string(in: row["type"] as? [String: Any], keys: ["name"]) ?? string(in: row, keys: ["type"])
        let episodeCount = int(in: row, keys: ["episodeNumber", "episodeCount"]) ?? ((row["episodes"] as? [[String: Any]])?.count ?? 0)
        
        // Detect special types including OVA, ONA, special, etc.
        let isSpecialType = number == 0 || 
            (typeName?.localizedCaseInsensitiveContains("special") == true) ||
            (typeName?.localizedCaseInsensitiveContains("ova") == true) ||
            (typeName?.localizedCaseInsensitiveContains("ona") == true) ||
            (typeName?.localizedCaseInsensitiveContains("movie") == true)
        
        return TVDBSeasonSummary(
            id: id,
            number: number,
            name: translatedString(in: row, translationKeys: ["nameTranslations", "name"], baseKeys: ["name"]),
            airDate: string(in: row, keys: ["firstAired", "year", "aired"]),
            episodeCount: episodeCount,
            isSpecial: isSpecialType,
            typeName: typeName
        )
    }

    private func parseEpisode(from row: [String: Any]) -> TVDBEpisodeRecord? {
        guard let number = int(in: row, keys: ["number", "airedEpisodeNumber", "episodeNumber"]), number >= 0 else {
            return nil
        }
        return TVDBEpisodeRecord(
            number: number,
            title: translatedString(in: row, translationKeys: ["nameTranslations", "name"], baseKeys: ["name"]),
            summary: translatedString(in: row, translationKeys: ["overviewTranslations", "overview"], baseKeys: ["overview"]),
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

        // Keep all seasons including season 0 (specials/OVAs/movies)
        return byNumber.values
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

    private func artworkSelection(from row: [String: Any], artworkTypeNames: [Int: String]) -> (poster: URL?, backdrop: URL?, logo: URL?) {
        let artworks = row["artworks"] as? [[String: Any]] ?? []
        let poster = bestArtworkURL(
            in: artworks,
            artworkTypeNames: artworkTypeNames,
            matchingAnyOf: ["poster", "cover"]
        ) ?? url(in: row, keys: ["image", "image_url"])
        let backdrop = bestArtworkURL(
            in: artworks,
            artworkTypeNames: artworkTypeNames,
            matchingAnyOf: ["background", "banner", "fanart"]
        )
        let logo = bestArtworkURL(
            in: artworks,
            artworkTypeNames: artworkTypeNames,
            matchingAnyOf: ["logo", "clearlogo", "clear art", "clearart"]
        )

        return (poster, backdrop, logo)
    }

    private func artworkDescriptor(for artwork: [String: Any], artworkTypeNames: [Int: String]) -> String {
        var parts: [String] = []
        if let typeID = artworkTypeID(in: artwork),
           let name = artworkTypeNames[typeID] {
            parts.append(name)
        }
        if let type = string(in: artwork, keys: ["type"]) {
            parts.append(type)
        }
        if let name = string(in: artwork, keys: ["name"]) {
            parts.append(name)
        }
        if let nestedType = string(in: artwork["type"] as? [String: Any], keys: ["name"]) {
            parts.append(nestedType)
        }
        return parts.map { $0.lowercased() }.joined(separator: " ")
    }

    private func artworkTypeID(in artwork: [String: Any]) -> Int? {
        if let nested = artwork["type"] as? [String: Any],
           let id = int(in: nested, keys: ["id"]) {
            return id
        }
        return int(in: artwork, keys: ["type", "typeId", "artworkType"])
    }

    private func bestArtworkURL(
        in artworks: [[String: Any]],
        artworkTypeNames: [Int: String],
        matchingAnyOf descriptors: [String]
    ) -> URL? {
        let normalizedDescriptors = descriptors.map { $0.lowercased() }
        let match = artworks
            .compactMap { artwork -> (url: URL, score: Int)? in
                guard let image = url(in: artwork, keys: ["image", "image_url", "thumbnail"]) else {
                    return nil
                }
                let descriptor = artworkDescriptor(for: artwork, artworkTypeNames: artworkTypeNames)
                guard normalizedDescriptors.contains(where: { descriptor.contains($0) }) else {
                    return nil
                }
                return (image, artworkScore(for: artwork, descriptor: descriptor))
            }
            .max { lhs, rhs in lhs.score < rhs.score }
        return match?.url
    }

    private func artworkScore(for artwork: [String: Any], descriptor: String) -> Int {
        var score = 0
        let language = artworkLanguage(for: artwork)
        switch language {
        case "eng", "en":
            score += 40
        case "jpn", "ja":
            score += 30
        case "", "null":
            score += 20
        default:
            score += 10
        }

        if descriptor.contains("official") { score += 12 }
        if descriptor.contains("clearlogo") || descriptor.contains("clear art") || descriptor.contains("clearart") {
            score += 10
        }
        if descriptor.contains("series") || descriptor.contains("movie") {
            score += 4
        }
        score += int(in: artwork, keys: ["score"]) ?? 0
        return score
    }

    private func artworkLanguage(for artwork: [String: Any]) -> String {
        translationLanguage(from: artwork)
    }

    private func translatedString(in row: [String: Any], translationKeys: [String], baseKeys: [String]) -> String? {
        if let translations = row["translations"] as? [String: Any] {
            for key in translationKeys {
                if let translated = translatedString(from: translations[key]) {
                    return translated
                }
            }
        }
        for key in translationKeys {
            if let translated = translatedString(from: row[key]) {
                return translated
            }
        }
        return string(in: row, keys: baseKeys)
    }

    private func translatedString(from value: Any?) -> String? {
        if let map = value as? [String: Any] {
            // First pass: Look for direct English keys
            for key in ["eng", "en", "english"] {
                if let text = map[key] as? String, !text.isEmpty {
                    return text
                }
            }
            // Second pass: Look for value in English translations
            if let text = map["value"] as? String, !text.isEmpty {
                return text
            }
            // Third pass: Check nested structures for English
            for key in ["eng", "en", "english"] {
                if let nested = translatedString(from: map[key]) {
                    return nested
                }
            }
            // Last resort: Any other language
            for nested in map.values {
                if let text = translatedString(from: nested) {
                    return text
                }
            }
        }
        if let list = value as? [[String: Any]] {
            // First priority: English
            for language in ["eng", "en", "english"] {
                if let match = list.first(where: { translationLanguage(from: $0) == language }) {
                    if let text = string(in: match, keys: ["name", "overview", "value", "translation", "translatedName", "translatedOverview"]) {
                        return text
                    }
                }
            }
            // Second priority: Romance languages
            for language in ["spa", "fra", "ita", "por"] {
                if let match = list.first(where: { translationLanguage(from: $0) == language }) {
                    if let text = string(in: match, keys: ["name", "overview", "value", "translation", "translatedName", "translatedOverview"]) {
                        return text
                    }
                }
            }
            // Third priority: Other languages
            for language in ["deu", "jpn", "ja", "ja-JP", "zh", "ko"] {
                if let match = list.first(where: { translationLanguage(from: $0) == language }) {
                    if let text = string(in: match, keys: ["name", "overview", "value", "translation", "translatedName", "translatedOverview"]) {
                        return text
                    }
                }
            }
            // Fallback: first non-empty item
            for item in list {
                if let text = string(in: item, keys: ["name", "overview", "value", "translation", "translatedName", "translatedOverview"]), !text.isEmpty {
                    return text
                }
            }
        }
        if let text = value as? String, !text.isEmpty {
            return text
        }
        return nil
    }

    private func translationLanguage(from row: [String: Any]) -> String {
        if let language = string(in: row, keys: ["language", "languageCode", "lang"])?.lowercased(),
           !language.isEmpty {
            return normalizeLanguageCode(language)
        }
        if let nested = row["language"] as? [String: Any] {
            let code = (string(in: nested, keys: ["code", "language", "locale", "name"]) ?? "").lowercased()
            return normalizeLanguageCode(code)
        }
        if let nested = row["translations"] as? [String: Any] {
            let code = (string(in: nested, keys: ["language", "languageCode", "lang"]) ?? "").lowercased()
            return normalizeLanguageCode(code)
        }
        return ""
    }

    private func normalizeLanguageCode(_ code: String) -> String {
        let lower = code.lowercased()
        switch lower {
        case "en", "eng", "en-us", "en-gb", "english":
            return "en"
        case "ja", "jpn", "ja-jp", "japanese":
            return "ja"
        case "es", "spa", "es-es", "spanish":
            return "spa"
        case "fr", "fra", "fr-fr", "french":
            return "fra"
        case "de", "deu", "de-de", "german":
            return "deu"
        case "it", "ita", "it-it", "italian":
            return "ita"
        case "pt", "por", "pt-br", "portuguese":
            return "por"
        case "zh", "zho", "zh-cn", "zh-tw", "chinese":
            return "zh"
        case "ko", "kor", "ko-kr", "korean":
            return "ko"
        default:
            return lower
        }
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
        if string.hasPrefix("/") {
            return URL(string: "https://artworks.thetvdb.com\(string)")
        }
        if !string.contains("://") {
            return URL(string: "https://artworks.thetvdb.com/\(string)")
        }
        return URL(string: string)
    }

    private func yearFrom(_ dateString: String?) -> Int? {
        guard let dateString, dateString.count >= 4 else { return nil }
        return Int(dateString.prefix(4))
    }
}
