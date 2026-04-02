import SwiftUI
import UIKit

struct AlertsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var notifications: [AniListNotificationItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.baseBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
                        alertHeader

                        if !appState.authState.isSignedIn {
                            alertStateCard(
                                title: "AniList not connected",
                                message: "Connect AniList to view release alerts and episode updates."
                            )
                        } else if isLoading && notifications.isEmpty {
                            alertStateCard(
                                title: "Loading alerts",
                                message: "Fetching your latest AniList airing updates."
                            )
                        } else if let errorMessage {
                            alertStateCard(
                                title: "Alerts unavailable",
                                message: errorMessage
                            )
                        } else if notifications.isEmpty {
                            alertStateCard(
                                title: "No new alerts",
                                message: "You're all caught up for now."
                            )
                        } else {
                            LazyVStack(spacing: UIConstants.interCardSpacing) {
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
                    .padding(.horizontal, UIConstants.standardPadding)
                    .padding(.top, UIConstants.smallPadding)
                    .padding(.bottom, UIConstants.standardPadding)
                }
                .refreshable {
                    await loadNotifications()
                }
            }
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: UIConstants.toolbarIconSize, height: UIConstants.toolbarIconSize)
                            .background(
                                Circle().fill(Color.black.opacity(0.4))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task {
            AppLog.debug(.ui, "alerts view load")
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

    private var alertHeader: some View {
        VStack(alignment: .leading, spacing: UIConstants.microPadding) {
            Text("Alerts")
                .font(.system(size: 28, weight: .heavy))
                .foregroundColor(Theme.textPrimary)
            Text("Latest episode releases from AniList.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private func alertStateCard(title: String, message: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: UIConstants.microPadding) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            HStack(alignment: .center, spacing: UIConstants.interCardSpacing) {
                artwork

                VStack(alignment: .leading, spacing: UIConstants.microPadding) {
                    HStack(alignment: .top, spacing: UIConstants.smallPadding) {
                        VStack(alignment: .leading, spacing: UIConstants.microPadding) {
                            Text(item.media?.title.best ?? "AniList Update")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(2)

                            Text(notificationSubtitle)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 0)

                        Text(alertBadgeText)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color(red: 0.05, green: 0.66, blue: 0.57).opacity(0.9))
                            )
                    }

                    Text(notificationSummary)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(3)

                    Text(relativeTimestamp)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
    }

    private var artwork: some View {
        Group {
            if let url = item.media?.coverURL {
                CachedImage(
                    url: url,
                    targetSize: CGSize(width: UIConstants.posterCardWidth, height: UIConstants.posterCardHeight)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Image(systemName: "bell.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                    )
            }
        }
        .frame(width: 72, height: 98)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var relativeTimestamp: String {
        let date = Date(timeIntervalSince1970: TimeInterval(item.createdAt))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var notificationSummary: String {
        let title = item.media?.title.best ?? "Unknown"
        if let episode = resolvedEpisodeNumber {
            return "Episode \(episode) of \(title) is now available."
        }
        if let context = sanitizedContext {
            return context
        }
        return "Episode update for \(title)."
    }

    private var notificationSubtitle: String {
        let format = item.media?.format?
            .replacingOccurrences(of: "_", with: " ")
            .capitalized ?? "Anime"
        if let episode = resolvedEpisodeNumber {
            return "\(format) - Episode \(episode)"
        }
        return format
    }

    private var alertBadgeText: String {
        if let episode = resolvedEpisodeNumber {
            return "EP \(episode)"
        }
        return "UPDATE"
    }

    private var resolvedEpisodeNumber: Int? {
        if let episode = item.episode, episode > 0 {
            return episode
        }
        guard let context = sanitizedContext else { return nil }
        let digits = context.split { !$0.isNumber }.compactMap { Int($0) }
        return digits.first
    }

    private var sanitizedContext: String? {
        guard let context = item.context else { return nil }
        let cleaned = context
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
