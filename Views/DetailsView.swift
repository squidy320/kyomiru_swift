import SwiftUI
import UIKit
import Observation

enum StreamSourcePreferenceResolver {
    static func audioKey(_ value: String) -> String {
        let normalized = value.lowercased()
        if normalized.contains("dub") || normalized.contains("eng") {
            return "dub"
        }
        return "sub"
    }

    static func normalizedAudioLabel(_ value: String) -> String {
        audioKey(value) == "dub" ? "Dub" : "Sub"
    }

    static func qualityRank(_ quality: String) -> Int {
        let digits = quality.filter { $0.isNumber }
        return Int(digits) ?? 0
    }

    static func sortedSources(_ sources: [SoraSource]) -> [SoraSource] {
        sources.sorted { lhs, rhs in
            let leftRank = qualityRank(lhs.quality)
            let rightRank = qualityRank(rhs.quality)
            if leftRank == rightRank {
                return lhs.subOrDub.localizedCaseInsensitiveCompare(rhs.subOrDub) == .orderedAscending
            }
            return leftRank > rightRank
        }
    }

    static func audioOptions(for sources: [SoraSource]) -> [String] {
        let options = Set(sources.map { normalizedAudioLabel($0.subOrDub) })
        return options.isEmpty ? ["Sub"] : Array(options).sorted()
    }

    static func qualityOptions(for sources: [SoraSource], selectedAudio: String) -> [String] {
        let key = audioKey(selectedAudio)
        let filtered = sources.filter { audioKey($0.subOrDub) == key }
        let pool = filtered.isEmpty ? sources : filtered
        var qualities = Set(pool.map { $0.quality.isEmpty ? "Auto" : $0.quality })
        qualities.insert("Auto")
        return qualities.sorted { lhs, rhs in
            if lhs == "Auto" { return true }
            if rhs == "Auto" { return false }
            return qualityRank(lhs) > qualityRank(rhs)
        }
    }

    static func filteredSources(
        from sources: [SoraSource],
        selectedAudio: String,
        selectedQuality: String
    ) -> [SoraSource] {
        let key = audioKey(selectedAudio)
        var filtered = sources.filter { audioKey($0.subOrDub) == key }
        if filtered.isEmpty {
            filtered = sources
        }
        if selectedQuality.lowercased() != "auto" {
            filtered = filtered.filter {
                !$0.quality.isEmpty && $0.quality.lowercased().contains(selectedQuality.lowercased())
            }
        }
        return sortedSources(filtered)
    }

    static func preferredSource(
        in sources: [SoraSource],
        preferredAudio: String,
        preferredQuality: String
    ) -> SoraSource? {
        let audioMatches = sources.filter { audioKey($0.subOrDub) == audioKey(preferredAudio) }
        guard !audioMatches.isEmpty else { return nil }
        if preferredQuality.lowercased() == "auto" {
            return sortedSources(audioMatches).first
        }
        return sortedSources(audioMatches).first {
            !$0.quality.isEmpty && $0.quality.lowercased().contains(preferredQuality.lowercased())
        }
    }
}

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
    @State private var playerStartAt: Double?
    @State private var listManagerModel = ListManagerViewModel(item: MediaItem(title: "", status: .planning))
    @State private var isLoadingMatch = false
    @State private var matchCandidates: [SoraAnimeMatch] = []
    @State private var matchError: String?
    @State private var matchQuery: String = ""
    @State private var selectedEpisodeTab: EpisodeTab = .currentSeries
    @State private var isBookmarked = false
    @State private var relatedSections: [AniListRelatedSection] = []
    @State private var episodeMetadata: [Int: EpisodeMetadata] = [:]
    @State private var episodeRatings: [Int: Double] = [:]
    @State private var streamingEpisodes: [AniListStreamingEpisode] = []
    @State private var tmdbHeroBackdropURL: URL?
    @State private var tmdbHeroLogoURL: URL?
    @State private var showImportPicker = false
    @State private var showImportReview = false
    @State private var importCandidates: [EpisodeImportCandidate] = []
    @State private var importMessage: String?
    @State private var downloadMessage: String?
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if isPad {
                ipadEpisodeLayout
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
                        detailHeroHeader

                        VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
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
                                RelationsCarouselView(sections: relatedSections)
                            }
                        }
                        .padding(.horizontal, UIConstants.standardPadding)
                        .padding(.top, UIConstants.smallPadding)
                        .padding(.bottom, UIConstants.bottomBarHeight)
                    }
                }
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
                PlayerView(
                    episode: episode,
                    sources: sources,
                    mediaId: media.id,
                    malId: media.idMal,
                    mediaTitle: media.title.best,
                    startAt: playerStartAt,
                    onRestoreAfterPictureInPicture: {
                        showPlayer = true
                    }
                )
            }
        }
        .sheet(isPresented: $showSourceSheet) {
            StreamSourcePickerSheet(
                media: media,
                episode: selectedEpisode,
                sources: sources,
                preferredAudio: appState.settings.defaultAudio,
                preferredQuality: appState.settings.defaultQuality,
                onPlay: { picked in
                    self.sources = [picked]
                    showPlayer = true
                },
                onDownload: { source in
                    enqueueDownload(source, episodeNumber: selectedEpisode?.number ?? 0)
                }
            )
        }
        .sheet(isPresented: $showImportPicker) {
            EpisodeImportPicker { urls in
                handleImportSelection(urls)
            } onCancel: {
                showImportPicker = false
            }
        }
        .sheet(isPresented: $showImportReview) {
            EpisodeImportReviewSheet(candidates: $importCandidates) { candidates in
                performImport(candidates: candidates)
            } onCancel: {
                showImportReview = false
            }
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
                Task {
                    await appState.syncListUpdate(updated, refresh: true)
                    isBookmarked = updated.status != MediaStatus.planning
                }
            }
            .presentationDetents([PresentationDetent.medium])
            .onAppear {
                listManagerModel = makeListManagerModel()
            }
        }
        .alert("Import", isPresented: Binding(
            get: { importMessage != nil },
            set: { _ in importMessage = nil }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importMessage ?? "")
        }
        .alert("Downloads", isPresented: Binding(
            get: { downloadMessage != nil },
            set: { _ in downloadMessage = nil }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(downloadMessage ?? "")
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

    private var ipadEpisodeLayout: some View {
        ZStack(alignment: .bottomLeading) {
            detailHeroBackdropFull

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
                    Spacer(minLength: UIScreen.main.bounds.height * 0.35)

                    ipadMetaBlock

                    actionRow

                    ipadGenreChips

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
                        ipadEpisodeCarousel
                        RelationsCarouselView(sections: relatedSections)
                    }
                }
                .padding(.horizontal, UIConstants.standardPadding)
                .padding(.bottom, UIConstants.bottomBarHeight)
            }
        }
        .ignoresSafeArea()
    }

    private var ipadMetaBlock: some View {
        VStack(alignment: .leading, spacing: UIConstants.tinyPadding) {
            if let logo = tmdbHeroLogoURL {
                AsyncImage(url: logo) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(maxWidth: 320)
            }

            Text(media.title.best)
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(2)

            HStack(spacing: UIConstants.tinyPadding) {
                if let eps = media.episodes, eps > 0 {
                    Text("\(eps) EPS")
                }
                if let studio = media.studios.first {
                    Text(studio)
                }
                if let score = media.averageScore {
                    Text("\(score)%")
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.textSecondary)
        }
    }

    private var ipadEpisodeCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: UIConstants.interCardSpacing) {
                ForEach(episodes, id: \.id) { episode in
                    let meta = episodeMetadata[episode.number]
                    let title = streamingTitle(for: episode) ?? meta?.title ?? "Episode \(episode.number)"
                    let thumb = streamingThumbnail(for: episode) ?? meta?.thumbnailURL ?? episodeThumbnailURL(for: episode)
                    Button {
                        playerStartAt = nil
                        selectEpisode(episode)
                    } label: {
                        EpisodeThumbCard(
                            title: title,
                            subtitle: "Episode \(episode.number)",
                            imageURL: thumb,
                            isWatched: isEpisodeWatched(episode.number),
                            isDownloaded: isEpisodeDownloaded(episode.number)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Mark Watched") {
                            Task { await appState.markEpisodeWatched(mediaId: media.id, episodeNumber: episode.number) }
                        }
                        Button("Mark Unwatched") {
                            Task { await appState.markEpisodeUnwatched(mediaId: media.id, episodeNumber: episode.number) }
                        }
                        Button("Download") {
                            openSourcePicker(for: episode)
                        }
                        Button("Play from Start") {
                            playerStartAt = 0
                            selectEpisode(episode)
                        }
                    }
                }
            }
            .padding(.horizontal, UIConstants.tinyPadding)
            .padding(.vertical, UIConstants.heroTopPadding)
        }
        .scrollClipDisabled()
    }

    private var detailHeroBackdropFull: some View {
        let height = UIScreen.main.bounds.height
        let topInset = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first?.safeAreaInsets.top }
            .first ?? 0
        return GeometryReader { proxy in
            let width = proxy.size.width
            let insetTop = proxy.safeAreaInsets.top
            let topFeatherHeight = max(24.0, insetTop * 0.6)
            let fallbackBackdrop = media.bannerURL ?? media.coverURL
            ZStack {
                Group {
                    if let url = tmdbHeroBackdropURL ?? fallbackBackdrop {
                        CachedImage(
                            url: url,
                            targetSize: CGSize(width: width, height: height + insetTop)
                        ) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Theme.surface
                        }
                    } else {
                        Theme.surface
                    }
                }
                .frame(width: width, height: height + insetTop)
                .clipped()
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [Color.clear, Color.black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: topFeatherHeight)
                        Color.black
                    }
                )

                LinearGradient(
                    colors: [Color.black.opacity(0.92), Color.black.opacity(0.45), Color.clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(width: width, height: height + insetTop)
            }
            .frame(width: width, height: height + insetTop)
            .clipped()
        }
        .frame(height: height)
        .offset(y: -topInset)
        .task(id: media.id) {
            tmdbHeroBackdropURL = await appState.services.metadataService.backdropURL(for: media)
            tmdbHeroLogoURL = await appState.services.metadataService.logoURL(for: media)
            let fallback = media.bannerURL ?? media.coverURL
            let urls = [tmdbHeroBackdropURL, fallback].compactMap { $0 }
            await ImageCache.shared.prefetch(urls: urls)
        }
    }

    private var detailHeroHeader: some View {
        let height = UIScreen.main.bounds.height * 0.5
        let topInset = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first?.safeAreaInsets.top }
            .first ?? 0
        return GeometryReader { proxy in
            let width = proxy.size.width
            let insetTop = proxy.safeAreaInsets.top
            let topFeatherHeight = max(24.0, insetTop * 0.6)
            let fallbackBackdrop = media.bannerURL ?? media.coverURL
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = tmdbHeroBackdropURL ?? fallbackBackdrop {
                        CachedImage(
                            url: url,
                            targetSize: CGSize(width: width, height: height + insetTop)
                        ) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Theme.surface
                        }
                    } else {
                        Theme.surface
                    }
                }
                .frame(width: width, height: height + insetTop)
                .clipped()
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [Color.clear, Color.black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: topFeatherHeight)
                        Color.black
                    }
                )

                LinearGradient(
                    colors: [Color.black.opacity(0.95), Color.black.opacity(0.5), Color.clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(width: width, height: height + insetTop)

                LinearGradient(
                    colors: [Color.black.opacity(0.55), Color.black.opacity(0.15), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: width, height: height + insetTop)

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.9)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: width, height: 120)
                .frame(maxHeight: .infinity, alignment: .bottom)

                VStack(alignment: .leading, spacing: 10) {
                    if let logo = tmdbHeroLogoURL {
                        CachedImage(
                            url: logo,
                            targetSize: CGSize(width: 320, height: 120)
                        ) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Color.clear
                        }
                        .frame(maxWidth: 220)
                    } else {
                        Text(media.title.best)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, UIConstants.standardPadding)
                .padding(.bottom, 24)
            }
            .frame(width: width, height: height + insetTop)
            .clipped()
        }
        .frame(height: height)
        .offset(y: -topInset)
        .task(id: media.id) {
            tmdbHeroBackdropURL = await appState.services.metadataService.backdropURL(for: media)
            tmdbHeroLogoURL = await appState.services.metadataService.logoURL(for: media)
            let fallback = media.bannerURL ?? media.coverURL
            let urls = [tmdbHeroBackdropURL, fallback].compactMap { $0 }
            await ImageCache.shared.prefetch(urls: urls)
        }
    }

    private var actionRow: some View {
        HStack(spacing: UIConstants.interCardSpacing) {
            Button {
                playResumeEpisode()
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
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: UIConstants.circleButtonSize, height: UIConstants.circleButtonSize)
                    .background(
                        Circle().fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)

            Button {
                downloadAllEpisodes()
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: UIConstants.circleButtonSize, height: UIConstants.circleButtonSize)
                    .background(
                        Circle().fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)

            Button {
                showImportPicker = true
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: UIConstants.circleButtonSize, height: UIConstants.circleButtonSize)
                    .background(
                        Circle().fill(Color.white.opacity(0.08))
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
                            playerStartAt = nil
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

    private var ipadGenreChips: some View {
        let genres = media.genres
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UIConstants.interCardSpacing) {
                ForEach(genres, id: \.self) { genre in
                    FilterChip(title: genre, isSelected: false, action: {})
                }
            }
        }
        .opacity(genres.isEmpty ? 0 : 1)
        .frame(height: genres.isEmpty ? 0 : nil)
    }

    private var episodeList: some View {
        LazyVStack(spacing: UIConstants.interCardSpacing) {
            ForEach(episodes, id: \.id) { episode in
                let meta = episodeMetadata[episode.number]
                EpisodeRowView(
                    episodeNumber: episode.number,
                    title: streamingTitle(for: episode) ?? meta?.title ?? "Episode \(episode.number)",
                    ratingText: ratingText(for: episode.number),
                    description: meta?.summary,
                    thumbnailURL: streamingThumbnail(for: episode) ?? meta?.thumbnailURL ?? episodeThumbnailURL(for: episode),
                    isPlayable: true,
                    isWatched: isEpisodeWatched(episode.number),
                    isDownloaded: isEpisodeDownloaded(episode.number),
                    isNew: false,
                    onTap: {
                        playerStartAt = nil
                        selectEpisode(episode)
                    }
                )
                .contextMenu {
                    Button("Mark Watched") {
                        Task { await appState.markEpisodeWatched(mediaId: media.id, episodeNumber: episode.number) }
                    }
                    Button("Mark Unwatched") {
                        Task { await appState.markEpisodeUnwatched(mediaId: media.id, episodeNumber: episode.number) }
                    }
                    Button("Download") {
                        openSourcePicker(for: episode)
                    }
                    Button("Play from Start") {
                        playerStartAt = 0
                        selectEpisode(episode)
                    }
                }
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
            isLoading = false

            if let cached = appState.services.episodeMetadataService.cachedEpisodes(for: media, episodes: result.episodes) {
                episodeMetadata = cached
            }

            Task { @MainActor in
                let meta = await appState.services.episodeMetadataService.fetchEpisodes(for: media, episodes: result.episodes)
                episodeMetadata = meta
            }
            Task { @MainActor in
                let firstEpisodeNumber = result.episodes.map(\.number).min()
                let ratings = await appState.services.ratingService.ratingsForSeason(
                    media: media,
                    seasonNumber: 1,
                    firstEpisodeNumber: firstEpisodeNumber
                )
                episodeRatings = ratings
            }
            Task { @MainActor in
                do {
                    streamingEpisodes = try await appState.services.aniListClient.streamingEpisodes(mediaId: media.id)
                } catch {
                    AppLog.error(.network, "streaming episodes load failed mediaId=\(media.id) \(error.localizedDescription)")
                    streamingEpisodes = []
                }
            }
        } catch {
            errorMessage = "Failed to load episodes."
            AppLog.error(.network, "details episodes load failed mediaId=\(media.id) \(error.localizedDescription)")
            isLoading = false
        }
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
                    presentSelectedEpisode()
                    isLoadingSources = false
                    return
                }
                async let sourceTask = appState.services.episodeService.loadSources(for: episode)
                async let skipSegmentsTask: [AniSkipSegment] = {
                    guard let malId = media.idMal else { return [] }
                    return await appState.services.aniSkipService.fetchSkipSegments(malId: malId, episode: episode.number)
                }()
                sources = try await sourceTask
                let skipSegments = await skipSegmentsTask
                if !skipSegments.isEmpty, let malId = media.idMal {
                    appState.services.downloadManager.storeSkipSegments(skipSegments, malId: malId, episode: episode.number)
                }
                if sources.isEmpty {
                    errorMessage = "No streams available."
                } else {
                    handleLoadedSourcesForPlayback(sources, episode: episode)
                }
            } catch {
                errorMessage = "Failed to load streams."
                AppLog.error(.network, "sources load failed ep=\(episode.number) \(error.localizedDescription)")
            }
            isLoadingSources = false
        }
    }

    private func openSourcePicker(for episode: SoraEpisode) {
        playerStartAt = nil
        selectedEpisode = episode
        Task {
            isLoadingSources = true
            do {
                let sources = try await appState.services.episodeService.loadSources(for: episode)
                if sources.isEmpty {
                    errorMessage = "No streams available."
                } else {
                    self.sources = sources
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
        playerStartAt = nil
        selectEpisode(first)
    }

    private func playResumeEpisode() {
        if let lastNumber = PlaybackHistoryStore.shared.lastEpisodeNumber(for: media.id),
           let episode = episodes.first(where: { $0.number == lastNumber }),
           let position = PlaybackHistoryStore.shared.position(for: episode.id),
           position > 0 {
            playerStartAt = position
            selectEpisode(episode)
            return
        }
        playFirstEpisode()
    }

    private func presentSelectedEpisode() {
        guard selectedEpisode != nil, !sources.isEmpty else { return }
        showPlayer = true
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

    private func ratingText(for number: Int) -> String? {
        guard let rating = episodeRatings[number], rating > 0 else { return nil }
        return "⭐ \(String(format: "%.1f", rating))"
    }

    private func streamingTitle(for episode: SoraEpisode) -> String? {
        if let match = streamingEpisodes.first(where: { $0.episodeNumber == episode.number }) {
            return match.title
        }
        return nil
    }

    private func streamingThumbnail(for episode: SoraEpisode) -> URL? {
        if let match = streamingEpisodes.first(where: { $0.episodeNumber == episode.number }) {
            return match.thumbnailURL
        }
        return nil
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
            relatedSections = try await appState.services.aniListClient.relatedSections(
                mediaId: media.id,
                token: appState.authState.token
            )
        } catch {
            relatedSections = []
            AppLog.error(.network, "related sections load failed mediaId=\(media.id) \(error.localizedDescription)")
        }
    }

    private func downloadAllEpisodes() {
        AppLog.debug(.downloads, "download all start mediaId=\(media.id) count=\(episodes.count)")
        Task {
            appState.services.offlineManager.beginDownload(for: detailItem)
            var queued = 0
            var skipped = 0
            for ep in episodes {
                do {
                    let sources = try await appState.services.episodeService.loadSources(for: ep)
                    guard let preferred = preferredSource(in: sources) else {
                        skipped += 1
                        continue
                    }
                    enqueueDownload(preferred, episodeNumber: ep.number)
                    queued += 1
                } catch {
                    continue
                }
            }
            appState.services.offlineManager.endDownload(for: detailItem)
            await MainActor.run {
                if skipped > 0 {
                    downloadMessage = "Queued \(queued) episode(s). Skipped \(skipped) because your saved audio/quality preference was unavailable."
                } else if queued > 0 {
                    downloadMessage = "Queued \(queued) episode(s) using your saved stream preference."
                } else {
                    downloadMessage = "No episodes matched your saved audio/quality preference."
                }
            }
        }
    }

    private func handleLoadedSourcesForPlayback(_ loadedSources: [SoraSource], episode: SoraEpisode) {
        self.sources = loadedSources
        if let preferred = preferredSource(in: loadedSources) {
            self.sources = [preferred]
            selectedEpisode = episode
            presentSelectedEpisode()
        } else {
            showSourceSheet = true
        }
    }

    private func preferredSource(in loadedSources: [SoraSource]) -> SoraSource? {
        StreamSourcePreferenceResolver.preferredSource(
            in: loadedSources,
            preferredAudio: appState.settings.defaultAudio,
            preferredQuality: appState.settings.defaultQuality
        )
    }

    private func enqueueDownload(_ source: SoraSource, episodeNumber: Int) {
        if source.format.lowercased() == "m3u8" {
            appState.services.downloadManager.enqueueHLS(
                title: media.title.best,
                episode: episodeNumber,
                url: source.url,
                headers: source.headers,
                media: detailItem
            )
        } else {
            appState.services.downloadManager.enqueue(
                title: media.title.best,
                episode: episodeNumber,
                url: source.url,
                media: detailItem
            )
        }
    }

    private func handleImportSelection(_ urls: [URL]) {
        showImportPicker = false
        let candidates = appState.services.downloadManager.buildImportCandidates(urls: urls)
        if candidates.isEmpty {
            importMessage = "No supported video files were selected."
            return
        }
        importCandidates = candidates
        if candidates.allSatisfy({ $0.episodeNumber != nil }) {
            performImport(candidates: candidates)
        } else {
            showImportReview = true
        }
    }

    private func performImport(candidates: [EpisodeImportCandidate]) {
        showImportReview = false
        Task { @MainActor in
            let result = await appState.services.downloadManager.importEpisodes(media: detailItem, candidates: candidates)
            if !result.failed.isEmpty {
                importMessage = "Imported \(result.imported), skipped \(result.skipped), failed \(result.failed.count)."
            } else {
                importMessage = "Imported \(result.imported), skipped \(result.skipped)."
            }
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
    @State private var tmdbLookupComplete = false

    var body: some View {
        let useTMDB = appState.settings.cardImageSource == .tmdb
        let resolvedURL: URL? = {
            if useTMDB {
                return tmdbLookupComplete ? (imdbImageURL ?? card.imageURL) : imdbImageURL
            }
            return card.imageURL
        }()
        HStack(alignment: .top, spacing: UIConstants.interCardSpacing) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: UIConstants.cornerRadiusSmall, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: UIConstants.episodeThumbWidth, height: UIConstants.episodeThumbHeight)
                if let resolved = resolvedURL {
                    CachedImage(
                        url: resolved,
                        targetSize: CGSize(width: UIConstants.episodeThumbWidth, height: UIConstants.episodeThumbHeight)
                    ) { img in
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
        .task(id: "\(card.relatedMedia?.id ?? 0)-\(appState.settings.cardImageSource.rawValue)") {
            guard let media = card.relatedMedia else { return }
            if useTMDB {
                imdbImageURL = await appState.services.metadataService.backdropURL(for: media)
                tmdbLookupComplete = true
            } else {
                imdbImageURL = nil
                tmdbLookupComplete = false
            }
        }
    }
}

private struct EpisodeThumbCard: View {
    let title: String
    let subtitle: String
    let imageURL: URL?
    let isWatched: Bool
    let isDownloaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIConstants.tinyPadding) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: UIConstants.cornerRadiusSmall, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 260, height: 140)
                if let imageURL {
                    CachedImage(
                        url: imageURL,
                        targetSize: CGSize(width: 260, height: 140)
                    ) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.white.opacity(0.08)
                    }
                    .frame(width: 260, height: 140)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: UIConstants.cornerRadiusSmall, style: .continuous))
                }
                if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(
                            Circle().fill(Color.black.opacity(0.4))
                        )
                        .padding(6)
                }
            }

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(isWatched ? 0.5 : 1.0))
                .lineLimit(2)

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 260, alignment: .leading)
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
                                CachedImage(
                                    url: url,
                                    targetSize: CGSize(width: UIConstants.sourceRowImageWidth, height: UIConstants.sourceRowImageHeight)
                                ) { img in
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

struct StreamSourcePickerSheet: View {
    let media: AniListMedia
    let episode: SoraEpisode?
    let sources: [SoraSource]
    let preferredAudio: String
    let preferredQuality: String
    let onPlay: (SoraSource) -> Void
    let onDownload: (SoraSource) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedAudio: String
    @State private var selectedQuality: String
    @State private var selectedSourceID: String?

    init(
        media: AniListMedia,
        episode: SoraEpisode?,
        sources: [SoraSource],
        preferredAudio: String,
        preferredQuality: String,
        onPlay: @escaping (SoraSource) -> Void,
        onDownload: @escaping (SoraSource) -> Void
    ) {
        self.media = media
        self.episode = episode
        self.sources = sources
        self.preferredAudio = preferredAudio
        self.preferredQuality = preferredQuality
        self.onPlay = onPlay
        self.onDownload = onDownload
        _selectedAudio = State(initialValue: preferredAudio)
        _selectedQuality = State(initialValue: preferredQuality)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Saved Preference") {
                    Picker("Audio", selection: $selectedAudio) {
                        ForEach(audioOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    Picker("Quality", selection: $selectedQuality) {
                        ForEach(qualityOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    if exactPreferredSource == nil {
                        Text("Your saved \(preferredAudio) / \(preferredQuality) preference is not available for this episode.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                Section("Sources") {
                    if filteredSources.isEmpty {
                        Text("No sources match these filters.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(filteredSources) { source in
                            Button {
                                selectedSourceID = source.id
                            } label: {
                                HStack(spacing: UIConstants.interCardSpacing) {
                                    VStack(alignment: .leading, spacing: UIConstants.tinyPadding) {
                                        Text("\(source.quality) - \(source.subOrDub)")
                                            .foregroundColor(.primary)
                                        Text(source.format.uppercased())
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if selectedSourceID == source.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.white)
                                    } else if exactPreferredSource?.id == source.id {
                                        Text("Preferred")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, UIConstants.tinyPadding)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Button("Play") {
                        guard let source = currentSource else { return }
                        dismiss()
                        onPlay(source)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(currentSource == nil)

                    if let source = currentSource,
                       source.format.lowercased() == "mp4" || source.format.lowercased() == "m3u8" {
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
            .navigationTitle("\(media.title.best) - Ep \(episode?.number ?? 0)")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear(perform: refreshSelection)
            .onChange(of: selectedAudio) { _, _ in
                refreshSelection()
            }
            .onChange(of: selectedQuality) { _, _ in
                refreshSelection()
            }
        }
    }

    private var audioOptions: [String] {
        StreamSourcePreferenceResolver.audioOptions(for: sources)
    }

    private var qualityOptions: [String] {
        StreamSourcePreferenceResolver.qualityOptions(for: sources, selectedAudio: selectedAudio)
    }

    private var filteredSources: [SoraSource] {
        StreamSourcePreferenceResolver.filteredSources(
            from: sources,
            selectedAudio: selectedAudio,
            selectedQuality: selectedQuality
        )
    }

    private var exactPreferredSource: SoraSource? {
        StreamSourcePreferenceResolver.preferredSource(
            in: sources,
            preferredAudio: preferredAudio,
            preferredQuality: preferredQuality
        )
    }

    private var currentSource: SoraSource? {
        if let selectedSourceID,
           let selected = filteredSources.first(where: { $0.id == selectedSourceID }) {
            return selected
        }
        return filteredSources.first
    }

    private func refreshSelection() {
        if !audioOptions.contains(selectedAudio) {
            selectedAudio = audioOptions.first ?? preferredAudio
            return
        }

        let validQualities = qualityOptions
        if !validQualities.contains(selectedQuality) {
            selectedQuality = validQualities.contains(preferredQuality) ? preferredQuality : (validQualities.first ?? "Auto")
            return
        }

        if let selectedSourceID,
           filteredSources.contains(where: { $0.id == selectedSourceID }) {
            return
        }

        if let exact = exactPreferredSource,
           filteredSources.contains(where: { $0.id == exact.id }) {
            selectedSourceID = exact.id
        } else {
            selectedSourceID = filteredSources.first?.id
        }
    }
}











