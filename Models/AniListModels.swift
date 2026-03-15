import Foundation

struct AniListUser: Equatable {
    let id: Int
    let name: String
    let avatarURL: URL?
    let bannerURL: URL?
}

struct AniListTitle: Equatable, Hashable {
    let romaji: String?
    let english: String?
    let native: String?

    var best: String {
        english ?? romaji ?? native ?? "Unknown"
    }
}

struct AniListMedia: Identifiable, Equatable, Hashable {
    let id: Int
    let idMal: Int?
    let title: AniListTitle
    let coverURL: URL?
    let bannerURL: URL?
    let averageScore: Int?
    let episodes: Int?
    let seasonYear: Int?
    let format: String?
    let status: String?
    let isAdult: Bool
    let genres: [String]
    let studios: [String]
}

struct AniListLibraryEntry: Identifiable, Equatable {
    let id: Int
    let progress: Int
    let media: AniListMedia
}

struct AniListLibrarySection: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [AniListLibraryEntry]
}

struct AniListTrackingEntry: Equatable {
    let id: Int
    let status: String?
    let progress: Int?
    let score: Double?
}

struct AniListEpisodeAvailability: Equatable {
    let totalEpisodes: Int
    let nextAiringEpisode: Int?
    let status: String?
}

struct AniListDiscoverySection: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [AniListMedia]
}

struct AniListRelatedSection: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [AniListMedia]
}

struct AniListNotificationItem: Identifiable, Equatable {
    let id: Int
    let type: String
    let createdAt: Int
    let context: String?
    let media: AniListMedia?
}
