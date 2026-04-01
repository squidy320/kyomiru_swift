import SwiftUI
import UIKit

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var librarySettings = LibrarySettingsManager()
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @State private var sections: [AniListLibrarySection] = []
    @State private var availabilityById: [Int: AniListEpisodeAvailability] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var filterText: String = ""
    @State private var continueThumbs: [Int: URL] = [:]
    @State private var continueEpisodes: [Int: [SoraEpisode]] = [:]
    @State private var continueLoading = false
    @State private var continueError: String?
    @State private var selectedContinueEpisode: SoraEpisode?
    @State private var selectedContinueMedia: AniListMedia?
    @State private var continueSources: [SoraSource] = []
    @State private var continuePlayerStartAt: Double?
    @State private var showContinuePlayer = false
    @State private var showContinueSourceSheet = false
    @State private var libraryLoadGeneration = 0
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        let useComfortableLayout = appState.settings.useComfortableLayout
        let screenSpacing = UIConstants.interCardSpacing + (useComfortableLayout ? 2 : 0)
        let screenPadding = UIConstants.standardPadding + (useComfortableLayout ? 4 : 0)
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: screenSpacing) {
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

                        SearchField(placeholder: "Search in library...", text: $filterText)

                        if !continueWatchingItems().isEmpty {
                            VStack(alignment: .leading, spacing: screenSpacing) {
                                Text("Continue Watching")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(spacing: screenSpacing) {
                                        ForEach(continueWatchingItems()) { item in
                                            Button {
                                                resumeContinueWatching(item)
                                            } label: {
                                                ContinueWatchingCard(
                                                    title: item.title,
                                                    episodeText: item.episodeText,
                                                    progress: item.progressFraction,
                                                    timeRemainingText: item.timeRemainingText,
                                                    imageURL: item.imageURL,
                                                    episodeBadge: item.episodeBadge,
                                                    media: item.media,
                                                    enablesTMDBArtworkLookup: true
                                                )
                                                .frame(height: UIConstants.continueCardHeight)
                                            }
                                            .buttonStyle(.plain)
                                            .contextMenu {
                                                Button("Remove") {
                                                    PlaybackHistoryStore.shared.clearMedia(mediaId: item.id)
                                                    continueThumbs.removeValue(forKey: item.id)
                                                    continueEpisodes.removeValue(forKey: item.id)
                                                }
                                                Button("Mark Completed") {
                                                    Task {
                                                        await appState.markMediaCompleted(mediaId: item.id)
                                                        PlaybackHistoryStore.shared.clearMedia(mediaId: item.id)
                                                        continueThumbs.removeValue(forKey: item.id)
                                                        continueEpisodes.removeValue(forKey: item.id)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .padding(.horizontal, UIConstants.tinyPadding)
                                    .padding(.vertical, UIConstants.heroTopPadding)
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
                                    LibrarySection(
                                        section: section,
                                        filterText: filterText,
                                        availabilityById: availabilityById
                                    )
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
                    .padding(.horizontal, screenPadding)
                    .padding(.top, UIConstants.smallPadding)
                    .padding(.bottom, UIConstants.bottomBarHeight)
                }
                .refreshable {
                    await loadLibrary(forceRefresh: true)
                }
                .navigationTitle(isPad ? "Library" : "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Sort By", selection: Binding(
                                get: { librarySettings.sortOption },
                                set: { librarySettings.sortOption = $0 }
                            )) {
                                ForEach(LibrarySortOption.allCases) { option in
                                    Text(option.title).tag(option)
                                }
                            }

                            Picker("Format", selection: Binding(
                                get: { librarySettings.formatFilter },
                                set: { librarySettings.formatFilter = $0 }
                            )) {
                                ForEach(LibraryFormatFilter.allCases) { option in
                                    Text(option.title).tag(option)
                                }
                            }

                            Divider()

                            Button("Library Settings") {
                                librarySettings.showSettingsSheet = true
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .foregroundColor(.white)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $librarySettings.showSettingsSheet) {
            LibrarySettingsSheet(manager: librarySettings)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showContinuePlayer) {
            if let episode = selectedContinueEpisode,
               let media = selectedContinueMedia,
               !continueSources.isEmpty {
                PlayerView(
                    episode: episode,
                    sources: continueSources,
                    mediaId: media.id,
                    malId: media.idMal,
                    mediaTitle: media.title.best,
                    startAt: continuePlayerStartAt,
                    onRestoreAfterPictureInPicture: {
                        showContinuePlayer = true
                    }
                )
            }
        }
        .sheet(isPresented: $showContinueSourceSheet) {
            if let episode = selectedContinueEpisode,
               let media = selectedContinueMedia,
               !continueSources.isEmpty {
                StreamSourcePickerSheet(
                    media: media,
                    episode: episode,
                    sources: continueSources,
                    preferredAudio: appState.settings.defaultAudio,
                    preferredQuality: appState.settings.defaultQuality,
                    onPlay: { picked in
                        continueSources = [picked]
                        presentContinuePlayer()
                    },
                    onDownload: { source in
                        enqueueContinueDownload(source, media: media, episodeNumber: episode.number)
                    }
                )
            }
        }
        .overlay(alignment: .bottom) {
            if continueLoading {
                GlassCard {
                    Text("Loading stream...")
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, screenPadding)
                .padding(.bottom, UIConstants.bottomBarHeight + UIConstants.smallPadding)
            } else if let continueError {
                GlassCard {
                    Text(continueError)
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, screenPadding)
                .padding(.bottom, UIConstants.bottomBarHeight + UIConstants.smallPadding)
            }
        }
        .task {
            AppLog.debug(.ui, "library view load")
            if let token = appState.authState.token,
               let cached = appState.services.aniListClient.cachedLibrarySections(token: token, allowStale: true),
               !cached.isEmpty {
                applyLibrarySections(cached)
                await runLibraryBackgroundWork(sections: cached)
            }
            if sections.isEmpty {
                await loadLibrary(forceRefresh: false)
            }
        }
        .onChange(of: appState.authState.token) { _, newToken in
            if newToken == nil {
                sections = []
                availabilityById = [:]
                continueThumbs = [:]
                continueEpisodes = [:]
                selectedContinueEpisode = nil
                selectedContinueMedia = nil
                continueSources = []
                continuePlayerStartAt = nil
                showContinuePlayer = false
                showContinueSourceSheet = false
                return
            }
            Task {
                await loadLibrary(forceRefresh: true)
            }
        }
        .onChange(of: sections) { _, _ in
            Task { await prefetchLibraryImages(sections: sections) }
        }
    }

    private func filteredSections() -> [AniListLibrarySection] {
        let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sectionMap = Dictionary(grouping: sections, by: { statusForSection($0.title) })
            .compactMapValues { $0.first }
        let ordered = librarySettings.orderedCatalogs.compactMap { sectionMap[$0] }
        let formatFilter = librarySettings.formatFilter

        return ordered.map { section in
            var items = section.items
            if formatFilter != .all {
                items = items.filter { formatMatches($0.media, filter: formatFilter) }
            }
            if !trimmed.isEmpty {
                items = items.filter { $0.media.title.best.lowercased().contains(trimmed) }
            }
            items = sortItems(items, by: librarySettings.sortOption)
            return AniListLibrarySection(id: section.id, title: section.title, items: items)
        }
    }

    private func formatMatches(_ media: AniListMedia, filter: LibraryFormatFilter) -> Bool {
        guard let format = media.format?.lowercased() else { return filter == .all }
        switch filter {
        case .all:
            return true
        case .tv:
            return format.contains("tv")
        case .movie:
            return format.contains("movie")
        case .ova:
            return format.contains("ova")
        }
    }

    private func sortItems(_ items: [AniListLibraryEntry], by option: LibrarySortOption) -> [AniListLibraryEntry] {
        switch option {
        case .lastUpdated:
            return items.sorted { lhs, rhs in
                let leftDate = PlaybackHistoryStore.shared.lastUpdated(for: lhs.media.id) ?? Date.distantPast
                let rightDate = PlaybackHistoryStore.shared.lastUpdated(for: rhs.media.id) ?? Date.distantPast
                return leftDate > rightDate
            }
        case .score:
            return items.sorted { lhs, rhs in
                (lhs.media.averageScore ?? 0) > (rhs.media.averageScore ?? 0)
            }
        case .alphabetical:
            return items.sorted { lhs, rhs in
                lhs.media.title.best.lowercased() < rhs.media.title.best.lowercased()
            }
        }
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
            if progress >= 0.85 { return nil }
            let remaining = max(duration - position, 0)
            let episodeNumber = PlaybackHistoryStore.shared.lastEpisodeNumber(for: entry.media.id) ?? (entry.progress + 1)
            let thumb = continueThumbs[entry.media.id]
            return ContinueItem(
                id: entry.media.id,
                title: entry.media.title.best,
                episodeText: "Episode \(episodeNumber)",
                progressFraction: progress,
                timeRemainingText: formatRemaining(remaining),
                imageURL: thumb ?? entry.media.bannerURL ?? entry.media.coverURL,
                episodeBadge: "EP \(episodeNumber)",
                media: entry.media,
                episodeNumber: episodeNumber,
                lastEpisodeId: lastEpisodeId
            )
        }
    }

    private func loadLibrary(forceRefresh: Bool = false) async {
        guard appState.authState.isSignedIn,
              let token = appState.authState.token else { return }
        libraryLoadGeneration += 1
        let loadGeneration = libraryLoadGeneration
        AppLog.debug(.network, "library load start")
        isLoading = true
        errorMessage = nil
        do {
            let items = try await appState.services.aniListClient.librarySections(token: token, forceRefresh: forceRefresh)
            guard loadGeneration == libraryLoadGeneration else { return }
            applyLibrarySections(items)
            await runLibraryBackgroundWork(sections: items, generation: loadGeneration)
        } catch {
            guard loadGeneration == libraryLoadGeneration else { return }
            if sections.isEmpty {
                errorMessage = "AniList is temporarily unavailable. Showing your cached library when available."
            }
            AppLog.error(.network, "library load failed \(error.localizedDescription)")
        }
        guard loadGeneration == libraryLoadGeneration else { return }
        isLoading = false
        AppLog.debug(.network, "library load complete sections=\(sections.count)")
    }

    private func applyLibrarySections(_ items: [AniListLibrarySection]) {
        sections = items
        appState.updateLibraryStore(with: items)
    }

    private func statusForSection(_ title: String) -> MediaStatus {
        MediaStatus.fromSectionTitle(title)
    }

    private func runLibraryBackgroundWork(sections: [AniListLibrarySection], generation: Int? = nil) async {
        await prefetchAvailability(sections: sections, generation: generation)
        guard generation == nil || generation == libraryLoadGeneration else { return }
        await prefetchLibraryImages(sections: sections)
    }

    private func prefetchAvailability(sections: [AniListLibrarySection], generation: Int? = nil) async {
        guard let token = appState.authState.token, appState.authState.isSignedIn else { return }
        let watching = Array((sections.first(where: { statusForSection($0.title) == .watching })?.items ?? []).prefix(6))
        if watching.isEmpty { return }
        var updated = availabilityById
        for entry in watching {
            if let generation, generation != libraryLoadGeneration { return }
            let avail = try? await appState.services.aniListClient.episodeAvailability(
                token: token,
                mediaId: entry.media.id
            )
            if let avail {
                updated[entry.media.id] = avail
            }
        }
        if let generation, generation != libraryLoadGeneration { return }
        await MainActor.run {
            availabilityById = updated
        }
    }

    private func prefetchLibraryImages(sections: [AniListLibrarySection], limit: Int = 18) async {
        guard networkMonitor.isOnWiFi else { return }
        var urls: [URL] = []

        let continueItems = continueWatchingItems()
        for item in continueItems.prefix(6) {
            if let url = item.imageURL {
                urls.append(url)
            }
        }

        await ImageCache.shared.prefetch(urls: urls)
    }

    private func resumeContinueWatching(_ item: ContinueItem) {
        guard let media = item.media else { return }
        Task {
            continueLoading = true
            continueError = nil
            do {
                let episodes: [SoraEpisode]
                if let cached = continueEpisodes[item.id] {
                    episodes = cached
                } else {
                    let result = try await appState.services.episodeService.loadEpisodes(media: media)
                    continueEpisodes[item.id] = result.episodes
                    episodes = result.episodes
                }
                let target = episodes.first(where: { $0.id == item.lastEpisodeId })
                    ?? episodes.first(where: { $0.number == item.episodeNumber })
                    ?? episodes.last
                guard let episode = target else {
                    continueError = "Unable to resume episode."
                    continueLoading = false
                    return
                }
                if let local = DownloadManager.shared.downloadedItem(title: media.title.best, episode: episode.number),
                   let localURL = DownloadManager.shared.playableURL(for: local) {
                    let format = localURL.pathExtension.lowercased()
                    let source = SoraSource(
                        id: "local|\(local.id)",
                        url: localURL,
                        quality: "Local",
                        subOrDub: "Sub",
                        format: format.isEmpty ? "mp4" : format,
                        headers: [:]
                    )
                    selectedContinueEpisode = episode
                    selectedContinueMedia = media
                    continueSources = [source]
                    continuePlayerStartAt = PlaybackHistoryStore.shared.position(for: episode.id)
                    presentContinuePlayer()
                    continueLoading = false
                    return
                }
                let loadedSources = try await appState.services.episodeService.loadSources(for: episode)
                if loadedSources.isEmpty {
                    continueError = "No streams available."
                } else {
                    selectedContinueEpisode = episode
                    selectedContinueMedia = media
                    continuePlayerStartAt = PlaybackHistoryStore.shared.position(for: episode.id)
                    continueSources = loadedSources
                    if let preferred = preferredSource(in: loadedSources) {
                        continueSources = [preferred]
                        presentContinuePlayer()
                    } else {
                        showContinueSourceSheet = true
                    }
                }
            } catch {
                continueError = "Failed to load stream."
                AppLog.error(.network, "continue watch load failed mediaId=\(item.id) \(error.localizedDescription)")
            }
            continueLoading = false
        }
    }

    private func presentContinuePlayer() {
        guard let episode = selectedContinueEpisode,
              let media = selectedContinueMedia,
              !continueSources.isEmpty else { return }
        _ = episode
        _ = media
        showContinueSourceSheet = false
        showContinuePlayer = true
    }

    private func preferredSource(in sources: [SoraSource]) -> SoraSource? {
        StreamSourcePreferenceResolver.preferredSource(
            in: sources,
            preferredAudio: appState.settings.defaultAudio,
            preferredQuality: appState.settings.defaultQuality
        )
    }

    private func enqueueContinueDownload(_ source: SoraSource, media: AniListMedia, episodeNumber: Int) {
        let mediaItem = MediaItem(
            externalId: media.id,
            title: media.title.best,
            subtitle: media.format,
            posterImageURL: media.coverURL,
            heroImageURL: media.bannerURL ?? media.coverURL,
            ratingScore: media.averageScore,
            matchPercent: media.averageScore,
            contentRating: media.isAdult ? "TV-MA" : "TV-14",
            genres: media.genres,
            totalEpisodes: media.episodes,
            currentEpisode: 0,
            userRating: 0,
            studio: media.studios.first ?? media.format,
            status: .planning
        )

        if source.format.lowercased() == "m3u8" {
            appState.services.downloadManager.enqueueHLS(
                title: media.title.best,
                episode: episodeNumber,
                url: source.url,
                headers: source.headers,
                media: mediaItem
            )
        } else {
            appState.services.downloadManager.enqueue(
                title: media.title.best,
                episode: episodeNumber,
                url: source.url,
                media: mediaItem
            )
        }
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
        HStack(alignment: .center, spacing: UIConstants.interCardSpacing) {
            VStack(alignment: .leading, spacing: UIConstants.microPadding) {
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
                        .frame(width: UIConstants.avatarSize, height: UIConstants.avatarSize)
                    if let url = avatarURL {
                        CachedImage(
                            url: url,
                            targetSize: CGSize(width: UIConstants.posterCardWidth, height: UIConstants.posterCardHeight)
                        ) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(width: UIConstants.avatarSize, height: UIConstants.avatarSize)
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
    let availabilityById: [Int: AniListEpisodeAvailability]
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let isWatching = MediaStatus.fromSectionTitle(section.title) == .watching
        VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
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
                    LazyHStack(spacing: UIConstants.interCardSpacing) {
                        ForEach(section.items, id: \.id) { entry in
                            let availability = availabilityById[entry.media.id]
                            let released = releasedEpisodeCount(media: entry.media, availability: availability)
                            let isReleasing = isReleasing(media: entry.media, availability: availability)
                            let showNew = isWatching && isReleasing && released > 0 && entry.progress < released
                            NavigationLink {
                                DetailsView(media: entry.media)
                            } label: {
                                MediaPosterCard(
                                    title: entry.media.title.best,
                                    subtitle: isWatching ? episodeSubtitle(progress: entry.progress, released: released) : nil,
                                    imageURL: entry.media.coverURL,
                                    media: entry.media,
                                    score: entry.media.averageScore,
                                    statusBadge: nil,
                                    cornerBadge: showNew ? "NEW" : nil,
                                    enablesTMDBArtworkLookup: true
                                )
                                .frame(width: UIConstants.posterCardWidth)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, UIConstants.tinyPadding)
                    .padding(.vertical, UIConstants.heroTopPadding)
                }
                .scrollClipDisabled()
            }
        }
        .padding(.bottom, UIConstants.microPadding)
    }

    private func episodeSubtitle(progress: Int, released: Int) -> String {
        if released > 0 {
            return "Ep \(progress) / \(released)"
        }
        return "Ep \(progress)"
    }

    private func releasedEpisodeCount(media: AniListMedia, availability: AniListEpisodeAvailability?) -> Int {
        if let availability, isReleasing(media: media, availability: availability),
           let next = availability.nextAiringEpisode, next > 0 {
            return max(next - 1, 0)
        }
        if let total = availability?.totalEpisodes, total > 0 {
            return total
        }
        return media.episodes ?? 0
    }

    private func isReleasing(media: AniListMedia, availability: AniListEpisodeAvailability?) -> Bool {
        let status = (availability?.status ?? media.status ?? "").uppercased()
        return status == "RELEASING"
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
    let media: AniListMedia?
    let episodeNumber: Int
    let lastEpisodeId: String
}

private struct LibrarySettingsSheet: View {
    @ObservedObject var manager: LibrarySettingsManager

    var body: some View {
        NavigationStack {
            List {
                Section("Visible Catalogs") {
                    ForEach(MediaStatus.allCases, id: \.self) { status in
                        Toggle(statusTitle(status), isOn: Binding(
                            get: { manager.visibleStatuses.contains(status) },
                            set: { manager.setVisibility(status, isVisible: $0) }
                        ))
                    }
                }

                Section("Catalog Order") {
                    ForEach(manager.catalogOrder, id: \.self) { status in
                        HStack {
                            Text(statusTitle(status))
                            Spacer()
                            Image(systemName: "line.3.horizontal")
                                .foregroundColor(.secondary)
                        }
                    }
                    .onMove { indices, destination in
                        manager.move(from: indices, to: destination)
                    }
                }
            }
            .navigationTitle("Library Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
    }

    private func statusTitle(_ status: MediaStatus) -> String {
        switch status {
        case .watching: return "Watching"
        case .planning: return "Plan to Watch"
        case .completed: return "Completed"
        case .paused: return "Paused"
        case .dropped: return "Dropped"
        }
    }
}
