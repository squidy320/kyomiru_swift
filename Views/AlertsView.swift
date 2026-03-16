import SwiftUI
import UIKit

struct AlertsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var notifications: [AniListNotificationItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if UIDevice.current.userInterfaceIdiom != .pad {
                            Text("Alerts")
                                .font(.system(size: 28, weight: .heavy))
                                .foregroundColor(.white)
                        }

                        if !appState.authState.isSignedIn {
                            GlassCard {
                                Text("Connect AniList to view notifications and alerts.")
                                    .foregroundColor(Theme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            if isLoading {
                                GlassCard {
                                    Text("Loading AniList alerts...")
                                        .foregroundColor(Theme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else if let errorMessage {
                                GlassCard {
                                    Text(errorMessage)
                                        .foregroundColor(Theme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else if notifications.isEmpty {
                                GlassCard {
                                    Text("No new alerts.")
                                        .foregroundColor(Theme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                ForEach(notifications) { item in
                                    if let media = item.media {
                                        NavigationLink {
                                            DetailsView(media: media)
                                        } label: {
                                            AlertRow(item: item)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        AlertRow(item: item)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .navigationTitle(isPad ? "Alerts" : "")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: tabBarInset)
        }
        .task {
            AppLog.debug(.ui, "alerts view load")
            await appState.bootstrap()
            await loadNotifications()
        }
        .onChange(of: appState.authState.token) { _, newToken in
            if newToken == nil {
                notifications = []
                return
            }
            Task {
                await loadNotifications()
            }
        }
    }

    private var tabBarInset: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 12 : 80
    }

    private func loadNotifications() async {
        guard appState.authState.isSignedIn,
              let token = appState.authState.token else { return }
        AppLog.debug(.network, "alerts load start")
        isLoading = true
        errorMessage = nil
        do {
            notifications = try await appState.services.aniListClient.notifications(token: token)
        } catch {
            errorMessage = "Failed to load AniList alerts."
            AppLog.error(.network, "alerts load failed \(error.localizedDescription)")
        }
        isLoading = false
        AppLog.debug(.network, "alerts load complete count=\(notifications.count)")
    }
}

private struct AlertRow: View {
    let item: AniListNotificationItem

    var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: 12) {
                if let url = item.media?.coverURL {
                    CachedImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.white.opacity(0.1)
                    }
                    .frame(width: 54, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.media?.title.best ?? "AniList Update")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Text(notificationSummary(item))
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Text(formatTimestamp(item.createdAt))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
            }
        }
    }

    private func formatTimestamp(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func notificationSummary(_ item: AniListNotificationItem) -> String {
        let title = item.media?.title.best ?? "Unknown"
        if let context = item.context, !context.isEmpty {
            if let episode = extractEpisodeNumber(from: context) {
                return "Episode \(episode) of \(title) aired."
            }
            return context
        }
        return "Episode update for \(title)."
    }

    private func extractEpisodeNumber(from text: String) -> Int? {
        let digits = text.split { !$0.isNumber }.compactMap { Int($0) }
        return digits.first
    }
}


