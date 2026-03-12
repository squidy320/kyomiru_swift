import Foundation

struct PlaybackProgress: Hashable {
    var currentTime: TimeInterval
    var duration: TimeInterval

    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var timeRemaining: TimeInterval {
        max(duration - currentTime, 0)
    }
}

final class PlaybackEngine: ObservableObject {
    @Published private(set) var progressByItem: [String: PlaybackProgress] = [:]

    func updateProgress(for itemId: String, currentTime: TimeInterval, duration: TimeInterval) {
        progressByItem[itemId] = PlaybackProgress(currentTime: currentTime, duration: duration)
    }

    func progressFraction(for itemId: String) -> Double {
        progressByItem[itemId]?.fraction ?? 0
    }

    func timeRemaining(for itemId: String) -> TimeInterval? {
        progressByItem[itemId]?.timeRemaining
    }
}
