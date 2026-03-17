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

    func discoverySections(sort: String) async throws -> [AniListDiscoverySection] {
        if let cached = cachedDiscoverySections, cached.expires > Date(), cached.sort == sort {
            AppLog.debug(.cache, "discovery sections cache hit")
            return cached.items
        }
        if let cached = cachedDiscoverySectionsFromDisk(sort: sort) {
            AppLog.debug(.cache, "discovery sections disk cache hit")
            cachedDiscoverySections = (sort, cached, Date().addingTimeInterval(60 * 10))
            return cached
        }
        AppLog.debug(.network, "discovery sections request start")
        let query = """
        query Discovery($sort: [MediaSort]) {
          trending: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, isAdult: false) {
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
          topRated: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, isAdult: false) {
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
          hotNow: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, isAdult: false) {
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
          action: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Action"], isAdult: false) {
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
          adventure: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Adventure"], isAdult: false) {
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
          comedy: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Comedy"], isAdult: false) {
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
          drama: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Drama"], isAdult: false) {
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
          ecchi: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Ecchi"], isAdult: false) {
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
          fantasy: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Fantasy"], isAdult: false) {
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
          horror: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Horror"], isAdult: false) {
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
          mahouShoujo: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Mahou Shoujo"], isAdult: false) {
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
          mecha: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Mecha"], isAdult: false) {
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
          music: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Music"], isAdult: false) {
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
          mystery: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Mystery"], isAdult: false) {
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
          psychological: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Psychological"], isAdult: false) {
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
          romance: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Romance"], isAdult: false) {
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
          sciFi: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Sci-Fi"], isAdult: false) {
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
          sliceOfLife: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Slice of Life"], isAdult: false) {
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
          sports: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Sports"], isAdult: false) {
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
          supernatural: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Supernatural"], isAdult: false) {
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
          thriller: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, genre_in: ["Thriller"], isAdult: false) {
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
          shounen: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, tag_in: ["Shounen"], isAdult: false) {
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
          shoujo: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, tag_in: ["Shoujo"], isAdult: false) {
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
          seinen: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, tag_in: ["Seinen"], isAdult: false) {
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
          josei: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, tag_in: ["Josei"], isAdult: false) {
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
          isekai: Page(page: 1, perPage: 12) {
            media(type: ANIME, sort: $sort, tag_in: ["Isekai"], isAdult: false) {
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
        let data = try await graphql(query: query, variables: ["sort": [sort]])
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
            ),
            AniListDiscoverySection(
                id: "action",
                title: "Top Action",
                items: decodeMediaList(data: data, keyPath: ["data", "action", "media"])
            )
            ,
            AniListDiscoverySection(
                id: "adventure",
                title: "Top Adventure",
                items: decodeMediaList(data: data, keyPath: ["data", "adventure", "media"])
            ),
            AniListDiscoverySection(
                id: "comedy",
                title: "Top Comedy",
                items: decodeMediaList(data: data, keyPath: ["data", "comedy", "media"])
            ),
            AniListDiscoverySection(
                id: "drama",
                title: "Top Drama",
                items: decodeMediaList(data: data, keyPath: ["data", "drama", "media"])
            ),
            AniListDiscoverySection(
                id: "ecchi",
                title: "Top Ecchi",
                items: decodeMediaList(data: data, keyPath: ["data", "ecchi", "media"])
            ),
            AniListDiscoverySection(
                id: "fantasy",
                title: "Top Fantasy",
                items: decodeMediaList(data: data, keyPath: ["data", "fantasy", "media"])
            ),
            AniListDiscoverySection(
                id: "horror",
                title: "Top Horror",
                items: decodeMediaList(data: data, keyPath: ["data", "horror", "media"])
            ),
            AniListDiscoverySection(
                id: "mahouShoujo",
                title: "Top Mahou Shoujo",
                items: decodeMediaList(data: data, keyPath: ["data", "mahouShoujo", "media"])
            ),
            AniListDiscoverySection(
                id: "mecha",
                title: "Top Mecha",
                items: decodeMediaList(data: data, keyPath: ["data", "mecha", "media"])
            ),
            AniListDiscoverySection(
                id: "music",
                title: "Top Music",
                items: decodeMediaList(data: data, keyPath: ["data", "music", "media"])
            ),
            AniListDiscoverySection(
                id: "mystery",
                title: "Top Mystery",
                items: decodeMediaList(data: data, keyPath: ["data", "mystery", "media"])
            ),
            AniListDiscoverySection(
                id: "psychological",
                title: "Top Psychological",
                items: decodeMediaList(data: data, keyPath: ["data", "psychological", "media"])
            ),
            AniListDiscoverySection(
                id: "romance",
                title: "Top Romance",
                items: decodeMediaList(data: data, keyPath: ["data", "romance", "media"])
            ),
            AniListDiscoverySection(
                id: "sciFi",
                title: "Top Sci-Fi",
                items: decodeMediaList(data: data, keyPath: ["data", "sciFi", "media"])
            ),
            AniListDiscoverySection(
                id: "sliceOfLife",
                title: "Top Slice of Life",
                items: decodeMediaList(data: data, keyPath: ["data", "sliceOfLife", "media"])
            ),
            AniListDiscoverySection(
                id: "sports",
                title: "Top Sports",
                items: decodeMediaList(data: data, keyPath: ["data", "sports", "media"])
            ),
            AniListDiscoverySection(
                id: "supernatural",
                title: "Top Supernatural",
                items: decodeMediaList(data: data, keyPath: ["data", "supernatural", "media"])
            ),
            AniListDiscoverySection(
                id: "thriller",
                title: "Top Thriller",
                items: decodeMediaList(data: data, keyPath: ["data", "thriller", "media"])
            ),
            AniListDiscoverySection(
                id: "shounen",
                title: "Top Shounen",
                items: decodeMediaList(data: data, keyPath: ["data", "shounen", "media"])
            ),
            AniListDiscoverySection(
                id: "shoujo",
                title: "Top Shoujo",
                items: decodeMediaList(data: data, keyPath: ["data", "shoujo", "media"])
            ),
            AniListDiscoverySection(
                id: "seinen",
                title: "Top Seinen",
                items: decodeMediaList(data: data, keyPath: ["data", "seinen", "media"])
            ),
            AniListDiscoverySection(
                id: "josei",
                title: "Top Josei",
                items: decodeMediaList(data: data, keyPath: ["data", "josei", "media"])
            ),
            AniListDiscoverySection(
                id: "isekai",
                title: "Top Isekai",
                items: decodeMediaList(data: data, keyPath: ["data", "isekai", "media"])
            )
        ]
        let cacheKey = discoverySectionsCacheKey(for: sort)
        cacheStore.writeJSON(data, forKey: cacheKey)
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

    private func cachedDiscoverySectionsFromDisk(sort: String) -> [AniListDiscoverySection]? {
        let cacheKey = discoverySectionsCacheKey(for: sort)
        guard let data = cacheStore.readJSON(forKey: cacheKey) else { return nil }
        return [
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
            ),
            AniListDiscoverySection(
                id: "action",
                title: "Top Action",
                items: decodeMediaList(data: data, keyPath: ["data", "action", "media"])
            )
            ,
            AniListDiscoverySection(
                id: "adventure",
                title: "Top Adventure",
                items: decodeMediaList(data: data, keyPath: ["data", "adventure", "media"])
            ),
            AniListDiscoverySection(
                id: "comedy",
                title: "Top Comedy",
                items: decodeMediaList(data: data, keyPath: ["data", "comedy", "media"])
            ),
            AniListDiscoverySection(
                id: "drama",
                title: "Top Drama",
                items: decodeMediaList(data: data, keyPath: ["data", "drama", "media"])
            ),
            AniListDiscoverySection(
                id: "ecchi",
                title: "Top Ecchi",
                items: decodeMediaList(data: data, keyPath: ["data", "ecchi", "media"])
            ),
            AniListDiscoverySection(
                id: "fantasy",
                title: "Top Fantasy",
                items: decodeMediaList(data: data, keyPath: ["data", "fantasy", "media"])
            ),
            AniListDiscoverySection(
                id: "horror",
                title: "Top Horror",
                items: decodeMediaList(data: data, keyPath: ["data", "horror", "media"])
            ),
            AniListDiscoverySection(
                id: "mahouShoujo",
                title: "Top Mahou Shoujo",
                items: decodeMediaList(data: data, keyPath: ["data", "mahouShoujo", "media"])
            ),
            AniListDiscoverySection(
                id: "mecha",
                title: "Top Mecha",
                items: decodeMediaList(data: data, keyPath: ["data", "mecha", "media"])
            ),
            AniListDiscoverySection(
                id: "music",
                title: "Top Music",
                items: decodeMediaList(data: data, keyPath: ["data", "music", "media"])
            ),
            AniListDiscoverySection(
                id: "mystery",
                title: "Top Mystery",
                items: decodeMediaList(data: data, keyPath: ["data", "mystery", "media"])
            ),
            AniListDiscoverySection(
                id: "psychological",
                title: "Top Psychological",
                items: decodeMediaList(data: data, keyPath: ["data", "psychological", "media"])
            ),
            AniListDiscoverySection(
                id: "romance",
                title: "Top Romance",
                items: decodeMediaList(data: data, keyPath: ["data", "romance", "media"])
            ),
            AniListDiscoverySection(
                id: "sciFi",
                title: "Top Sci-Fi",
                items: decodeMediaList(data: data, keyPath: ["data", "sciFi", "media"])
            ),
            AniListDiscoverySection(
                id: "sliceOfLife",
                title: "Top Slice of Life",
                items: decodeMediaList(data: data, keyPath: ["data", "sliceOfLife", "media"])
            ),
            AniListDiscoverySection(
                id: "sports",
                title: "Top Sports",
                items: decodeMediaList(data: data, keyPath: ["data", "sports", "media"])
            ),
            AniListDiscoverySection(
                id: "supernatural",
                title: "Top Supernatural",
                items: decodeMediaList(data: data, keyPath: ["data", "supernatural", "media"])
            ),
            AniListDiscoverySection(
                id: "thriller",
                title: "Top Thriller",
                items: decodeMediaList(data: data, keyPath: ["data", "thriller", "media"])
            ),
            AniListDiscoverySection(
                id: "shounen",
                title: "Top Shounen",
                items: decodeMediaList(data: data, keyPath: ["data", "shounen", "media"])
            ),
            AniListDiscoverySection(
                id: "shoujo",
                title: "Top Shoujo",
                items: decodeMediaList(data: data, keyPath: ["data", "shoujo", "media"])
            ),
            AniListDiscoverySection(
                id: "seinen",
                title: "Top Seinen",
                items: decodeMediaList(data: data, keyPath: ["data", "seinen", "media"])
            ),
            AniListDiscoverySection(
                id: "josei",
                title: "Top Josei",
                items: decodeMediaList(data: data, keyPath: ["data", "josei", "media"])
            ),
            AniListDiscoverySection(
                id: "isekai",
                title: "Top Isekai",
                items: decodeMediaList(data: data, keyPath: ["data", "isekai", "media"])
            )
        ]
    }

    private func discoverySectionsCacheKey(for sort: String) -> String {
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
        return "discovery:sections:\(suffix)"
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



