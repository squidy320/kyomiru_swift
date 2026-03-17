import Foundation

final class PlaybackHistoryStore {
    static let shared = PlaybackHistoryStore()
    private let key = "kyomiru.playback.history"
    private let durationKey = "kyomiru.playback.duration"
    private let lastEpisodeKey = "kyomiru.playback.lastEpisode"
    private let lastEpisodeNumberKey = "kyomiru.playback.lastEpisodeNumber"
    private let lastUpdatedKey = "kyomiru.playback.lastUpdated"
    private let defaults = UserDefaults.standard

    func save(position: Double, for episodeId: String) {
        var map = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        map[episodeId] = position
        defaults.set(map, forKey: key)
        AppLog.debug(.player, "playback saved episode=\(episodeId) pos=\(position)")
    }

    func position(for episodeId: String) -> Double? {
        let map = defaults.dictionary(forKey: key) as? [String: Double]
        let value = map?[episodeId]
        AppLog.debug(.player, "playback lookup episode=\(episodeId) found=\(value != nil)")
        return value
    }

    func saveDuration(_ duration: Double, for episodeId: String) {
        var map = defaults.dictionary(forKey: durationKey) as? [String: Double] ?? [:]
        map[episodeId] = duration
        defaults.set(map, forKey: durationKey)
        AppLog.debug(.player, "duration saved episode=\(episodeId) dur=\(duration)")
    }

    func duration(for episodeId: String) -> Double? {
        let map = defaults.dictionary(forKey: durationKey) as? [String: Double]
        return map?[episodeId]
    }

    func saveLastEpisode(mediaId: Int, episodeId: String, episodeNumber: Int) {
        var idMap = defaults.dictionary(forKey: lastEpisodeKey) as? [String: String] ?? [:]
        var numberMap = defaults.dictionary(forKey: lastEpisodeNumberKey) as? [String: Int] ?? [:]
        var updatedMap = defaults.dictionary(forKey: lastUpdatedKey) as? [String: TimeInterval] ?? [:]
        idMap[String(mediaId)] = episodeId
        numberMap[String(mediaId)] = episodeNumber
        updatedMap[String(mediaId)] = Date().timeIntervalSince1970
        defaults.set(idMap, forKey: lastEpisodeKey)
        defaults.set(numberMap, forKey: lastEpisodeNumberKey)
        defaults.set(updatedMap, forKey: lastUpdatedKey)
        AppLog.debug(.player, "last episode saved mediaId=\(mediaId) episode=\(episodeId)")
    }

    func lastEpisodeId(for mediaId: Int) -> String? {
        let map = defaults.dictionary(forKey: lastEpisodeKey) as? [String: String]
        return map?[String(mediaId)]
    }

    func lastEpisodeNumber(for mediaId: Int) -> Int? {
        let map = defaults.dictionary(forKey: lastEpisodeNumberKey) as? [String: Int]
        return map?[String(mediaId)]
    }

    func lastUpdated(for mediaId: Int) -> Date? {
        let map = defaults.dictionary(forKey: lastUpdatedKey) as? [String: TimeInterval]
        guard let value = map?[String(mediaId)] else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    func clearEpisode(episodeId: String) {
        var positions = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        var durations = defaults.dictionary(forKey: durationKey) as? [String: Double] ?? [:]
        positions.removeValue(forKey: episodeId)
        durations.removeValue(forKey: episodeId)
        defaults.set(positions, forKey: key)
        defaults.set(durations, forKey: durationKey)
        AppLog.debug(.player, "playback cleared episode=\(episodeId)")
    }

    func clearMedia(mediaId: Int) {
        let mediaKey = String(mediaId)
        var idMap = defaults.dictionary(forKey: lastEpisodeKey) as? [String: String] ?? [:]
        var numberMap = defaults.dictionary(forKey: lastEpisodeNumberKey) as? [String: Int] ?? [:]
        var updatedMap = defaults.dictionary(forKey: lastUpdatedKey) as? [String: TimeInterval] ?? [:]
        if let lastEpisode = idMap[mediaKey] {
            clearEpisode(episodeId: lastEpisode)
        }
        idMap.removeValue(forKey: mediaKey)
        numberMap.removeValue(forKey: mediaKey)
        updatedMap.removeValue(forKey: mediaKey)
        defaults.set(idMap, forKey: lastEpisodeKey)
        defaults.set(numberMap, forKey: lastEpisodeNumberKey)
        defaults.set(updatedMap, forKey: lastUpdatedKey)
        AppLog.debug(.player, "playback cleared mediaId=\(mediaId)")
    }
}

