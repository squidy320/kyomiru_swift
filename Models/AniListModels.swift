import Foundation

enum AniListScoreFormat: String, Equatable, Hashable, Codable {
    case point100 = "POINT_100"
    case point10Decimal = "POINT_10_DECIMAL"
    case point10 = "POINT_10"
    case point5 = "POINT_5"
    case point3 = "POINT_3"

    var step: Double {
        switch self {
        case .point10Decimal:
            return 0.1
        default:
            return 1.0
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .point100:
            return 0...100
        case .point10Decimal, .point10:
            return 0...10
        case .point5:
            return 0...5
        case .point3:
            return 0...3
        }
    }
}

struct AniListUser: Equatable {
    let id: Int
    let name: String
    let avatarURL: URL?
    let bannerURL: URL?
    let scoreFormat: AniListScoreFormat
}

struct AniListTitle: Equatable, Hashable, Codable {
    let romaji: String?
    let english: String?
    let native: String?

    var best: String {
        english ?? romaji ?? native ?? "Unknown"
    }
}

struct AniListMedia: Identifiable, Equatable, Hashable, Codable {
    let id: Int
    let idMal: Int?
    let title: AniListTitle
    let coverURL: URL?
    let bannerURL: URL?
    let averageScore: Int?
    let episodes: Int?
    let seasonYear: Int?
    let startDate: AniListFuzzyDate?
    let format: String?
    let status: String?
    let isAdult: Bool
    let genres: [String]
    let studios: [String]
}

struct AniListFuzzyDate: Equatable, Hashable, Codable {
    let year: Int?
    let month: Int?
    let day: Int?

    var isEmpty: Bool {
        let values = [year, month, day].compactMap { $0 }.filter { $0 > 0 }
        return values.isEmpty
    }

    var displayText: String {
        guard !isEmpty else { return "Not set" }
        let components = [day, month, year].compactMap { value -> String? in
            guard let value, value > 0 else { return nil }
            return String(value)
        }
        guard !components.isEmpty else { return "Not set" }
        return components.joined(separator: "/")
    }

    static func sanitized(year: Int?, month: Int?, day: Int?) -> AniListFuzzyDate? {
        let normalized = AniListFuzzyDate(
            year: sanitizeComponent(year),
            month: sanitizeComponent(month),
            day: sanitizeComponent(day)
        )
        return normalized.isEmpty ? nil : normalized
    }

    static func today() -> AniListFuzzyDate {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        return AniListFuzzyDate(
            year: components.year,
            month: components.month,
            day: components.day
        )
    }

    private static func sanitizeComponent(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

struct AniListLibraryEntry: Identifiable, Equatable {
    let id: Int
    let progress: Int
    let score: Double?
    let startedAt: AniListFuzzyDate?
    let completedAt: AniListFuzzyDate?
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
    let startedAt: AniListFuzzyDate?
    let completedAt: AniListFuzzyDate?
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

struct AniListRelationEdge: Equatable, Codable {
    let relationType: String
    let media: AniListMedia
}

struct AniListStreamingEpisode: Equatable, Hashable, Codable {
    let title: String
    let thumbnailURL: URL?
    let url: URL?
    let episodeNumber: Int?
}

struct AniListNotificationItem: Identifiable, Equatable {
    let id: Int
    let type: String
    let createdAt: Int
    let episode: Int?
    let context: String?
    let media: AniListMedia?
}
