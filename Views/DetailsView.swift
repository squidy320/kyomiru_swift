import SwiftUI
import UIKit
import Observation

struct DetailsView: View {
    let media: AniListMedia
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var episodes: [SoraEpisode] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedEpisode: SoraEpisode?
    @State private var sources: [SoraSource] = []
    @State private var showPlayer = false
    @State private var isLoadingSources = false
    @State private var showSourceSheet = false
    @State private var showMatchSheet = false
    @State private var showListManager = false
    @State private var listManagerModel = ListManagerViewModel(item: MediaItem(title: "", status: .planning))
    @State private var isLoadingMatch = false
    @State private var matchCandidates: [SoraAnimeMatch] = []
    @State private var matchError: String?
    @State private var matchQuery: String = ""
    @State private var selectedEpisodeTab: EpisodeTab = .currentSeries
    @State private var isBookmarked = false
    @State private var relatedSections: [AniListRelatedSection] = []
    @State private var episodeMetadata: [Int: EpisodeMetadata] = [:]
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
                    header

                    actionRow

                    if isLoading {
                        GlassCard {
                            Text("Loading episodes...")
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
                        episodeList
                        if !relatedSections.isEmpty {
                            RelationsCarouselView(sections: relatedSections)
                        }
                    }
                }
                .padding(.horizontal, UIConstants.standardPadding)
                .padding(.top, UIConstants.smallPadding)
                .padding(.bottom, UIConstants.bottomBarHeight)
            }
        }
        .navigationBarBackButtonHidden(!isPad)
        .navigationTitle(isPad ? media.title.best : "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            AppLog.debug(.ui, "details view load mediaId=\(media.id)")
            await loadEpisodes()
            await loadRelated()
            isBookmarked = (appState.services.libraryStore.item(forExternalId: media.id)?.status ?? .planning) != .planning
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let episode = selectedEpisode, !sources.isEmpty {
                PlayerView(episode: episode, sources: sources, mediaId: media.id, malId: media.idMal, mediaTitle: media.title.best)
            }
        }
        .sheet(isPresented: $showSourceSheet) {
            SourcePickerSheet(
                media: media,
                episode: selectedEpisode,
                sources: sources,
                onPlay: { picked in
                    if let picked {
                        self.sources = [picked]
                    }
                    showPlayer = true
                },
                onDownload: { source in
                    if source.format.lowercased() == "m3u8" {
                        appState.services.downloadManager.enqueueHLS(
                            title: media.title.best,
                            episode: selectedEpisode?.number ?? 0,
                            url: source.url,
                            headers: source.headers
                        )
                    } else {
                        appState.services.downloadManager.enqueue(
                            title: media.title.best,
                            episode: selectedEpisode?.number ?? 0,
                            url: source.url
                        )
                    }
                }
            )
        }
        .sheet(isPresented: $showMatchSheet) {
            MatchPickerSheet(
                media: media,
                query: $matchQuery,
                candidates: matchCandidates,
                isLoading: isLoadingMatch,
                errorMessage: matchError,
                onSearch: { term in
                    performMatchSearch(query: term)
                },
                onSelect: { match in
                    Task {
                        _ = await appState.services.metadataService.manualMatch(local: detailItem, remoteId: match.session)
                        appState.services.episodeService.setManualMatch(media: media, match: match)
                        AppLog.debug(.matching, "manual match selected mediaId=\(media.id) session=\(match.session)")
                        await loadEpisodes()
                    }
                }
            )
        }
        .sheet(isPresented: $showListManager) {
            ListManagerView(item: detailItem, viewModel: listManagerModel) { updated in
                appState.services.libraryStore.upsert(updated)
                isBookmarked = updated.status != MediaStatus.planning
            }
            .presentationDetents([PresentationDetent.medium])
            .onAppear {
                listManagerModel = makeListManagerModel()
            }
        }
        .toolbar {
            if !isPad {
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
        .overlay(alignment: .bottom) {
            if isLoadingSources {
                GlassCard {
                    Text("Loading streams...")
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(UIConstants.overlayPadding)
            }
        }
    }

    private var header: some View {
        let episodesCount = media.episodes ?? 0
        let pills = [
            HeroPill(icon: "rectangle.stack.fill", text: episodesCount > 0 ? "\(episodesCount) EPS" : "Episodes"),
            HeroPill(icon: "building.2.fill", text: media.studios.first ?? media.format ?? "Studio"),
            HeroPill(icon: "star.fill", text: "Score \(media.averageScore ?? 0)")
        ]
        let tags = Array(media.genres.prefix(2))
        return HeroHeader(
            title: media.title.best,
            subtitle: media.format,
            imageURL: media.bannerURL ?? media.coverURL,
            media: media,
            pills: pills,
            tags: tags,
            height: UIConstants.heroHeightCompact
        )
    }

    private var actionRow: some View {
        HStack(spacing: UIConstants.interCardSpacing) {
            Button {
                playFirstEpisode()
            } label: {
                HStack(spacing: UIConstants.smallPadding) {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, UIConstants.buttonHorizontalPadding)
                .padding(.vertical, UIConstants.buttonVerticalPadding)
                .background(
                    Capsule(style: .continuous)
                        .fill(Theme.accent)
                )
            }
            .buttonStyle(.plain)

            Button {
                listManagerModel = makeListManagerModel()
                showListManager = true
            } label: {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: UIConstants.circleButtonSize, height: UIConstants.circleButtonSize)
                    .background(
                        Circle().fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)

            Button {
                openMatchPicker()
            } label: {
                HStack(spacing: UIConstants.tinyPadding) {
                    Image(systemName: "link")
                    Text("Manual Match")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, UIConstants.interCardSpacing)
                .padding(.vertical, UIConstants.buttonVerticalPadding)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)

            Button {
                downloadAllEpisodes()
            } label: {
                HStack(spacing: UIConstants.tinyPadding) {
                    Image(systemName: "arrow.down")
                    Text(appState.services.offlineManager.isDownloading(detailItem) ? "Downloading" : "Download All")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, UIConstants.interCardSpacing)
                .padding(.vertical, UIConstants.buttonVerticalPadding)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var episodeTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UIConstants.interCardSpacing) {
                ForEach(EpisodeTab.allCases) { tab in
                    FilterChip(
                        title: tab.title,
                        isSelected: selectedEpisodeTab == tab,
                        action: { selectedEpisodeTab = tab }
                    )
                }
            }
        }
    }

    private var episodeGrid: some View {
        let cards = episodeCards()
        return VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
            if selectedEpisodeTab != .currentSeries {
                Text(selectedEpisodeTab.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            LazyVStack(spacing: UIConstants.interCardSpacing) {
                ForEach(cards) { card in
                    if let related = card.relatedMedia {
                        NavigationLink {
                            DetailsView(media: related)
                        } label: {
                            EpisodeRow(card: card)
                        }
                        .buttonStyle(.plain)
                    } else if let ep = card.episode {
                        Button {
                            selectEpisode(ep)
                        } label: {
                            EpisodeRow(card: card)
                        }
                        .buttonStyle(.plain)
                    } else {
                        EpisodeRow(card: card)
                    }
                }
            }
        }
    }

    private var episodeList: some View {
        LazyVStack(spacing: UIConstants.interCardSpacing) {
            ForEach(episodes, id: \.id) { episode in
                let meta = episodeMetadata[episode.number]
                EpisodeRowView(
                    title: meta?.title ?? "Episode \(episode.number)",
                    runtimeText: runtimeText(from: meta),
                    description: meta?.summary,
                    thumbnailURL: meta?.thumbnailURL ?? episodeThumbnailURL(for: episode),
                    isPlayable: true,
                    isWatched: isEpisodeWatched(episode.number),
                    isDownloaded: isEpisodeDownloaded(episode.number),
                    onTap: {
                        selectEpisode(episode)
                    }
                )
            }
        }
    }

    private var detailItem: MediaItem {
        MediaItem(
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
    }

    private func makeListManagerModel() -> ListManagerViewModel {
        if let existing = appState.services.libraryStore.item(forExternalId: media.id) {
            return ListManagerViewModel(item: existing)
        }
        return ListManagerViewModel(item: detailItem)
    }

    private func loadEpisodes() async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await appState.services.episodeService.loadEpisodes(media: media)
            episodes = result.episodes
            episodeMetadata = await appState.services.episodeMetadataService.fetchEpisodes(for: media, episodes: result.episodes)
        } catch {
            errorMessage = "Failed to load episodes."
            AppLog.error(.network, "details episodes load failed mediaId=\(media.id) \(error.localizedDescription)")
        }
        isLoading = false
    }

    private func openMatchPicker() {
        matchQuery = media.title.best
        showMatchSheet = true
        performMatchSearch(query: matchQuery)
    }

    private func performMatchSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoadingMatch = true
        matchError = nil
        matchCandidates = []
        Task {
            do {
                let candidates: [SoraAnimeMatch]
                if trimmed.isEmpty {
                    candidates = try await appState.services.episodeService.searchCandidates(media: media)
                } else {
                    candidates = try await appState.services.episodeService.searchCandidates(query: trimmed)
                }
                matchCandidates = candidates
                if candidates.isEmpty {
                    matchError = "No matches found."
                }
            } catch {
                matchError = "Failed to search matches."
                AppLog.error(.matching, "manual match search failed mediaId=\(media.id) \(error.localizedDescription)")
            }
            isLoadingMatch = false
        }
    }

    private func selectEpisode(_ episode: SoraEpisode) {
        selectedEpisode = episode
        AppLog.debug(.ui, "episode selected ep=\(episode.number)")
        Task {
            isLoadingSources = true
            do {
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
                    sources = [source]
                    showPlayer = true
                    isLoadingSources = false
                    return
                }
                async let sourceTask = appState.services.episodeService.loadSources(for: episode)
                async let skipTask: Void = {
                    guard let malId = media.idMal else { return }
                    let segments = await appState.services.aniSkipService.fetchSkipSegments(malId: malId, episode: episode.number)
                    if !segments.isEmpty {
                        appState.services.downloadManager.storeSkipSegments(segments, malId: malId, episode: episode.number)
                    }
                }()
                sources = try await sourceTask
                _ = await skipTask
                if sources.isEmpty {
                    errorMessage = "No streams available."
                } else {
                    showSourceSheet = true
                }
            } catch {
                errorMessage = "Failed to load streams."
                AppLog.error(.network, "sources load failed ep=\(episode.number) \(error.localizedDescription)")
            }
            isLoadingSources = false
        }
    }

    private func playFirstEpisode() {
        guard let first = episodes.first else { return }
        selectEpisode(first)
    }

    private func episodeCards() -> [EpisodeCardModel] {
        if selectedEpisodeTab == .currentSeries {
            return episodes.map { ep in
                let key = "episode:\(ep.id)"
                let progress = progressFraction(for: ep.id, fallbackKey: key)
                let remaining = timeRemainingText(for: ep.id)
                return EpisodeCardModel(
                    id: UUID(),
                    title: "Episode \(ep.number)",
                    subtitle: episodeSubtitle(),
                    imageURL: episodeThumbnailURL(for: ep),
                    progressFraction: progress,
                    badgeText: nil,
                    score: nil,
                    tags: [],
                    timeBadgeText: remaining,
                    isPlayable: true,
                    episode: ep,
                    relatedMedia: nil
                )
            }
        }

        let related = relatedItems(for: selectedEpisodeTab)
        if !related.isEmpty {
            return related.map { item in
                EpisodeCardModel(
                    id: UUID(),
                    title: item.title.best,
                    subtitle: selectedEpisodeTab.title,
                    imageURL: item.bannerURL ?? item.coverURL,
                    progressFraction: nil,
                    badgeText: item.format ?? item.studios.first,
                    score: item.averageScore,
                    tags: item.genres,
                    timeBadgeText: nil,
                    isPlayable: false,
                    episode: nil,
                    relatedMedia: item
                )
            }
        }

        let count = max(min(episodes.count, 8), 8)
        return (1...count).map { idx in
            EpisodeCardModel(
                id: UUID(),
                title: "\(selectedEpisodeTab.title) Ep \(idx)",
                subtitle: "Related entry",
                imageURL: media.bannerURL ?? media.coverURL,
                progressFraction: nil,
                badgeText: nil,
                score: nil,
                tags: [],
                timeBadgeText: nil,
                isPlayable: false,
                episode: nil,
                relatedMedia: nil
            )
        }
    }

    private func episodeThumbnailURL(for episode: SoraEpisode) -> URL? {
        media.coverURL ?? media.bannerURL
    }

    private func episodeSubtitle() -> String {
        let minutes = 24
        return "Tap to play - \(minutes)m"
    }

    private func runtimeText(from meta: EpisodeMetadata?) -> String? {
        guard let minutes = meta?.runtimeMinutes, minutes > 0 else { return nil }
        return "\(minutes)m"
    }

    private func isEpisodeWatched(_ number: Int) -> Bool {
        guard let item = appState.services.libraryStore.item(forExternalId: media.id) else { return false }
        return number <= item.currentEpisode
    }

    private func isEpisodeDownloaded(_ number: Int) -> Bool {
        DownloadManager.shared.downloadedItem(title: media.title.best, episode: number) != nil
    }

    private func progressFraction(for episodeId: String, fallbackKey: String) -> Double? {
        let engine = appState.services.playbackEngine.progressFraction(for: fallbackKey)
        if engine > 0 { return engine }
        guard let duration = PlaybackHistoryStore.shared.duration(for: episodeId),
              let position = PlaybackHistoryStore.shared.position(for: episodeId),
              duration.isFinite, position.isFinite, duration > 0 else { return nil }
        return min(max(position / duration, 0), 1)
    }

    private func timeRemainingText(for episodeId: String) -> String? {
        guard let duration = PlaybackHistoryStore.shared.duration(for: episodeId),
              let position = PlaybackHistoryStore.shared.position(for: episodeId),
              duration.isFinite, position.isFinite, duration > 0 else { return nil }
        let remaining = max(duration - position, 0)
        return formatTime(remaining)
    }

    private func formatTime(_ seconds: Double) -> String {
        let totalMinutes = max(Int(seconds / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m left"
        }
        return "\(minutes)m left"
    }

    private func relatedItems(for tab: EpisodeTab) -> [AniListMedia] {
        relatedSections.first(where: { $0.id == tab.relationKey })?.items ?? []
    }

    private func loadRelated() async {
        do {
            relatedSections = try await appState.services.aniListClient.relatedSections(mediaId: media.id)
        } catch {
            relatedSections = []
            AppLog.error(.network, "related sections load failed mediaId=\(media.id) \(error.localizedDescription)")
        }
    }

    private func downloadAllEpisodes() {
        AppLog.debug(.downloads, "download all start mediaId=\(media.id) count=\(episodes.count)")
        Task {
            appState.services.offlineManager.beginDownload(for: detailItem)
            for ep in episodes {
                do {
                    let sources = try await appState.services.episodeService.loadSources(for: ep)
                    guard let best = sources.first else { continue }
                    if best.format.lowercased() == "m3u8" {
                        appState.services.downloadManager.enqueueHLS(
                            title: media.title.best,
                            episode: ep.number,
                            url: best.url,
                            headers: best.headers
                        )
                    } else {
                        appState.services.downloadManager.enqueue(
                            title: media.title.best,
                            episode: ep.number,
                            url: best.url
                        )
                    }
                } catch {
                    continue
                }
            }
            appState.services.offlineManager.endDownload(for: detailItem)
        }
    }
}

private enum EpisodeTab: String, CaseIterable, Identifiable {
    case currentSeries = "Current Series"
    case adaptation = "Adaptation"
    case prequel = "Prequel"
    case sideStory = "Side Story"

    var id: String { rawValue }
    var title: String { rawValue }
    var relationKey: String {
        switch self {
        case .adaptation:
            return "adaptation"
        case .prequel:
            return "prequel"
        case .sideStory:
            return "side_story"
        case .currentSeries:
            return "current_series"
        }
    }
}

private struct EpisodeCardModel: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String
    let imageURL: URL?
    let progressFraction: Double?
    let badgeText: String?
    let score: Int?
    let tags: [String]
    let timeBadgeText: String?
    let isPlayable: Bool
    let episode: SoraEpisode?
    let relatedMedia: AniListMedia?
}

private struct EpisodeRow: View {
    let card: EpisodeCardModel
    @EnvironmentObject private var appState: AppState
    @State private var imdbImageURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: UIConstants.interCardSpacing) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: UIConstants.cornerRadiusSmall, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: UIConstants.episodeThumbWidth, height: UIConstants.episodeThumbHeight)
                if let resolved = imdbImageURL ?? card.imageURL {
                    CachedImage(url: resolved) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.white.opacity(0.08)
                    }
                    .frame(width: UIConstants.episodeThumbWidth, height: UIConstants.episodeThumbHeight)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: UIConstants.cornerRadiusSmall, style: .continuous))
                }
                if let score = card.score {
                    RatingBadge(score: score)
                        .padding(UIConstants.ratingBadgePadding)
                }
            }

            VStack(alignment: .leading, spacing: UIConstants.tinyPadding) {
                Text(card.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                Text(card.subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                if let timeBadgeText = card.timeBadgeText {
                    Text(timeBadgeText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                if let progress = card.progressFraction {
                    ProgressView(value: progress)
                        .tint(Theme.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(UIConstants.rowPadding)
        .background(
            RoundedRectangle(cornerRadius: UIConstants.cornerRadiusLarge, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .task(id: card.relatedMedia?.id) {
            guard let media = card.relatedMedia else { return }
            imdbImageURL = await appState.services.metadataService.backdropURL(for: media)
        }
    }
}

@Observable
final class ListManagerViewModel {
    var status: MediaStatus
    var currentEpisode: Int
    var rating: Int
    let totalEpisodes: Int?
    let title: String

    init(item: MediaItem) {
        self.status = item.status
        self.currentEpisode = item.currentEpisode
        self.rating = item.userRating
        self.totalEpisodes = item.totalEpisodes
        self.title = item.title
    }

    func apply(to item: MediaItem) -> MediaItem {
        var updated = item
        updated.status = status
        updated.currentEpisode = max(currentEpisode, 0)
        updated.userRating = min(max(rating, 0), 100)
        return updated
    }
}

private struct ListManagerView: View {
    let item: MediaItem
    @Bindable var viewModel: ListManagerViewModel
    let onSave: (MediaItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: UIConstants.standardPadding) {
                Text(viewModel.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: UIConstants.mediumPadding) {
                    Text("Status")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    Picker("Status", selection: $viewModel.status) {
                        ForEach(MediaStatus.allCases, id: \.self) { status in
                            Text(status.rawValue.capitalized).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: UIConstants.mediumPadding) {
                    Text("Episodes Watched")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    Stepper(
                        value: $viewModel.currentEpisode,
                        in: 0...(viewModel.totalEpisodes ?? 999),
                        step: 1
                    ) {
                        Text("Episode \(viewModel.currentEpisode)")
                            .foregroundColor(.white)
                    }
                }

                VStack(alignment: .leading, spacing: UIConstants.mediumPadding) {
                    Text("Your Rating")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    Slider(value: Binding(
                        get: { Double(viewModel.rating) },
                        set: { viewModel.rating = Int($0) }
                    ), in: 0...100, step: 1)
                    Text("\(viewModel.rating)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }

                Spacer()
            }
            .padding(UIConstants.standardPadding)
            .background(Theme.baseBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(viewModel.apply(to: item))
                        dismiss()
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
            }
        }
    }
}

private struct SourcePickerSheet: View {
    let media: AniListMedia
    let episode: SoraEpisode?
    let sources: [SoraSource]
    let onPlay: (SoraSource?) -> Void
    let onDownload: (SoraSource) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAudio: String = "Sub"
    @State private var selectedQuality: String = "Auto"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Audio", selection: $selectedAudio) {
                        ForEach(audioOptions(), id: \.self) { a in
                            Text(a).tag(a)
                        }
                    }
                    Picker("Quality", selection: $selectedQuality) {
                        ForEach(qualityOptions(), id: \.self) { q in
                            Text(q).tag(q)
                        }
                    }
                }
                ForEach(filteredSources()) { source in
                    VStack(alignment: .leading, spacing: UIConstants.tinyPadding) {
                        Text("\(source.quality) - \(source.subOrDub)")
                        Text(source.format.uppercased())
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        HStack {
                            Button("Play") {
                                dismiss()
                                onPlay(bestSource())
                            }
                            .buttonStyle(.borderedProminent)
                            if source.format.lowercased() == "mp4" || source.format.lowercased() == "m3u8" {
                                Button("Download") {
                                    onDownload(source)
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Text("Download only for MP4/HLS")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, UIConstants.tinyPadding)
                }
            }
            .navigationTitle("\(media.title.best) ??? Ep \(episode?.number ?? 0)")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func audioKey(_ value: String) -> String {
        let v = value.lowercased()
        if v.contains("sub") || v.contains("jpn") || v.contains("jp") { return "sub" }
        if v.contains("dub") || v.contains("eng") { return "dub" }
        return "sub"
    }

    private func audioOptions() -> [String] {
        let options = Set(sources.map { audioKey($0.subOrDub) == "dub" ? "Dub" : "Sub" })
        return options.isEmpty ? ["Sub"] : Array(options)
    }

    private func qualityOptions() -> [String] {
        let key = audioKey(selectedAudio)
        let pool = sources.filter { audioKey($0.subOrDub) == key }
        let list = pool.isEmpty ? sources : pool
        let qualities = Set(list.map { $0.quality.isEmpty ? "Auto" : $0.quality })
        return qualities.sorted { a, b in
            if a == "Auto" { return true }
            if b == "Auto" { return false }
            return a > b
        }
    }

    private func filteredSources() -> [SoraSource] {
        let key = audioKey(selectedAudio)
        var list = sources.filter { audioKey($0.subOrDub) == key }
        if list.isEmpty { list = sources }
        if selectedQuality.lowercased() != "auto" {
            if let exact = list.first(where: { $0.quality.lowercased().contains(selectedQuality.lowercased()) }) {
                return [exact]
            }
        }
        return list
    }

    private func bestSource() -> SoraSource? {
        let filtered = filteredSources()
        let ranked = filtered.sorted { qualityRank($0.quality) > qualityRank($1.quality) }
        return ranked.first
    }

    private func qualityRank(_ q: String) -> Int {
        let digits = q.filter { $0.isNumber }
        return Int(digits) ?? 0
    }
}

private struct MatchPickerSheet: View {
    let media: AniListMedia
    @Binding var query: String
    let candidates: [SoraAnimeMatch]
    let isLoading: Bool
    let errorMessage: String?
    let onSearch: (String) -> Void
    let onSelect: (SoraAnimeMatch) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: UIConstants.mediumPadding) {
                        TextField("Search titles...", text: $query)
                            .textInputAutocapitalization(.words)
                            .disableAutocorrection(true)
                            .submitLabel(.search)
                            .onSubmit { onSearch(query) }
                        Button("Search") {
                            onSearch(query)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                if isLoading {
                    Text("Searching matches...")
                        .foregroundColor(.secondary)
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(candidates) { match in
                        HStack(spacing: UIConstants.interCardSpacing) {
                            if let url = match.imageURL {
                                CachedImage(url: url) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Color.white.opacity(0.1)
                                }
                                .frame(width: UIConstants.sourceRowImageWidth, height: UIConstants.sourceRowImageHeight)
                                .clipShape(RoundedRectangle(cornerRadius: UIConstants.smallCornerRadius, style: .continuous))
                            }
                            VStack(alignment: .leading, spacing: UIConstants.microPadding) {
                                Text(match.title)
                                    .font(.system(size: 16, weight: .semibold))
                                if let year = match.year {
                                    Text("\(year)")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button("Use") {
                                dismiss()
                                onSelect(match)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, UIConstants.tinyPadding)
                    }
                }
            }
            .navigationTitle("Match for \(media.title.best)")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}











