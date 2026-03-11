import Foundation

final class TrackingSyncService {
    static let shared = TrackingSyncService()
    private init() {}

    func start(auth: AuthState, client: AniListClient) {
        AppLog.network.debug("tracking sync start")
        NotificationCenter.default.addObserver(
            forName: .downloadCompleted,
            object: nil,
            queue: .main
        ) { notif in
            guard let title = notif.userInfo?["title"] as? String,
                  let episode = notif.userInfo?["episode"] as? Int else { return }
            AppLog.network.debug("tracking sync event title=\(title, privacy: .public) ep=\(episode)")
            Task {
                await self.updateProgress(auth: auth, client: client, title: title, episode: episode)
            }
        }
    }

    private func updateProgress(auth: AuthState, client: AniListClient, title: String, episode: Int) async {
        guard auth.isSignedIn, let token = auth.token else { return }
        do {
            let media = try await client.searchAnime(query: title).first
            if let media {
                let success = try await client.saveTrackingEntry(token: token, mediaId: media.id, progress: episode)
                AppLog.network.debug("tracking sync save mediaId=\(media.id) success=\(success)")
            }
        } catch {
            AppLog.network.error("tracking sync failed \(error.localizedDescription, privacy: .public)")
            return
        }
    }
}

extension Notification.Name {
    static let downloadCompleted = Notification.Name("kyomiru.download.completed")
}
