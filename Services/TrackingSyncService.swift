import Foundation

final class TrackingSyncService {
    static let shared = TrackingSyncService()
    private init() {}

    func start(auth: AuthState, client: AniListClient) {
        AppLog.debug(.network, "tracking sync start")
        // download-based tracking removed; playback handles sync at 85%
    }

    private func updateProgress(auth: AuthState, client: AniListClient, title: String, episode: Int) async {
        let token = await MainActor.run { auth.token }
        guard let token, !token.isEmpty else { return }
        do {
            let media = try await client.searchAnime(query: title).first
            if let media {
                let success = try await client.saveTrackingEntry(token: token, mediaId: media.id, progress: episode)
                AppLog.debug(.network, "tracking sync save mediaId=\(media.id) success=\(success)")
            }
        } catch {
            AppLog.error(.network, "tracking sync failed \(error.localizedDescription)")
            return
        }
    }
}

extension Notification.Name {
    // downloadCompleted removed; playback-based sync replaces it
}

