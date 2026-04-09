import Foundation

final class MatchStore {
    static let shared = MatchStore()
    private let key = "kyomiru.match.overrides"
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    func match(for mediaId: Int, moduleID: String = StreamingModuleStore.shared.selectedModuleID()) -> StoredMatch? {
        let map = loadMap()
        guard let stored = map[String(mediaId)] else { return nil }
        let storedModuleID = stored.moduleID ?? StreamingModuleStore.shared.migrateMatchProvider(stored.provider)
        guard storedModuleID == moduleID else { return nil }
        return stored
    }

    func set(match: SoraAnimeMatch, mediaId: Int, isManual: Bool, moduleID: String, behavior: StreamingProvider) {
        var map = loadMap()
        let stored = StoredMatch(
            mediaId: mediaId,
            session: match.session,
            title: match.title,
            imageURL: match.imageURL?.absoluteString,
            detailURL: match.detailURL?.absoluteString,
            year: match.year,
            format: match.format,
            episodeCount: match.episodeCount,
            provider: behavior.rawValue,
            moduleID: moduleID,
            isManual: isManual,
            updatedAt: Date().timeIntervalSince1970
        )
        map[String(mediaId)] = stored
        saveMap(map)
        AppLog.debug(.matching, "match saved mediaId=\(mediaId) session=\(match.session) module=\(moduleID) manual=\(isManual)")
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
    let detailURL: String?
    let year: Int?
    let format: String?
    let episodeCount: Int?
    let provider: String?
    let moduleID: String?
    let isManual: Bool
    let updatedAt: TimeInterval

    func asSoraMatch() -> SoraAnimeMatch? {
        guard !session.isEmpty else { return nil }
        return SoraAnimeMatch(
            id: session,
            title: title,
            imageURL: imageURL.flatMap(URL.init(string:)),
            session: session,
            detailURL: detailURL.flatMap(URL.init(string:)),
            year: year,
            format: format,
            episodeCount: episodeCount,
            normalizedTitle: nil,
            matchScore: nil,
            matchContext: nil
        )
    }
}

