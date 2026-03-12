import Foundation

struct MediaItem: Identifiable, Hashable {
    let id: UUID
    var title: String
    var subtitle: String?
    var posterImageURL: URL?
    var heroImageURL: URL?
    var ratingScore: Int?
    var matchPercent: Int?
    var contentRating: String?
    var genres: [String]
    var totalEpisodes: Int?
    var studio: String?
    var status: MediaStatus

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String? = nil,
        posterImageURL: URL? = nil,
        heroImageURL: URL? = nil,
        ratingScore: Int? = nil,
        matchPercent: Int? = nil,
        contentRating: String? = nil,
        genres: [String] = [],
        totalEpisodes: Int? = nil,
        studio: String? = nil,
        status: MediaStatus = .planning
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.posterImageURL = posterImageURL
        self.heroImageURL = heroImageURL
        self.ratingScore = ratingScore
        self.matchPercent = matchPercent
        self.contentRating = contentRating
        self.genres = genres
        self.totalEpisodes = totalEpisodes
        self.studio = studio
        self.status = status
    }
}

enum MediaStatus: String, CaseIterable, Hashable {
    case watching
    case planning
    case completed
    case paused
}
