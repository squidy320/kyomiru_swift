import Foundation

final class PlaybackHistoryStore {
    static let shared = PlaybackHistoryStore()
    private let key = "kyomiru.playback.history"
    private let durationKey = "kyomiru.playback.duration"
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
}

