import Foundation

enum AniListError: Error {
    case invalidResponse
    case graphQLError(String)
}

final class AniListClient {
    private let endpoint = URL(string: "https://graphql.anilist.co")!
    private let cacheStore: CacheStore
    private let session: URLSession
    private var cachedTrending: (items: [AniListMedia], expires: Date)?
    private var cachedDiscoverySections: (items: [AniListDiscoverySection], expires: Date)?
    private var cachedLibrarySections: (items: [AniListLibrarySection], expires: Date)?

    init(cacheStore: CacheStore, session: URLSession = .shared) {
        self.cacheStore = cacheStore
        self.session = session
    }

    func viewer(token: String) async throws -> AniListUser {
        let cacheKey = "viewer:\(token.prefix(8))"
        if let data = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 10),
           let user = decodeViewer(data: data) {
            AppLog.debug(.cache, "viewer cache hit")
            return user
        }
        AppLog.debug(.network, "viewer request start")
        let query = """
        query Viewer {
          Viewer {
            id
            name
            avatar { large }
            bannerImage
          }
        }
        """
        let data = try await graphql(query: query, token: token)
        cacheStore.writeJSON(data, forKey: cacheKey)
        guard let user = decodeViewer(data: data) else {
            AppLog.error(.network, "viewer decode failed")
            throw AniListError.invalidResponse
        }
        AppLog.debug(.network, "viewer request success")
        return user
    }

    func discoveryTrending() async throws -> [AniListMedia] {
        if let cached = cachedTrending, cached.expires > Date() {
            AppLog.debug(.cache, "trending cache hit")
            return cached.items
        }
        AppLog.debug(.network, "trending request start")
        let query = """
        query Trending {
          Page(page: 1, perPage: 20) {
            media(type: ANIME, sort: TRENDING_DESC) {
              id
              title { romaji english native }
              coverImage { extraLarge large }
              bannerImage
              averageScore
              episodes
              seasonYear
              format
              status
              isAdult
              genres
            }
          }
        }
        """
        let data = try await graphql(query: query)
        let items = decodeMediaList(data: data, keyPath: ["data", "Page", "media"])
        cachedTrending = (items, Date().addingTimeInterval(60 * 10))
        AppLog.debug(.network, "trending request success count=\(items.count)")
        return items
    }

    func discoverySections() async throws -> [AniListDiscoverySection] {
        if let cached = cachedDiscoverySections, cached.expires > Date() {
            AppLog.debug(.cache, "discovery sections cache hit")
            return cached.items
        }
        AppLog.debug(.network, "discovery sections request start")
        let query = """
        query Discovery {
          trending: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: TRENDING_DESC) {
              id
              title { romaji english native }
              coverImage { extraLarge large }
              bannerImage
              averageScore
              episodes
              seasonYear
              format
              status
              isAdult
              genres
            }
          }
          topRated: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: SCORE_DESC) {
              id
              title { romaji english native }
              coverImage { extraLarge large }
              bannerImage
              averageScore
              episodes
              seasonYear
              format
              status
              isAdult
              genres
            }
          }
          hotNow: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: POPULARITY_DESC) {
              id
              title { romaji english native }
              coverImage { extraLarge large }
              bannerImage
              averageScore
              episodes
              seasonYear
              format
              status
              isAdult
              genres
            }
          }
        }
        """
        let data = try await graphql(query: query)
        let sections: [AniListDiscoverySection] = [
            AniListDiscoverySection(
                id: "trending",
                title: "Trending",
                items: decodeMediaList(data: data, keyPath: ["data", "trending", "media"])
            ),
            AniListDiscoverySection(
                id: "topRated",
                title: "Top Rated",
                items: decodeMediaList(data: data, keyPath: ["data", "topRated", "media"])
            ),
            AniListDiscoverySection(
                id: "hotNow",
                title: "Hot Now",
                items: decodeMediaList(data: data, keyPath: ["data", "hotNow", "media"])
            )
        ]
        cachedDiscoverySections = (sections, Date().addingTimeInterval(60 * 10))
        AppLog.debug(.network, "discovery sections request success count=\(sections.count)")
        return sections
    }

    func librarySections(token: String) async throws -> [AniListLibrarySection] {
        if let cached = cachedLibrarySections, cached.expires > Date() {
            AppLog.debug(.cache, "library cache hit")
            return cached.items
        }
        AppLog.debug(.network, "library request start")
        let viewer = try await viewer(token: token)
        let query = """
        query Library($userId: Int) {
          MediaListCollection(userId: $userId, type: ANIME) {
            lists {
              name
              entries {
                id
                progress
                media {
                  id
                  title { romaji english native }
                  coverImage { extraLarge large }
                  bannerImage
                  averageScore
                  episodes
                  seasonYear
                  format
                  status
                  isAdult
                  genres
                }
              }
            }
          }
        }
        """
        let data = try await graphql(query: query, variables: ["userId": viewer.id], token: token)
        let sections = decodeLibrarySections(data: data)
        cachedLibrarySections = (sections, Date().addingTimeInterval(60 * 5))
        AppLog.debug(.network, "library request success count=\(sections.count)")
        return sections
    }

    func searchAnime(query: String) async throws -> [AniListMedia] {
        AppLog.debug(.network, "search request start query=\(query, privacy: .public)")
        let q = """
        query Search($search: String) {
          Page(page: 1, perPage: 10) {
            media(type: ANIME, search: $search, sort: SEARCH_MATCH) {
              id
              title { romaji english native }
              coverImage { extraLarge large }
              bannerImage
              averageScore
              episodes
              seasonYear
              format
              status
              isAdult
              genres
            }
          }
        }
        """
        let data = try await graphql(query: q, variables: ["search": query])
        let items = decodeMediaList(data: data, keyPath: ["data", "Page", "media"])
        AppLog.debug(.network, "search request success count=\(items.count)")
        return items
    }

    func saveTrackingEntry(token: String, mediaId: Int, progress: Int) async throws -> Bool {
        AppLog.debug(.network, "save tracking start mediaId=\(mediaId) progress=\(progress)")
        let q = """
        mutation SaveProgress($mediaId: Int, $progress: Int) {
          SaveMediaListEntry(mediaId: $mediaId, progress: $progress) {
            id
          }
        }
        """
        let data = try await graphql(query: q, variables: ["mediaId": mediaId, "progress": progress], token: token)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataMap = root["data"] as? [String: Any],
              let _ = dataMap["SaveMediaListEntry"] as? [String: Any] else {
            AppLog.error(.network, "save tracking failed mediaId=\(mediaId)")
            return false
        }
        AppLog.debug(.network, "save tracking success mediaId=\(mediaId)")
        return true
    }

    func notifications(token: String) async throws -> [AniListNotificationItem] {
        AppLog.debug(.network, "notifications request start")
        let q = """
        query Notifications {
          Page(page: 1, perPage: 30) {
            notifications(type_in: [AIRING, RELATED_MEDIA_ADDITION, MEDIA_DATA_CHANGE, MEDIA_MERGE]) {
              __typename
              ... on AiringNotification {
                id
                type
                createdAt
                context
                media {
                  id
                  title { romaji english native }
                  coverImage { extraLarge large }
                  bannerImage
                  averageScore
                  episodes
                  seasonYear
                  format
                  status
                  isAdult
                  genres
                }
              }
            }
          }
        }
        """
        let data = try await graphql(query: q, token: token)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let page = traverse(root, keyPath: ["data", "Page", "notifications"]) as? [[String: Any]] else {
            AppLog.error(.network, "notifications decode failed")
            return []
        }
        let items = page.compactMap { row in
            let id = row["id"] as? Int ?? 0
            let type = row["type"] as? String ?? ""
            let createdAt = row["createdAt"] as? Int ?? 0
            let context = row["context"] as? String
            let media = (row["media"] as? [String: Any]).flatMap(decodeMedia)
            return AniListNotificationItem(id: id, type: type, createdAt: createdAt, context: context, media: media)
        }
        AppLog.debug(.network, "notifications request success count=\(items.count)")
        return items
    }

    func trackingEntry(token: String, mediaId: Int) async throws -> AniListTrackingEntry? {
        AppLog.debug(.network, "tracking entry start mediaId=\(mediaId)")
        let viewer = try await viewer(token: token)
        let query = """
        query TrackingEntry($mediaId: Int, $userId: Int) {
          MediaList(mediaId: $mediaId, type: ANIME, userId: $userId) {
            id
            status
            progress
            score
          }
        }
        """
        let data = try await graphql(query: query, variables: ["mediaId": mediaId, "userId": viewer.id], token: token)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataMap = root["data"] as? [String: Any],
              let row = dataMap["MediaList"] as? [String: Any] else {
            AppLog.error(.network, "tracking entry decode failed mediaId=\(mediaId)")
            return nil
        }
        let id = row["id"] as? Int ?? 0
        let status = row["status"] as? String
        let progress = row["progress"] as? Int
        let score = row["score"] as? Double ?? (row["score"] as? Int).map(Double.init)
        let entry = AniListTrackingEntry(id: id, status: status, progress: progress, score: score)
        AppLog.debug(.network, "tracking entry success mediaId=\(mediaId)")
        return entry
    }

    func episodeAvailability(token: String, mediaId: Int) async throws -> AniListEpisodeAvailability? {
        AppLog.debug(.network, "episode availability start mediaId=\(mediaId)")
        let query = """
        query Availability($id: Int) {
          Media(id: $id, type: ANIME) {
            episodes
            status
            nextAiringEpisode { episode }
          }
        }
        """
        let data = try await graphql(query: query, variables: ["id": mediaId], token: token)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataMap = root["data"] as? [String: Any],
              let media = dataMap["Media"] as? [String: Any] else {
            AppLog.error(.network, "episode availability decode failed mediaId=\(mediaId)")
            return nil
        }
        let total = media["episodes"] as? Int ?? 0
        let status = media["status"] as? String
        let nextEpisode = (media["nextAiringEpisode"] as? [String: Any])?["episode"] as? Int
        let availability = AniListEpisodeAvailability(totalEpisodes: total, nextAiringEpisode: nextEpisode, status: status)
        AppLog.debug(.network, "episode availability success mediaId=\(mediaId)")
        return availability
    }

    private func decodeViewer(data: Data) -> AniListUser? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataMap = root["data"] as? [String: Any],
              let viewer = dataMap["Viewer"] as? [String: Any] else {
            return nil
        }
        let id = viewer["id"] as? Int ?? 0
        let name = viewer["name"] as? String ?? "User"
        let avatar = (viewer["avatar"] as? [String: Any])?["large"] as? String
        let banner = viewer["bannerImage"] as? String
        return AniListUser(
            id: id,
            name: name,
            avatarURL: avatar.flatMap(URL.init(string:)),
            bannerURL: banner.flatMap(URL.init(string:))
        )
    }

    private func graphql(query: String, variables: [String: Any] = [:], token: String? = nil) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        AppLog.debug(.network, "graphql request start")
        let body: [String: Any] = ["query": query, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 500 else {
            AppLog.error(.network, "graphql invalid response")
            throw AniListError.invalidResponse
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errors = root["errors"] as? [[String: Any]],
           let message = errors.first?["message"] as? String {
            AppLog.error(.network, "graphql error \(message, privacy: .public)")
            throw AniListError.graphQLError(message)
        }
        AppLog.debug(.network, "graphql request success status=\(http.statusCode)")
        return data
    }

    private func decodeMediaList(data: Data, keyPath: [String]) -> [AniListMedia] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mediaList = traverse(root, keyPath: keyPath) as? [[String: Any]] else {
            return []
        }
        return mediaList.compactMap(decodeMedia)
    }

    private func decodeLibrarySections(data: Data) -> [AniListLibrarySection] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lists = traverse(root, keyPath: ["data", "MediaListCollection", "lists"]) as? [[String: Any]] else {
            return []
        }
        return lists.compactMap { list in
            let name = list["name"] as? String ?? "Section"
            let entries = (list["entries"] as? [[String: Any]] ?? []).compactMap { entry -> AniListLibraryEntry? in
                let id = entry["id"] as? Int ?? 0
                let progress = entry["progress"] as? Int ?? 0
                guard let mediaMap = entry["media"] as? [String: Any],
                      let media = decodeMedia(mediaMap) else { return nil }
                return AniListLibraryEntry(id: id, progress: progress, media: media)
            }
            return AniListLibrarySection(id: name.lowercased().replacingOccurrences(of: " ", with: "-"), title: name, items: entries)
        }
    }

    private func decodeMedia(_ media: [String: Any]) -> AniListMedia? {
        let id = media["id"] as? Int ?? 0
        let titleMap = media["title"] as? [String: Any] ?? [:]
        let title = AniListTitle(
            romaji: titleMap["romaji"] as? String,
            english: titleMap["english"] as? String,
            native: titleMap["native"] as? String
        )
        let cover = (media["coverImage"] as? [String: Any])?["extraLarge"] as? String ??
            (media["coverImage"] as? [String: Any])?["large"] as? String
        let banner = media["bannerImage"] as? String
        let score = media["averageScore"] as? Int
        let episodes = media["episodes"] as? Int
        let seasonYear = media["seasonYear"] as? Int
        let format = media["format"] as? String
        let status = media["status"] as? String
        let isAdult = media["isAdult"] as? Bool ?? false
        let genres = media["genres"] as? [String] ?? []
        return AniListMedia(
            id: id,
            title: title,
            coverURL: cover.flatMap(URL.init(string:)),
            bannerURL: banner.flatMap(URL.init(string:)),
            averageScore: score,
            episodes: episodes,
            seasonYear: seasonYear,
            format: format,
            status: status,
            isAdult: isAdult,
            genres: genres
        )
    }

    private func traverse(_ root: [String: Any], keyPath: [String]) -> Any? {
        var current: Any? = root
        for key in keyPath {
            if let dict = current as? [String: Any] {
                current = dict[key]
            } else {
                return nil
            }
        }
        return current
    }
}

