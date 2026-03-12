import SwiftUI
import UIKit

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var sections: [AniListLibrarySection] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var filterText: String = ""
    @State private var selectedFilter: LibraryFilter = .all
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if UIDevice.current.userInterfaceIdiom != .pad {
                            LibraryTopBar(
                                title: "Library",
                                subtitle: "Currently watching and synced lists",
                                avatarURL: appState.authState.user?.avatarURL,
                                onAvatarTap: {
                                    if !appState.authState.isSignedIn {
                                        Task { await appState.authState.signIn() }
                                    }
                                }
                            )
                        }

                        libraryHero

                        SearchField(placeholder: "Search in library...", text: $filterText)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 16) {
                                ForEach(LibraryFilter.allCases) { filter in
                                    FilterChip(
                                        title: filterTitle(filter),
                                        isSelected: selectedFilter == filter,
                                        action: { selectedFilter = filter }
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .scrollClipDisabled()

                        if !continueWatchingItems().isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Continue Watching")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(spacing: 16) {
                                        ForEach(continueWatchingItems()) { item in
                                            ContinueWatchingCard(
                                                title: item.title,
                                                episodeText: item.episodeText,
                                                progress: item.progressFraction,
                                                timeRemainingText: item.timeRemainingText,
                                                imageURL: item.imageURL,
                                                episodeBadge: item.episodeBadge
                                            )
                                        }
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                }
                                .scrollClipDisabled()
                            }
                        }

                        if appState.authState.isSignedIn {
                            if isLoading {
                                GlassCard {
                                    Text("Loading AniList library...")
                                        .foregroundColor(Theme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else if let errorMessage {
                                GlassCard {
                                    Text(errorMessage)
                                        .foregroundColor(Theme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                ForEach(filteredSections()) { section in
                                    LibrarySection(section: section, filterText: filterText)
                                }
                            }
                        } else {
                            GlassCard {
                                Text("No account connected. Tap the avatar to sign in.")
                                    .foregroundColor(Theme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .navigationTitle(isPad ? "Library" : "")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: tabBarInset)
        }
        .task {
            AppLog.debug(.ui, "library view load")
            await appState.bootstrap()
            if let token = appState.authState.token,
               let cached = appState.services.aniListClient.cachedLibrarySections(token: token),
               !cached.isEmpty {
                applyLibrarySections(cached)
            }
            await loadLibrary()
        }
    }

    private var tabBarInset: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 12 : 80
    }

    private func filteredSections() -> [AniListLibrarySection] {
        let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let byChip = sections.filter { section in
            guard selectedFilter != .all else { return true }
            return section.title.lowercased().contains(selectedFilter.rawValue)
        }
        if trimmed.isEmpty { return byChip }
        return byChip.map { section in
            let items = section.items.filter { $0.media.title.best.lowercased().contains(trimmed) }
            return AniListLibrarySection(id: section.id, title: section.title, items: items)
        }
    }

    private var libraryHero: some View {
        let heroMedia = sections.first(where: { $0.title.lowercased().contains("watching") })?.items.first?.media
            ?? sections.first?.items.first?.media
        let score = heroMedia?.averageScore ?? 91
        let pills = [
            HeroPill(icon: "hand.thumbsup.fill", text: "\(score)% Match"),
            HeroPill(icon: "star.fill", text: "Score \(score)%"),
            HeroPill(icon: "shield.fill", text: (heroMedia?.isAdult ?? false) ? "TV-MA" : "TV-14"),
        ]
        let tags = Array(heroMedia?.genres.prefix(2) ?? ["Action", "Drama"])
        return HeroHeader(
            title: heroMedia?.title.best ?? "86 EIGHTY-SIX",
            subtitle: "Continue watching your synced lists",
            imageURL: heroMedia?.bannerURL ?? heroMedia?.coverURL,
            pills: pills,
            tags: tags,
            height: 260
        )
    }

    private func filterTitle(_ filter: LibraryFilter) -> String {
        guard filter != .all else { return filter.title }
        let status: MediaStatus
        switch filter {
        case .watching:
            status = .watching
        case .planning:
            status = .planning
        case .completed:
            status = .completed
        case .all:
            status = .planning
        }
        let count = appState.services.mediaTracker.count(for: status)
        return "\(filter.title) (\(count))"
    }

    private func continueWatchingItems() -> [ContinueItem] {
        guard let section = sections.first(where: { $0.title.lowercased().contains("watching") }) else {
            return []
        }
        return section.items.compactMap { entry in
            guard let lastEpisodeId = PlaybackHistoryStore.shared.lastEpisodeId(for: entry.media.id),
                  let duration = PlaybackHistoryStore.shared.duration(for: lastEpisodeId),
                  let position = PlaybackHistoryStore.shared.position(for: lastEpisodeId),
                  duration.isFinite, position.isFinite,
                  position > 0, position < duration else { return nil }
            let progress = min(max(position / duration, 0), 1)
            let remaining = max(duration - position, 0)
            let episodeNumber = PlaybackHistoryStore.shared.lastEpisodeNumber(for: entry.media.id) ?? (entry.progress + 1)
            return ContinueItem(
                id: entry.media.id,
                title: entry.media.title.best,
                episodeText: "Episode \(episodeNumber)",
                progressFraction: progress,
                timeRemainingText: formatRemaining(remaining),
                imageURL: entry.media.bannerURL ?? entry.media.coverURL,
                episodeBadge: "EP \(episodeNumber)"
            )
        }
    }

    private func loadLibrary() async {
        guard appState.authState.isSignedIn,
              let token = appState.authState.token else { return }
        AppLog.debug(.network, "library load start")
        isLoading = true
        errorMessage = nil
        do {
            let items = try await appState.services.aniListClient.librarySections(token: token)
            applyLibrarySections(items)
        } catch {
            errorMessage = "Failed to load AniList library."
            AppLog.error(.network, "library load failed \(error.localizedDescription)")
        }
        isLoading = false
        AppLog.debug(.network, "library load complete sections=\(sections.count)")
    }

    private func applyLibrarySections(_ items: [AniListLibrarySection]) {
        sections = items
        let mediaItems = items.flatMap { section -> [MediaItem] in
            let status = statusForSection(section.title)
            return section.items.map { entry in
                MediaItem(
                    externalId: entry.media.id,
                    title: entry.media.title.best,
                    subtitle: entry.media.format,
                    posterImageURL: entry.media.coverURL,
                    heroImageURL: entry.media.bannerURL ?? entry.media.coverURL,
                    ratingScore: entry.media.averageScore,
                    matchPercent: entry.media.averageScore,
                    contentRating: entry.media.isAdult ? "TV-MA" : "TV-14",
                    genres: entry.media.genres,
                    totalEpisodes: entry.media.episodes,
                    currentEpisode: entry.progress,
                    userRating: entry.media.averageScore ?? 0,
                    studio: entry.media.studios.first,
                    status: status
                )
            }
        }
        appState.services.mediaTracker.setItems(mediaItems)
    }

    private func statusForSection(_ title: String) -> MediaStatus {
        let lower = title.lowercased()
        if lower.contains("watching") || lower.contains("current") {
            return .watching
        }
        if lower.contains("planning") {
            return .planning
        }
        if lower.contains("completed") {
            return .completed
        }
        if lower.contains("paused") {
            return .paused
        }
        if lower.contains("dropped") {
            return .dropped
        }
        return .planning
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0 min left" }
        let totalMinutes = max(Int(seconds / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m left"
        }
        return "\(minutes)m left"
    }
}

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case watching
    case planning
    case completed

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private struct LibraryTopBar: View {
    let title: String
    let subtitle: String
    let avatarURL: URL?
    let onAvatarTap: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundColor(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Button(action: onAvatarTap) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 38, height: 38)
                    if let url = avatarURL {
                        CachedImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(width: 38, height: 38)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct LibrarySection: View {
    let section: AniListLibrarySection
    let filterText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            if section.items.isEmpty, !filterText.isEmpty {
                GlassCard {
                    Text("No matches in this list.")
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(section.items, id: \.id) { entry in
                            NavigationLink {
                                DetailsView(media: entry.media)
                            } label: {
                                MediaPosterCard(
                                    title: entry.media.title.best,
                                    subtitle: "Ep \(entry.progress)",
                                    imageURL: entry.media.coverURL,
                                    score: entry.media.averageScore
                                )
                                .frame(width: 150)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
            }
        }
        .padding(.bottom, 4)
    }
}

private struct ContinueItem: Identifiable {
    let id: Int
    let title: String
    let episodeText: String
    let progressFraction: Double
    let timeRemainingText: String
    let imageURL: URL?
    let episodeBadge: String?
}
