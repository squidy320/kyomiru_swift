import SwiftUI

struct UnwatchedBadge: View {
    let mediaId: Int
    @EnvironmentObject private var appState: AppState
    @State private var unseen: Int?

    var body: some View {
        Group {
            if let unseen, unseen > 0 {
                Text("+\(unseen)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.85), in: Capsule())
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard appState.authState.isSignedIn,
              let token = appState.authState.token else { return }
        do {
            let tracking = try await appState.services.aniListClient.trackingEntry(token: token, mediaId: mediaId)
            guard let tracking, (tracking.status ?? "") == "CURRENT" else { return }
            let availability = try await appState.services.aniListClient.episodeAvailability(token: token, mediaId: mediaId)
            let next = (availability?.nextAiringEpisode ?? 0)
            let released = next > 0 ? max(0, next - 1) : (availability?.totalEpisodes ?? 0)
            let progress = min(tracking.progress ?? 0, released)
            let delta = max(0, released - progress)
            unseen = delta
        } catch {
            unseen = nil
        }
    }
}
