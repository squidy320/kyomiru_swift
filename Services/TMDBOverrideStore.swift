import Foundation

struct TMDBManualOverride: Codable, Equatable {
    let aniListId: Int
    let showId: Int
    let seasonNumber: Int
    let episodeOffset: Int
    let showTitle: String?
    let seasonLabel: String?
    let updatedAt: TimeInterval
}

final class TMDBOverrideStore {
    static let shared = TMDBOverrideStore()

    private let key = "kyomiru.tmdb.match.overrides"
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    func override(for aniListId: Int) -> TMDBManualOverride? {
        loadMap()[String(aniListId)]
    }

    func save(_ overrideMatch: TMDBManualOverride) {
        var map = loadMap()
        map[String(overrideMatch.aniListId)] = overrideMatch
        saveMap(map)
        AppLog.debug(
            .matching,
            "tmdb manual override saved mediaId=\(overrideMatch.aniListId) showId=\(overrideMatch.showId) season=\(overrideMatch.seasonNumber) offset=\(overrideMatch.episodeOffset)"
        )
    }

    func clear(aniListId: Int) {
        var map = loadMap()
        map.removeValue(forKey: String(aniListId))
        saveMap(map)
        AppLog.debug(.matching, "tmdb manual override cleared mediaId=\(aniListId)")
    }

    private func loadMap() -> [String: TMDBManualOverride] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? decoder.decode([String: TMDBManualOverride].self, from: data)) ?? [:]
    }

    private func saveMap(_ map: [String: TMDBManualOverride]) {
        guard let data = try? encoder.encode(map) else { return }
        defaults.set(data, forKey: key)
    }
}
