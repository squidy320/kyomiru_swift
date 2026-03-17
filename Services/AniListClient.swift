import Foundation

enum AniListError: Error {
    case invalidResponse
    case graphQLError(String)
    case invalidToken
}

final class AniListClient {
    private let endpoint = URL(string: "https://graphql.anilist.co")!
    private let cacheStore: CacheStore
    private let session: URLSession
    private var cachedTrending: (items: [AniListMedia], expires: Date)?
    private var cachedDiscoverySections: (sort: String, items: [AniListDiscoverySection], expires: Date)?
    private var cachedLibrarySections: (items: [AniListLibrarySection], expires: Date)?
    private var cachedTrackingEntries: [Int: (entry: AniListTrackingEntry?, expires: Date)] = [:]
    private var cachedAvailability: [Int: (entry: AniListEpisodeAvailability?, expires: Date)] = [:]
    private let requestGate = RequestGate(maxConcurrent: 4)

    init(cacheStore: CacheStore, session: URLSession = .custom) {
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
        if let cached = cachedTrendingFromDisk() {
            AppLog.debug(.cache, "trending disk cache hit")
            cachedTrending = (cached, Date().addingTimeInterval(60 * 10))
            return cached
        }
        AppLog.debug(.network, "trending request start")
        let query = """
        query Trending {
          Page(page: 1, perPage: 20) {
            media(type: ANIME, sort: TRENDING_DESC) {
              id
              idMal
              title { romaji english native }
              coverImage { extraLarge large }
              bannerImage
              averageScore
              episodes
              seasonYear
              startDate { year month day }
              format
              status
              isAdult
              genres
              studios(isMain: true) { nodes { name } }
            }
          }
        }
        """
        let data = try await graphql(query: query)
        let items = decodeMediaList(data: data, keyPath: ["data", "Page", "media"])
        cacheStore.writeJSON(data, forKey: "discovery:trending")
        cachedTrending = (items, Date().addingTimeInterval(60 * 10))
        AppLog.debug(.network, "trending request success count=\(items.count)")
        return items
    }

func discoverySections(sort: String, forceRefresh: Bool = false) async throws -> [AniListDiscoverySection] {
    if !forceRefresh {
        if let cached = cachedDiscoverySections, cached.expires > Date(), cached.sort == sort {
            AppLog.debug(.cache, "discovery sections cache hit")
            return cached.items
        }
        if let cached = cachedDiscoverySectionsFromDisk(sort: sort) {
            AppLog.debug(.cache, "discovery sections disk cache hit")
            cachedDiscoverySections = (sort, cached, Date().addingTimeInterval(60 * 10))
            return cached
        }
    } else {
        AppLog.debug(.cache, "discovery sections cache bypass")
    }
    AppLog.debug(.network, "discovery sections request start")

    let mediaFields = """
          id
          idMal
          title { romaji english native }
          coverImage { extraLarge large }
          bannerImage
          averageScore
          episodes
          seasonYear
          startDate { year month day }
          format
          status
          isAdult
          genres
          studios(isMain: true) { nodes { name } }
    """
    let (seasonValue, seasonYear) = currentSeasonAndYear()
    let baseQuery = """
        query DiscoveryBase {
          trending: Page(page: 1, perPage: 12) { media(type: ANIME, sort: TRENDING_DESC, isAdult: false) { \(mediaFields) } }
          hotNow: Page(page: 1, perPage: 12) { media(type: ANIME, sort: POPULARITY_DESC, isAdult: false, season: \(seasonValue), seasonYear: \(seasonYear)) { \(mediaFields) } }
          upcoming: Page(page: 1, perPage: 12) { media(type: ANIME, sort: START_DATE, isAdult: false, status: NOT_YET_RELEASED) { \(mediaFields) } }
          allTime: Page(page: 1, perPage: 12) { media(type: ANIME, sort: SCORE_DESC, isAdult: false) { \(mediaFields) } }
        }
        """

    let baseSections = [
        ("trending", "Trending"),
        ("hotNow", "Popular This Season"),
        ("upcoming", "Upcoming"),
        ("allTime", "All Time")
    ]

    var sections: [AniListDiscoverySection] = []
    sections += try await loadDiscoveryBatch(
        sort: sort,
        batch: "base",
        query: baseQuery,
        variables: [:],
        sectionDefs: baseSections
    )

    cachedDiscoverySections = (sort, sections, Date().addingTimeInterval(60 * 10))
    AppLog.debug(.network, "discovery sections request success count=\(sections.count)")
    return sections
}

func librarySections(token: String, forceRefresh: Bool = false) async throws -> [AniListLibrarySection] {
        if !forceRefresh {
            if let cached = cachedLibrarySections, cached.expires > Date() {
                AppLog.debug(.cache, "library cache hit")
                return cached.items
            }
            if let cached = cachedLibrarySectionsFromDisk(token: token) {
                AppLog.debug(.cache, "library disk cache hit")
                cachedLibrarySections = (cached, Date().addingTimeInterval(60 * 5))
                return cached
            }
        } else {
            AppLog.debug(.cache, "library cache bypass")
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
              idMal
              title { romaji english native }
                  coverImage { extraLarge large }
                  bannerImage
                  averageScore
                  episodes
                  seasonYear
                  startDate { year month day }
                  format
                  status
                  isAdult
                  genres
                  studios(isMain: true) { nodes { name } }
                }
              }
            }
          }
        }
        """
        let data = try await graphql(query: query, variables: ["userId": viewer.id], token: token)
        let sections = decodeLibrarySections(data: data)
        cacheStore.writeJSON(data, forKey: "library:\(token.prefix(8))")
        cachedLibrarySections = (sections, Date().addingTimeInterval(60 * 5))
        AppLog.debug(.network, "library request success count=\(sections.count)")
        return sections
    }

    func searchAnime(query: String) async throws -> [AniListMedia] {
        AppLog.debug(.network, "search request start query=\(query)")
        let q = """
        query Search($search: String) {
          Page(page: 1, perPage: 10) {
            media(type: ANIME, search: $search, sort: SEARCH_MATCH) {
              id
              idMal
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
              studios(isMain: true) { nodes { name } }
            }
          }
        }
        """
        let data = try await graphql(query: q, variables: ["search": query])
        let items = decodeMediaList(data: data, keyPath: ["data", "Page", "media"])
        AppLog.debug(.network, "search request success count=\(items.count)")
        return items
    }

    func searchAnimeByTitle(_ title: String) async throws -> AniListMedia? {
        let titleResults = try await searchAnime(query: title)
        return titleResults.first
    }

    func discoverySectionItems(
        sectionId: String,
        sort: String,
        page: Int,
        perPage: Int = 30
    ) async throws -> [AniListMedia] {
        let (sortValue, filterClause) = discoverySectionQueryConfig(sectionId: sectionId, sort: sort)
        let query = """
        query DiscoverySection($page: Int, $perPage: Int) {
          Page(page: $page, perPage: $perPage) {
            media(type: ANIME, sort: \(sortValue), isAdult: false\(filterClause)) {
              id
              idMal
              title { romaji english native }
              coverImage { extraLarge large }
              bannerImage
              averageScore
              episodes
              seasonYear
              startDate { year month day }
              format
              status
              isAdult
              genres
              studios(isMain: true) { nodes { name } }
            }
          }
        }
        """
        let data = try await graphql(query: query, variables: ["page": page, "perPage": perPage])
        return decodeMediaList(data: data, keyPath: ["data", "Page", "media"])
    }

    func browseMedia(
        filters: BrowseFilterState,
        page: Int,
        perPage: Int = 30
    ) async throws -> [AniListMedia] {
        let cacheKey = "browse:\(filters.cacheKey):p\(page)"
        if let data = cacheStore.readJSON(forKey: cacheKey, maxAge: 60 * 10) {
            return decodeMediaList(data: data, keyPath: ["data", "Page", "media"])
        }

        let sortValue = aniListSort(for: filters.sort)
        let query = """
        query Browse($page: Int, $perPage: Int, $genre: [String], $tag: [String], $format: MediaFormat, $season: MediaSeason, $year: Int) {
          Page(page: $page, perPage: $perPage) {
            media(type: ANIME, sort: [\(sortValue)], isAdult: false, genre_in: $genre, tag_in: $tag, format: $format, season: $season, seasonYear: $year) {
              id
              idMal
              title { romaji english native }
              coverImage { extraLarge large }
              bannerImage
              averageScore
              episodes
              seasonYear
              startDate { year month day }
              format
              status
              isAdult
              genres
              studios(isMain: true) { nodes { name } }
            }
          }
        }
        """

        var variables: [String: Any] = ["page": page, "perPage": perPage]
        if let genre = filters.genre { variables["genre"] = [genre] }
        if let tag = filters.tag { variables["tag"] = [tag] }
        if let format = filters.format { variables["format"] = aniListFormat(for: format) }
        if let season = filters.season { variables["season"] = aniListSeason(for: season) }
        if let year = filters.year { variables["year"] = year }

        let data = try await graphql(query: query, variables: variables)
        cacheStore.writeJSON(data, forKey: cacheKey)
        return decodeMediaList(data: data, keyPath: ["data", "Page", "media"])
    }

    func cachedDiscoverySectionsSnapshot(sort: String) -> [AniListDiscoverySection]? {
        cachedDiscoverySectionsFromDisk(sort: sort)
    }

    func cachedLibrarySections(token: String) -> [AniListLibrarySection]? {
        cachedLibrarySectionsFromDisk(token: token)
    }

    func clearLibraryCache(token: String) {
        cachedLibrarySections = nil
        let key = "library:\(token.prefix(8))"
        cacheStore.remove(key: key)
        AppLog.debug(.cache, "library cache cleared key=\(key)")
    }

    private func cachedTrendingFromDisk() -> [AniListMedia]? {
        guard let data = cacheStore.readJSON(forKey: "discovery:trending") else { return nil }
        return decodeMediaList(data: data, keyPath: ["data", "Page", "media"])
    }

    private func discoverySectionQueryConfig(sectionId: String, sort: String) -> (String, String) {
        let fixedSort: String? = {
            switch sectionId {
            case "trending":
                return "TRENDING_DESC"
            case "hotNow":
                return "POPULARITY_DESC"
            case "upcoming":
                return "START_DATE"
            case "allTime":
                return "SCORE_DESC"
            default:
                return nil
            }
        }()
        let sortValue = "[\(fixedSort ?? sort)]"

        let genreMap: [String: String] = [
            "action": "Action",
            "adventure": "Adventure",
            "comedy": "Comedy",
            "drama": "Drama",
            "ecchi": "Ecchi",
            "fantasy": "Fantasy",
            "horror": "Horror",
            "mahouShoujo": "Mahou Shoujo",
            "mecha": "Mecha",
            "music": "Music",
            "mystery": "Mystery",
            "psychological": "Psychological",
            "romance": "Romance",
            "sciFi": "Sci-Fi",
            "sliceOfLife": "Slice of Life",
            "sports": "Sports",
            "supernatural": "Supernatural",
            "thriller": "Thriller"
        ]

        let tagMap: [String: String] = [
            "shounen": "Shounen",
            "shoujo": "Shoujo",
            "seinen": "Seinen",
            "josei": "Josei",
            "isekai": "Isekai"
        ]

        if sectionId == "hotNow" {
            let (seasonValue, seasonYear) = currentSeasonAndYear()
            return (sortValue, ", season: \(seasonValue), seasonYear: \(seasonYear)")
        }
        if sectionId == "upcoming" {
            return (sortValue, ", status: NOT_YET_RELEASED")
        }
        if let genre = genreMap[sectionId] {
            return (sortValue, ", genre_in: [\"" + genre + "\"]")
        }
        if let tag = tagMap[sectionId] {
            return (sortValue, ", tag_in: [\"" + tag + "\"]")
        }
        return (sortValue, "")
    }

    private func aniListSort(for sort: BrowseSortOption) -> String {
        switch sort {
        case .trending:
            return "TRENDING_DESC"
        case .score:
            return "SCORE_DESC"
        case .popularity:
            return "POPULARITY_DESC"
        case .title:
            return "TITLE_ROMAJI"
        }
    }

    private func aniListFormat(for format: BrowseFormat) -> String {
        switch format {
        case .TV: return "TV"
        case .Movie: return "MOVIE"
        case .OVA: return "OVA"
        case .ONA: return "ONA"
        case .Special: return "SPECIAL"
        }
    }

    private func aniListSeason(for season: BrowseSeason) -> String {
        switch season {
        case .Winter: return "WINTER"
        case .Spring: return "SPRING"
        case .Summer: return "SUMMER"
        case .Fall: return "FALL"
        }
    }

    private func currentSeasonAndYear() -> (season: String, year: Int) {
        let calendar = Calendar.current
        let now = Date()
        let month = calendar.component(.month, from: now)
        var year = calendar.component(.year, from: now)
        let season: String
        switch month {
        case 12:
            season = "WINTER"
            year += 1
        case 1...2:
            season = "WINTER"
        case 3...5:
            season = "SPRING"
        case 6...8:
            season = "SUMMER"
        default:
            season = "FALL"
        }
        return (season, year)
    }

private func cachedDiscoverySectionsFromDisk(sort: String) -> [AniListDiscoverySection]? {
    let batches = ["base"]
    var sections: [AniListDiscoverySection] = []
    for batch in batches {
        let cacheKey = discoverySectionsCacheKey(batch: batch, sort: sort)
        guard let data = cacheStore.readJSON(forKey: cacheKey) else { continue }
        sections += decodeDiscoveryBatch(data: data, batch: batch)
    }
    return sections.isEmpty ? nil : sections
}

private func discoverySectionsCacheKey(batch: String, sort: String) -> String {
    let suffix: String
    switch sort {
    case "TRENDING_DESC":
        suffix = "trending"
    case "SCORE_DESC":
        suffix = "score"
    case "TITLE_ROMAJI":
        suffix = "title"
    default:
        suffix = sort.lowercased()
    }
    return "discovery:sections:\(batch):\(suffix)"
}

private func loadDiscoveryBatch(
    sort: String,
    batch: String,
    query: String,
    variables: [String: Any],
    sectionDefs: [(id: String, title: String)]
) async throws -> [AniListDiscoverySection] {
    let cacheKey = discoverySectionsCacheKey(batch: batch, sort: sort)
    if let data = cacheStore.readJSON(forKey: cacheKey) {
        return decodeDiscoveryBatch(data: data, batch: batch)
    }
    let data = try await graphql(query: query, variables: variables)
    cacheStore.writeJSON(data, forKey: cacheKey)
    return sectionDefs.map { def in
        AniListDiscoverySection(
            id: def.id,
            title: def.title,
            items: decodeMediaList(data: data, keyPath: ["data", def.id, "media"])
        )
    }
}

private func decodeDiscoveryBatch(data: Data, batch: String) -> [AniListDiscoverySection] {
    let sectionDefs: [(id: String, title: String)]
    switch batch {
    case "base":
        sectionDefs = [
            ("trending", "Trending"),
            ("topRated", "Top Rated"),
            ("hotNow", "Hot Now")
        ]
    case "genresA":
        sectionDefs = [
            ("action", "Top Action"),
            ("adventure", "Top Adventure"),
            ("comedy", "Top Comedy"),
            ("drama", "Top Drama"),
            ("fantasy", "Top Fantasy"),
            ("romance", "Top Romance"),
            ("sciFi", "Top Sci-Fi"),
            ("sliceOfLife", "Top Slice of Life")
        ]
    case "genresB":
        sectionDefs = [
            ("horror", "Top Horror"),
            ("mystery", "Top Mystery"),
            ("psychological", "Top Psychological"),
            ("supernatural", "Top Supernatural"),
            ("thriller", "Top Thriller"),
            ("sports", "Top Sports"),
            ("music", "Top Music"),
            ("mecha", "Top Mecha"),
            ("mahouShoujo", "Top Mahou Shoujo"),
            ("ecchi", "Top Ecchi")
        ]
    default:
        sectionDefs = [
            ("shounen", "Top Shounen"),
            ("shoujo", "Top Shoujo"),
            ("seinen", "Top Seinen"),
            ("josei", "Top Josei"),
            ("isekai", "Top Isekai")
        ]
    }
    return sectionDefs.map { def in
        AniListDiscoverySection(
            id: def.id,
            title: def.title,
            items: decodeMediaList(data: data, keyPath: ["data", def.id, "media"])
        )
    }
}

private func cachedLibrarySectionsFromDisk(token: String) -> [AniListLibrarySection]? {
        let key = "library:\(token.prefix(8))"
        guard let data = cacheStore.readJSON(forKey: key) else { return nil }
        return decodeLibrarySections(data: data)
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

    func saveMediaListEntry(
        token: String,
        mediaId: Int,
        status: String?,
        progress: Int?
    ) async throws -> Bool {
        AppLog.debug(.network, "save list start mediaId=\(mediaId) status=\(status ?? "nil") progress=\(progress.map(String.init) ?? "nil")")
        let q = """
        mutation SaveEntry($mediaId: Int, $status: MediaListStatus, $progress: Int) {
          SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress) {
            id
            status
            progress
          }
        }
        """
        var vars: [String: Any] = ["mediaId": mediaId]
        if let status {
            vars["status"] = status
        } else {
            vars["status"] = NSNull()
        }
        if let progress {
            vars["progress"] = progress
        } else {
            vars["progress"] = NSNull()
        }
        let data = try await graphql(query: q, variables: vars, token: token)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataMap = root["data"] as? [String: Any],
              let _ = dataMap["SaveMediaListEntry"] as? [String: Any] else {
            AppLog.error(.network, "save list failed mediaId=\(mediaId)")
            return false
        }
        AppLog.debug(.network, "save list success mediaId=\(mediaId)")
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
                contexts
                media {
                  id
              idMal
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
            let contexts = row["contexts"] as? [String] ?? []
            let context = contexts.isEmpty ? nil : contexts.joined(separator: "\n")
            let media = (row["media"] as? [String: Any]).flatMap(decodeMedia)
            return AniListNotificationItem(id: id, type: type, createdAt: createdAt, context: context, media: media)
        }
        AppLog.debug(.network, "notifications request success count=\(items.count)")
        return items
    }

    func trackingEntry(token: String, mediaId: Int) async throws -> AniListTrackingEntry? {
        if let cached = cachedTrackingEntries[mediaId], cached.expires > Date() {
            return cached.entry
        }
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
        let data: Data
        do {
            data = try await graphql(query: query, variables: ["mediaId": mediaId, "userId": viewer.id], token: token)
        } catch let AniListError.graphQLError(message) where message == "Not Found." {
            cachedTrackingEntries[mediaId] = (nil, Date().addingTimeInterval(60 * 5))
            return nil
        }
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
        cachedTrackingEntries[mediaId] = (entry, Date().addingTimeInterval(60 * 5))
        AppLog.debug(.network, "tracking entry success mediaId=\(mediaId)")
        return entry
    }

    func episodeAvailability(token: String, mediaId: Int) async throws -> AniListEpisodeAvailability? {
        if let cached = cachedAvailability[mediaId], cached.expires > Date() {
            return cached.entry
        }
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
        cachedAvailability[mediaId] = (availability, Date().addingTimeInterval(60 * 5))
        AppLog.debug(.network, "episode availability success mediaId=\(mediaId)")
        return availability
    }

    func relatedSections(mediaId: Int, token: String? = nil) async throws -> [AniListRelatedSection] {
        AppLog.debug(.network, "related sections request start mediaId=\(mediaId)")
        let query = """
        query Related($id: Int) {
          Media(id: $id, type: ANIME) {
            relations {
              edges {
                relationType
                node {
                  id
              idMal
              title { romaji english native }
                  coverImage { extraLarge large }
                  bannerImage
                  averageScore
                  episodes
                  seasonYear
                  startDate { year month day }
                  format
                  status
                  isAdult
                  genres
                  studios(isMain: true) { nodes { name } }
                }
              }
            }
          }
        }
        """
        let data = try await graphql(query: query, variables: ["id": mediaId], token: token)
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let edges = traverse(root, keyPath: ["data", "Media", "relations", "edges"]) as? [[String: Any]] {
            var map: [String: [AniListMedia]] = [:]
            for edge in edges {
                guard let relation = edge["relationType"] as? String,
                      let node = edge["node"] as? [String: Any],
                      let media = decodeMedia(node) else { continue }
                map[relation, default: []].append(media)
            }
            let sections = map.map { relation, items in
                AniListRelatedSection(
                    id: relation.lowercased(),
                    title: relation.replacingOccurrences(of: "_", with: " ").capitalized,
                    items: items
                )
            }
            if !sections.isEmpty {
                AppLog.debug(.network, "related sections request success mediaId=\(mediaId) count=\(sections.count)")
                return sections
            }
        } else {
            AppLog.error(.network, "related sections decode failed mediaId=\(mediaId)")
        }

        let fallbackQuery = """
        query RelatedFallback($id: Int) {
          Media(id: $id, type: ANIME) {
            relations {
              nodes {
                id
                idMal
                title { romaji english native }
                coverImage { extraLarge large }
                bannerImage
                averageScore
                episodes
                seasonYear
                startDate { year month day }
                format
                status
                isAdult
                genres
                studios(isMain: true) { nodes { name } }
              }
            }
          }
        }
        """
        let fallbackData = try await graphql(query: fallbackQuery, variables: ["id": mediaId], token: token)
        guard let fallbackRoot = try? JSONSerialization.jsonObject(with: fallbackData) as? [String: Any],
              let nodes = traverse(fallbackRoot, keyPath: ["data", "Media", "relations", "nodes"]) as? [[String: Any]] else {
            AppLog.error(.network, "related sections fallback decode failed mediaId=\(mediaId)")
            return []
        }
        let items = nodes.compactMap { decodeMedia($0) }
        let sections = items.isEmpty ? [] : [
            AniListRelatedSection(id: "related", title: "Related", items: items)
        ]
        AppLog.debug(.network, "related sections fallback success mediaId=\(mediaId) count=\(sections.count)")
        return sections
    }

    func relationsGraph(mediaId: Int, token: String? = nil) async throws -> [AniListRelationEdge] {
        let query = """
        query RelationGraph($id: Int) {
          Media(id: $id, type: ANIME) {
            relations {
              edges {
                relationType
                node {
                  id
                  idMal
                  title { romaji english native }
                  coverImage { extraLarge large }
                  bannerImage
                  averageScore
                  episodes
                  seasonYear
                  startDate { year month day }
                  format
                  status
                  isAdult
                  genres
                  studios(isMain: true) { nodes { name } }
                }
              }
            }
          }
        }
        """
        let data = try await graphql(query: query, variables: ["id": mediaId], token: token)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let edges = traverse(root, keyPath: ["data", "Media", "relations", "edges"]) as? [[String: Any]] else {
            AppLog.error(.network, "relations graph decode failed mediaId=\(mediaId)")
            return []
        }
        var result: [AniListRelationEdge] = []
        for edge in edges {
            guard let relation = edge["relationType"] as? String,
                  let node = edge["node"] as? [String: Any],
                  let media = decodeMedia(node) else { continue }
            result.append(AniListRelationEdge(relationType: relation, media: media))
        }
        return result
    }

    func streamingEpisodes(mediaId: Int) async throws -> [AniListStreamingEpisode] {
        AppLog.debug(.network, "streaming episodes request start mediaId=\(mediaId)")
        let query = """
        query StreamingEpisodes($id: Int) {
          Media(id: $id, type: ANIME) {
            streamingEpisodes {
              title
              thumbnail
              url
            }
          }
        }
        """
        let data = try await graphql(query: query, variables: ["id": mediaId])
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = traverse(root, keyPath: ["data", "Media", "streamingEpisodes"]) as? [[String: Any]] else {
            AppLog.error(.network, "streaming episodes decode failed mediaId=\(mediaId)")
            return []
        }
        let episodes = list.map { row -> AniListStreamingEpisode in
            let title = row["title"] as? String ?? "Episode"
            let thumb = row["thumbnail"] as? String
            let url = row["url"] as? String
            let number = extractEpisodeNumber(from: title) ?? extractEpisodeNumber(from: url)
            return AniListStreamingEpisode(
                title: title,
                thumbnailURL: thumb.flatMap(URL.init(string:)),
                url: url.flatMap(URL.init(string:)),
                episodeNumber: number
            )
        }
        AppLog.debug(.network, "streaming episodes request success mediaId=\(mediaId) count=\(episodes.count)")
        return episodes
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
        await requestGate.acquire()
        defer { Task { await self.requestGate.release() } }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        AppLog.debug(.network, "graphql request start")
        let body: [String: Any] = ["query": query, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse) = try await NetworkRetry.withRetries(
            label: "anilist-graphql",
            attempts: 5,
            baseDelay: 1.0
        ) { [self] in
            let (data, response) = try await self.session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 500 || http.statusCode == 429 {
                throw URLError(.badServerResponse)
            }
            return (data, response)
        }
        guard let http = response as? HTTPURLResponse else {
            AppLog.error(.network, "graphql invalid response")
            throw AniListError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            AppLog.error(.network, "graphql invalid token http=\(http.statusCode)")
            NotificationCenter.default.post(name: .aniListInvalidToken, object: nil)
            throw AniListError.invalidToken
        }
        guard http.statusCode < 500 else {
            AppLog.error(.network, "graphql invalid response")
            throw AniListError.invalidResponse
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errors = root["errors"] as? [[String: Any]],
           let message = errors.first?["message"] as? String {
            AppLog.error(.network, "graphql error \(message)")
            if message.lowercased().contains("invalid token") {
                NotificationCenter.default.post(name: .aniListInvalidToken, object: nil)
                throw AniListError.invalidToken
            }
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
        let idMal = media["idMal"] as? Int
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
        let startDateMap = media["startDate"] as? [String: Any]
        let startDate = AniListFuzzyDate(
            year: startDateMap?["year"] as? Int,
            month: startDateMap?["month"] as? Int,
            day: startDateMap?["day"] as? Int
        )
        let format = media["format"] as? String
        let status = media["status"] as? String
        let isAdult = media["isAdult"] as? Bool ?? false
        let genres = media["genres"] as? [String] ?? []
        let studios = ((media["studios"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        return AniListMedia(
            id: id,
            idMal: idMal,
            title: title,
            coverURL: cover.flatMap(URL.init(string:)),
            bannerURL: banner.flatMap(URL.init(string:)),
            averageScore: score,
            episodes: episodes,
            seasonYear: seasonYear,
            startDate: startDate,
            format: format,
            status: status,
            isAdult: isAdult,
            genres: genres,
            studios: studios
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

    private func extractEpisodeNumber(from text: String?) -> Int? {
        guard let text else { return nil }
        let digits = text.split { !$0.isNumber }.compactMap { Int($0) }
        return digits.first
    }
}

actor RequestGate {
    private let maxConcurrent: Int
    private var current: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func acquire() async {
        if current < maxConcurrent {
            current += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        current += 1
    }

    func release() {
        if !waiters.isEmpty {
            current = max(0, current - 1)
            let next = waiters.removeFirst()
            next.resume()
        } else {
            current = max(0, current - 1)
        }
    }
}

extension Notification.Name {
    static let aniListInvalidToken = Notification.Name("AniListInvalidToken")
}



