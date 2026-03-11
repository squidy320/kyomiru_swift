import Foundation

final class PlaybackHistoryStore {
    static let shared = PlaybackHistoryStore()
    private let key = "kyomiru.playback.history"
    private let defaults = UserDefaults.standard

    func save(position: Double, for episodeId: String) {
        var map = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        map[episodeId] = position
        defaults.set(map, forKey: key)
        AppLog.player.debug("playback saved episode=\(episodeId, privacy: .public) pos=\(position)")
    }

    func position(for episodeId: String) -> Double? {
        let map = defaults.dictionary(forKey: key) as? [String: Double]
        let value = map?[episodeId]
        AppLog.player.debug("playback lookup episode=\(episodeId, privacy: .public) found=\(value != nil)")
        return value
    }
}
