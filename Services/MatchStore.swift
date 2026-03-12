import Foundation

final class MatchStore {
    static let shared = MatchStore()
    private let key = "kyomiru.match.overrides"
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    func match(for mediaId: Int) -> StoredMatch? {
        let map = loadMap()
        return map[String(mediaId)]
    }

    func set(match: SoraAnimeMatch, mediaId: Int, isManual: Bool) {
        var map = loadMap()
        let stored = StoredMatch(
            mediaId: mediaId,
            session: match.session,
            title: match.title,
            imageURL: match.imageURL?.absoluteString,
            year: match.year,
            format: match.format,
            episodeCount: match.episodeCount,
            isManual: isManual,
            updatedAt: Date().timeIntervalSince1970
        )
        map[String(mediaId)] = stored
        saveMap(map)
        AppLog.debug(.matching, "match saved mediaId=\(mediaId) session=\(match.session) manual=\(isManual)")
    }

    func clear(mediaId: Int) {
        var map = loadMap()
        map.removeValue(forKey: String(mediaId))
        saveMap(map)
        AppLog.debug(.matching, "match cleared mediaId=\(mediaId)")
    }

    private func loadMap() -> [String: StoredMatch] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        if let map = try? decoder.decode([String: StoredMatch].self, from: data) {
            return map
        }
        return [:]
    }

    private func saveMap(_ map: [String: StoredMatch]) {
        if let data = try? encoder.encode(map) {
            defaults.set(data, forKey: key)
        }
    }
}

struct StoredMatch: Codable, Hashable {
    let mediaId: Int
    let session: String
    let title: String
    let imageURL: String?
    let year: Int?
    let format: String?
    let episodeCount: Int?
    let isManual: Bool
    let updatedAt: TimeInterval

    func asSoraMatch() -> SoraAnimeMatch? {
        guard !session.isEmpty else { return nil }
        return SoraAnimeMatch(
            id: session,
            title: title,
            imageURL: imageURL.flatMap(URL.init(string:)),
            session: session,
            year: year,
            format: format,
            episodeCount: episodeCount
        )
    }
}

