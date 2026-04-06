import Foundation

struct BrowseFilterState: Equatable {
    var genre: String? = nil
    var tag: String? = nil
    var format: BrowseFormat? = nil
    var season: BrowseSeason? = nil
    var year: Int? = nil
    var sort: BrowseSortOption = .trending

    var cacheKey: String {
        [
            "g:\(genre ?? "all")",
            "t:\(tag ?? "all")",
            "f:\(format?.rawValue ?? "all")",
            "s:\(season?.rawValue ?? "all")",
            "y:\(year.map(String.init) ?? "all")",
            "o:\(sort.rawValue)"
        ].joined(separator: "|")
    }

    static let genres: [String] = ["All", "Action", "Adventure", "Comedy", "Drama", "Fantasy", "Romance", "Sci-Fi", "Slice of Life", "Horror", "Mystery", "Psychological", "Supernatural", "Thriller", "Sports", "Music", "Mecha", "Mahou Shoujo", "Ecchi"]
    static let tags: [String] = ["All", "Shounen", "Shoujo", "Seinen", "Josei", "Isekai"]
    static let formatOptions: [String] = ["All", "TV", "Movie", "OVA", "ONA", "Special"]
    static let seasonOptions: [String] = ["All", "Winter", "Spring", "Summer", "Fall"]
    static let yearOptions: [String] = ["All"] + (1980...Calendar.current.component(.year, from: Date())).reversed().map(String.init)
}

enum BrowseFormat: String {
    case TV
    case Movie
    case OVA
    case ONA
    case Special
}

enum BrowseSeason: String {
    case Winter = "Winter"
    case Spring = "Spring"
    case Summer = "Summer"
    case Fall = "Fall"
}

enum BrowseSortOption: String, CaseIterable {
    case trending
    case score
    case popularity
    case title

    var title: String {
        switch self {
        case .trending: return "Trending"
        case .score: return "Score"
        case .popularity: return "Popularity"
        case .title: return "Title"
        }
    }
}
