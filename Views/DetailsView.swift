import SwiftUI
import UIKit
import Observation

enum StreamSourcePreferenceResolver {
    static func audioKey(_ value: String) -> String {
        let normalized = value.lowercased()
        if normalized.contains("manual") {
            return "manual"
        }
        if normalized.contains("any") {
            return "any"
        }
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

    static func hasExactPreferredSource(
        in sources: [SoraSource],
        preferredAudio: String,
        preferredQuality: String
    ) -> Bool {
        if audioKey(preferredAudio) == "manual" || preferredQuality.lowercased() == "manual" {
            return false
        }
        let audioMatches = sources.filter { audioKey($0.subOrDub) == audioKey(preferredAudio) }
        guard !audioMatches.isEmpty else { return false }
        if preferredQuality.lowercased() == "auto" {
            return true
        }
        return audioMatches.contains {
            !$0.quality.isEmpty && $0.quality.lowercased().contains(preferredQuality.lowercased())
        }
    }

    static func streamVariantRank(_ source: SoraSource) -> Int {
        let url = source.url.absoluteString.lowercased()
        if url.contains("/owo.m3u8") { return 2 }
        if url.contains("/uwu.m3u8") { return 0 }
        return 1
    }

    static func sortedSources(_ sources: [SoraSource]) -> [SoraSource] {
        sources.sorted { lhs, rhs in
            let leftRank = qualityRank(lhs.quality)
            let rightRank = qualityRank(rhs.quality)
            if leftRank == rightRank {
                let leftVariant = streamVariantRank(lhs)
                let rightVariant = streamVariantRank(rhs)
                if leftVariant != rightVariant {
                    return leftVariant > rightVariant
                }
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
        let filtered = key == "any" || key == "manual" ? sources : sources.filter { audioKey($0.subOrDub) == key }
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
        var filtered = key == "any" || key == "manual" ? sources : sources.filter { audioKey($0.subOrDub) == key }
        if filtered.isEmpty {
            filtered = sources
        }
        if selectedQuality.lowercased() != "auto" && selectedQuality.lowercased() != "manual" {
            let exactMatches = filtered.filter {
                !$0.quality.isEmpty && $0.quality.lowercased().contains(selectedQuality.lowercased())
            }
            if !exactMatches.isEmpty {
                filtered = exactMatches
            }
        }
        return sortedSources(filtered)
    }

    static func preferredSource(
        in sources: [SoraSource],
        preferredAudio: String,
        preferredQuality: String
    ) -> SoraSource? {
        if audioKey(preferredAudio) == "manual" || preferredQuality.lowercased() == "manual" {
            return nil
        }
        let key = audioKey(preferredAudio)
        let audioMatches = key == "any" ? sources : sources.filter { audioKey($0.subOrDub) == key }
        let pool = audioMatches.isEmpty ? sources : audioMatches
        guard !pool.isEmpty else { return nil }
        if preferredQuality.lowercased() == "auto" {
            return sortedSources(pool).first
        }
        if let exact = sortedSources(pool).first(where: {
            !$0.quality.isEmpty && $0.quality.lowercased().contains(preferredQuality.lowercased())
        }) {
            return exact
        }
        let preferredRank = qualityRank(preferredQuality)
        if preferredRank <= 0 {
            return sortedSources(pool).first
        }
        return sortedSources(pool).min { lhs, rhs in
            let leftDistance = abs(qualityRank(lhs.quality) - preferredRank)
            let rightDistance = abs(qualityRank(rhs.quality) - preferredRank)
            if leftDistance != rightDistance {
                return leftDistance < rightDistance
            }
            return qualityRank(lhs.quality) > qualityRank(rhs.quality)
        }
    }
}

struct DetailsView: View {
    let media: AniListMedia
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var episodes: [SoraEpisode] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedEpisode: SoraEpisode?
    @State private var sources: [SoraSource] = []
    @State private var showPlayer = false
    @State private var isLoadingSources = false
    @State private var showSourceSheet = false
    @State private var showMatchSheet = false
    @State private var showTMDBMatchSheet = false
    @State private var showListManager = false
    @State private var playerStartAt: Double?
    @State private var listManagerModel = ListManagerViewModel(item: MediaItem(title: "", status: .planning))
    @State private var listTrackingEntry: AniListTrackingEntry?
    @State private var isLoadingMatch = false
    @State private var matchCandidates: [SoraAnimeMatch] = []
    @State private var matchError: String?
    @State private var matchQuery: String = ""
    @State private var activeMatchQuery: String?
    @State private var isLoadingTMDBMatch = false
    @State private var tmdbMatchCandidates: [TMDBSearchResult] = []
    @State private var tmdbMatchError: String?
    @State private var tmdbMatchQuery: String = ""
    @State private var tmdbManualOverride: TMDBManualOverride?
    @State private var selectedEpisodeTab: EpisodeTab = .currentSeries
    @State private var isBookmarked = false
    @State private var relatedSections: [AniListRelatedSection] = []
    @State private var episodeMetadata: [Int: EpisodeMetadata] = [:]
    @State private var episodeRatings: [Int: Double] = [:]
    @State private var streamingEpisodes: [AniListStreamingEpisode] = []
    @State private var episodeLoadGeneration = 0
    @State private var matchSearchGeneration = 0
    @State private var tmdbMatchSearchGeneration = 0
    @State private var tmdbHeroBackdropURL: URL?
    @State private var tmdbHeroLogoURL: URL?
    @State private var tmdbHeroLookupComplete = false
    @State private var heroAtmosphere: HeroAtmosphere = .fallback
    @State private var showImportPicker = false
    @State private var showImportReview = false
    @State private var importCandidates: [EpisodeImportCandidate] = []
    @State private var importMessage: String?
    @State private var downloadMessage: String?
    @State private var initialLoadTask: Task<Void, Never>?
    @State private var isInitialLoadInProgress = true
    @State private var lastEpisodeRefreshAt: Date?
    private var isPad: Bool { PlatformSupport.prefersTabletLayout }
    private var useComfortableLayout: Bool { appState.settings.useComfortableLayout }
    private var screenSpacing: CGFloat { UIConstants.interCardSpacing + (useComfortableLayout ? 2 : 0) }
    private var screenPadding: CGFloat { UIConstants.standardPadding + (useComfortableLayout ? 4 : 0) }

    var body: some View {
        screenContent
    }

    private var currentHeroBackdropURL: URL? {
        tmdbHeroBackdropURL ?? media.bannerURL ?? media.coverURL
    }

    private var activeHeroAtmosphere: HeroAtmosphere {
        (isPad || !appState.settings.enableBannerAtmosphere) ? .fallback : heroAtmosphere
    }
    private var bannerAtmosphereEnabled: Bool {
        !isPad && appState.settings.enableBannerAtmosphere
    }

    private var detailContent: some View {
        ZStack {
            Group {
                if bannerAtmosphereEnabled {
                    LinearGradient(
                        colors: [
                            activeHeroAtmosphere.baseBackground,
                            activeHeroAtmosphere.bottomFeather.opacity(0.50),
                            activeHeroAtmosphere.bottomFeather.opacity(0.38),
                            activeHeroAtmosphere.bottomFeather.opacity(0.24),
                            activeHeroAtmosphere.bottomFeather.opacity(0.12)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                } else {
                    Theme.baseBackground.ignoresSafeArea()
                }
            }
            if shouldShowInitialLoadingScreen {
                loadingScreen
            } else if isPad {
                ipadEpisodeLayout
            } else {
                ZStack(alignment: .top) {
                    phoneFixedHeroBanner
                        .ignoresSafeArea(edges: .top)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear
                                .frame(height: detailHeroHeight(for: UIScreen.main.bounds.height) * 0.62)

                            VStack(alignment: .leading, spacing: screenSpacing) {
                                phoneHeroContentBlock

                                actionRow
                            }
                            .padding(.horizontal, screenPadding)
                            .padding(.top, UIConstants.smallPadding)

                            phoneScrollableContent
                        }
                    }
                    .ignoresSafeArea(edges: .top)
                    .refreshable {
                        await refreshDetailContent()
                    }
                }
            }
        }
    }

    private var shouldShowInitialLoadingScreen: Bool {
        isInitialLoadInProgress && episodes.isEmpty && errorMessage == nil
    }

    private var loadingScreen: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.25)

            Text("Loading details...")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.baseBackground.ignoresSafeArea())
    }

    private var phoneScrollableContent: some View {
        VStack(alignment: .leading, spacing: screenSpacing) {
            if isLoading && episodes.isEmpty {
                GlassCard {
                    Text("Loading episodes...")
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                if let errorMessage {
                    GlassCard {
                        Text(errorMessage)
                            .foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                episodeList
                RelationsCarouselView(sections: relatedSections)
            }
        }
        .padding(.horizontal, screenPadding)
        .padding(.top, UIConstants.smallPadding)
        .padding(.bottom, UIConstants.bottomBarHeight)
        .background(Color.clear)
    }

    private var modalContent: some View {
        detailContent
        .navigationBarBackButtonHidden(isPad)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .applyIf(isPad) { view in
            view.toolbar(.hidden, for: .navigationBar)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task(id: currentHeroBackdropURL) {
            if !isPad {
                await refreshHeroAtmosphere()
            }
        }
        .task(id: media.id) {
            startInitialLoad()
        }
        .onAppear {
            refreshEpisodesIfNeededOnResume()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            refreshEpisodesIfNeededOnResume()
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
                        await MainActor.run {
                            isLoadingMatch = true
                            matchError = nil
                        }
                        do {
                            _ = try await appState.services.episodeService.applyManualMatch(media: media, match: match)
                            AppLog.debug(.matching, "manual match selected mediaId=\(media.id) session=\(match.session)")
                            await MainActor.run {
                                isLoadingMatch = false
                                showMatchSheet = false
                            }
                            await loadEpisodes()
                        } catch is CancellationError {
                            await MainActor.run {
                                isLoadingMatch = false
                            }
                        } catch {
                            await MainActor.run {
                                isLoadingMatch = false
                                matchError = error.localizedDescription
                            }
                            AppLog.error(.matching, "manual match select failed mediaId=\(media.id) session=\(match.session) \(error.localizedDescription)")
                        }
                    }
                }
            )
        }
        .sheet(isPresented: $showTMDBMatchSheet) {
            TMDBMatchSheet(
                media: media,
                currentOverride: tmdbManualOverride,
                query: $tmdbMatchQuery,
                candidates: tmdbMatchCandidates,
                isLoading: isLoadingTMDBMatch,
                errorMessage: tmdbMatchError,
                onSearch: { term in
                    performTMDBMatchSearch(query: term)
                },
                loadSeasons: { candidate in
                    await appState.services.tmdbMatchingService.fetchSeasonChoices(for: media, showId: candidate.id, mediaType: candidate.mediaType)
                },
                onSave: { choice, additionalOffset, parentSeriesId in
                    Task {
                        let resolvedOffset = choice.episodeOffset + additionalOffset
                        await appState.services.metadataService.saveManualTMDBMatch(
                            media: media,
                            showId: choice.showId,
                            mediaType: choice.mediaType,
                            seasonNumber: choice.tmdbSeasonNumber,
                            episodeOffset: resolvedOffset,
                            showTitle: choice.showTitle,
                            seasonLabel: choice.displayLabel,
                            parentSeriesId: parentSeriesId
                        )
                        await reloadTMDBOverrideDependentState()
                    }
                },
                onClear: {
                    Task {
                        appState.services.metadataService.clearManualTMDBMatch(for: media)
                        await reloadTMDBOverrideDependentState()
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
                Task {
                    await refreshTrackingEntryForSheet()
                }
            }
        }
    }

    private var screenContent: some View {
        modalContent
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
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                detailHeroBackdropFull(size: proxy.size, safeArea: proxy.safeAreaInsets)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
                        Spacer(minLength: proxy.size.height * 0.35)

                        ipadMetaBlock

                        actionRow

                        ipadGenreChips

                        if isLoading && episodes.isEmpty {
                            GlassCard {
                                Text("Loading episodes...")
                                    .foregroundColor(Theme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            if let errorMessage {
                                GlassCard {
                                    Text(errorMessage)
                                        .foregroundColor(Theme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            ipadEpisodeCarousel
                            RelationsCarouselView(sections: relatedSections)
                        }
                    }
                    .padding(.horizontal, UIConstants.standardPadding)
                    .padding(.bottom, UIConstants.bottomBarHeight)
                }
                .refreshable {
                    await refreshDetailContent()
                }
            }
        }
        .ignoresSafeArea()
#if targetEnvironment(macCatalyst)
        .toolbar(.hidden, for: .navigationBar)
#endif
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
            } else {
                Text(media.title.best)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
            }

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
                    let title = meta?.title ?? streamingTitle(for: episode) ?? "Episode \(episode.number)"
                    let thumb = meta?.thumbnailURL ?? streamingThumbnail(for: episode) ?? episodeThumbnailURL(for: episode)
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
                            downloadEpisodeUsingPreferences(episode)
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

    private func detailHeroBackdropFull(size: CGSize, safeArea: EdgeInsets) -> some View {
        let width = size.width
        let height = size.height
        let insetTop = safeArea.top
        let fallbackBackdrop = media.bannerURL ?? media.coverURL
        return ZStack {
            Group {
                if let url = tmdbHeroBackdropURL ?? fallbackBackdrop {
                    CachedImage(
                        url: url,
                        targetSize: CGSize(width: width, height: height + insetTop)
                    ) { image in
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: width, height: height + insetTop, alignment: .bottom)
                    } placeholder: {
                        Theme.surface
                    }
                } else {
                    Theme.surface
                }
            }
            .frame(width: width, height: height + insetTop)
            .clipped()

            LinearGradient(
                colors: bannerAtmosphereEnabled
                    ? [activeHeroAtmosphere.bottomFeather.opacity(0.92), activeHeroAtmosphere.bottomFeather.opacity(0.45), Color.clear]
                    : [Color.black.opacity(0.92), Color.black.opacity(0.45), Color.clear],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(width: width, height: height + insetTop)

            LinearGradient(
                colors: bannerAtmosphereEnabled
                    ? [activeHeroAtmosphere.topFeather.opacity(0.22), activeHeroAtmosphere.topFeather.opacity(0.08), Color.clear]
                    : [Color.black.opacity(0.18), Color.black.opacity(0.06), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: width, height: max(44, insetTop + 34))
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: width, height: height + insetTop)
        .clipped()
        .offset(y: -insetTop)
    }

    private var detailHeroHeader: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let insetTop = proxy.safeAreaInsets.top
            let fallbackBackdrop = media.bannerURL ?? media.coverURL
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = tmdbHeroBackdropURL ?? fallbackBackdrop {
                        CachedImage(
                            url: url,
                            targetSize: CGSize(width: width, height: height + insetTop)
                        ) { image in
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: width, height: height + insetTop, alignment: .bottom)
                        } placeholder: {
                            Theme.surface
                        }
                    } else {
                        Theme.surface
                    }
                }
                .frame(width: width, height: height + insetTop)
                .clipped()

                LinearGradient(
                    colors: [Color.black.opacity(0.52), Color.black.opacity(0.16), Color.clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(width: width, height: height + insetTop)

                LinearGradient(
                    colors: [Color.black.opacity(0.18), Color.black.opacity(0.06), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: width, height: height + insetTop)

                LinearGradient(
                    colors: [Color.black.opacity(0.20), Color.black.opacity(0.08), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: width, height: max(44, insetTop + 34))
                .frame(maxHeight: .infinity, alignment: .top)

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.32)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: width, height: 104)
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

                    phoneHeroMetaBlock
                }
                .padding(.horizontal, UIConstants.standardPadding)
                .padding(.bottom, 24)

            }
            .frame(width: width, height: height + insetTop)
            .clipped()
            .offset(y: -insetTop)
        }
        .frame(height: detailHeroHeight(for: UIScreen.main.bounds.height))
#if targetEnvironment(macCatalyst)
        .toolbar(.hidden, for: .navigationBar)
#endif
    }

    private var phoneFixedHeroBanner: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let insetTop = proxy.safeAreaInsets.top
            let fallbackBackdrop = media.bannerURL ?? media.coverURL
            ZStack(alignment: .topLeading) {
                Group {
                    if let url = tmdbHeroBackdropURL ?? fallbackBackdrop {
                        CachedImage(
                            url: url,
                            targetSize: CGSize(width: width, height: height + insetTop)
                        ) { image in
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: width, height: height + insetTop, alignment: .bottom)
                        } placeholder: {
                            Theme.surface
                        }
                    } else {
                        Theme.surface
                    }
                }
                .frame(width: width, height: height + insetTop)
                .clipped()

                LinearGradient(
                    colors: [
                        activeHeroAtmosphere.bottomFeather.opacity(0.52),
                        activeHeroAtmosphere.bottomFeather.opacity(0.16),
                        Color.clear
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(width: width, height: height + insetTop)

                LinearGradient(
                    colors: [
                        activeHeroAtmosphere.topFeather.opacity(0.14),
                        activeHeroAtmosphere.topFeather.opacity(0.06),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: width, height: height + insetTop)

                LinearGradient(
                    colors: [
                        activeHeroAtmosphere.topFeather.opacity(0.10),
                        activeHeroAtmosphere.topFeather.opacity(0.04),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: width, height: max(44, insetTop + 34))
                .frame(maxHeight: .infinity, alignment: .top)

                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.clear,
                        activeHeroAtmosphere.bottomFeather.opacity(0.04),
                        activeHeroAtmosphere.bottomFeather.opacity(0.10),
                        activeHeroAtmosphere.bottomFeather.opacity(0.22),
                        activeHeroAtmosphere.bottomFeather.opacity(0.38),
                        activeHeroAtmosphere.bottomFeather.opacity(0.52)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: width, height: 200)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(width: width, height: height + insetTop)
            .clipped()
            .offset(y: -insetTop)
        }
        .frame(height: detailHeroHeight(for: UIScreen.main.bounds.height))
    }

    private var phoneHeroContentBlock: some View {
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

            phoneHeroMetaBlock
        }
        .padding(.bottom, 8)
    }

    private func detailHeroHeight(for screenHeight: CGFloat) -> CGFloat {
        if isPad {
            return min(max(screenHeight * 0.5, 360), 560)
        }
        return min(max(screenHeight * 0.5, 380), 500)
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

    private var phoneHeroMetaBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            let primary = phoneHeroPrimaryInfo
            if !primary.isEmpty {
                Text(primary)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
            }

            let genres = phoneHeroGenreInfo
            if !genres.isEmpty {
                Text(genres)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    private var episodeList: some View {
        LazyVStack(spacing: UIConstants.interCardSpacing) {
            ForEach(episodes, id: \.id) { episode in
                let meta = episodeMetadata[episode.number]
                EpisodeRowView(
                    episodeNumber: episode.number,
                    title: meta?.title ?? streamingTitle(for: episode) ?? "Episode \(episode.number)",
                    ratingText: ratingText(for: episode.number),
                    description: meta?.summary,
                    thumbnailURL: meta?.thumbnailURL ?? streamingThumbnail(for: episode) ?? episodeThumbnailURL(for: episode),
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
                        downloadEpisodeUsingPreferences(episode)
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
        let scoreFormat = appState.authState.user?.scoreFormat ?? .point100
        if let existing = appState.services.libraryStore.item(forExternalId: media.id) {
            return ListManagerViewModel(
                item: existing,
                trackingEntry: listTrackingEntry,
                scoreFormat: scoreFormat
            )
        }
        return ListManagerViewModel(
            item: detailItem,
            trackingEntry: listTrackingEntry,
            scoreFormat: scoreFormat
        )
    }

    private func loadEpisodes(forceRefresh: Bool = false) async {
        episodeLoadGeneration += 1
        let loadGeneration = episodeLoadGeneration
        let shouldShowInlineLoading = episodes.isEmpty
        isLoading = shouldShowInlineLoading
        errorMessage = nil
        do {
            if forceRefresh {
                appState.services.metadataService.invalidateTMDBCaches(for: media)
            }
            let result = try await fetchEpisodesDetached(for: media, forceRefresh: forceRefresh)
            guard loadGeneration == episodeLoadGeneration else { return }
            episodes = result.episodes
            if let cached = appState.services.episodeMetadataService.cachedEpisodes(for: media, episodes: result.episodes) {
                episodeMetadata = cached
            }

            async let metadataTask = appState.services.episodeMetadataService.fetchEpisodes(for: media, episodes: result.episodes)
            async let ratingsTask = appState.services.ratingService.ratingsForSeason(
                media: media,
                seasonNumber: 1,
                firstEpisodeNumber: result.episodes.map(\.number).min()
            )
            async let streamingEpisodesTask: [AniListStreamingEpisode] = {
                do {
                    return try await appState.services.aniListClient.streamingEpisodes(mediaId: media.id)
                } catch {
                    AppLog.error(.network, "streaming episodes load failed mediaId=\(media.id) \(error.localizedDescription)")
                    return []
                }
            }()

            let metadata = await metadataTask
            let ratings = await ratingsTask
            let loadedStreamingEpisodes = await streamingEpisodesTask
            guard loadGeneration == episodeLoadGeneration else { return }
            episodeMetadata = metadata
            episodeRatings = ratings
            streamingEpisodes = loadedStreamingEpisodes
            lastEpisodeRefreshAt = Date()
            isLoading = false
        } catch is CancellationError {
            guard loadGeneration == episodeLoadGeneration else { return }
            isLoading = false
            AppLog.debug(.network, "details episodes load cancelled mediaId=\(media.id)")
        } catch {
            guard loadGeneration == episodeLoadGeneration else { return }
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

    private func openTMDBMatchPicker() {
        tmdbManualOverride = appState.services.tmdbMatchingService.manualOverride(for: media.id)
        tmdbMatchQuery = media.title.best
        showTMDBMatchSheet = true
        performTMDBMatchSearch(query: tmdbMatchQuery)
    }

    private func refreshTrackingEntryForSheet() async {
        guard appState.authState.isSignedIn,
              let token = appState.authState.token else {
            listTrackingEntry = nil
            listManagerModel = makeListManagerModel()
            return
        }
        do {
            let entry = try await appState.services.aniListClient.trackingEntry(token: token, mediaId: media.id)
            listTrackingEntry = entry
            listManagerModel = makeListManagerModel()
        } catch {
            AppLog.error(.network, "tracking entry load failed mediaId=\(media.id) \(error.localizedDescription)")
        }
    }

    private func performMatchSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLoadingMatch, activeMatchQuery == trimmed {
            return
        }
        matchSearchGeneration += 1
        let searchGeneration = matchSearchGeneration
        isLoadingMatch = true
        activeMatchQuery = trimmed
        matchError = nil
        matchCandidates = []
        Task {
            do {
                let candidates: [SoraAnimeMatch]
                if trimmed.isEmpty {
                    candidates = try await appState.services.episodeService.searchCandidates(media: media)
                } else {
                    candidates = try await appState.services.episodeService.searchCandidates(query: trimmed, media: media)
                }
                await MainActor.run {
                    guard searchGeneration == matchSearchGeneration else { return }
                    matchCandidates = candidates
                    if candidates.isEmpty {
                        matchError = "No matches found."
                    }
                    isLoadingMatch = false
                    activeMatchQuery = nil
                }
            } catch {
                await MainActor.run {
                    guard searchGeneration == matchSearchGeneration else { return }
                    matchError = "Failed to search matches."
                    isLoadingMatch = false
                    activeMatchQuery = nil
                }
                AppLog.error(.matching, "manual match search failed mediaId=\(media.id) \(error.localizedDescription)")
            }
        }
    }

    private func fetchEpisodesDetached(for media: AniListMedia, forceRefresh: Bool) async throws -> EpisodeService.MatchLoadResult {
        let episodeService = appState.services.episodeService
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let result = try await episodeService.loadEpisodes(media: media, forceRefresh: forceRefresh)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startInitialLoad() {
        initialLoadTask?.cancel()
        initialLoadTask = Task { @MainActor in
            AppLog.debug(.ui, "details view load mediaId=\(media.id)")
            isInitialLoadInProgress = true
            tmdbManualOverride = appState.services.tmdbMatchingService.manualOverride(for: media.id)
            hydrateInitialCachedState()
            if !episodes.isEmpty {
                isInitialLoadInProgress = false
            }
            async let episodesTask: Void = loadEpisodes(forceRefresh: true)
            async let relatedTask: Void = loadRelated()
            async let heroTask: Void = loadHeroArtwork()
            _ = await (episodesTask, relatedTask, heroTask)
            guard !Task.isCancelled else { return }
            isBookmarked = (appState.services.libraryStore.item(forExternalId: media.id)?.status ?? .planning) != .planning
            isInitialLoadInProgress = false
        }
    }

    private func hydrateInitialCachedState() {
        if let cachedEpisodes = appState.services.episodeService.cachedEpisodes(for: media) {
            episodes = cachedEpisodes.episodes
            if let cachedMetadata = appState.services.episodeMetadataService.cachedEpisodes(for: media, episodes: cachedEpisodes.episodes) {
                episodeMetadata = cachedMetadata
            }
            if let cachedStreaming = appState.services.aniListClient.cachedStreamingEpisodesSnapshot(mediaId: media.id) {
                streamingEpisodes = cachedStreaming
            }
        }

        if let cachedRelated = appState.services.aniListClient.cachedRelatedSectionsSnapshot(mediaId: media.id) {
            relatedSections = cachedRelated
        }

        let cachedArtwork = appState.services.metadataService.cachedHeroArtwork(for: media)
        if tmdbHeroBackdropURL == nil {
            tmdbHeroBackdropURL = cachedArtwork.backdrop
        }
        if tmdbHeroLogoURL == nil {
            tmdbHeroLogoURL = cachedArtwork.logo
        }
        if tmdbHeroBackdropURL != nil || tmdbHeroLogoURL != nil {
            tmdbHeroLookupComplete = true
        }

        isBookmarked = (appState.services.libraryStore.item(forExternalId: media.id)?.status ?? .planning) != .planning
    }

    private func refreshDetailContent() async {
        initialLoadTask?.cancel()
        let hadVisibleContent = !episodes.isEmpty
        appState.services.metadataService.invalidateTMDBCaches(for: media)
        appState.services.episodeService.invalidateCachedEpisodes(for: media)
        appState.services.aniListClient.invalidateDetailCaches(mediaId: media.id)

        errorMessage = nil
        if !hadVisibleContent {
            isInitialLoadInProgress = true
        }

        async let episodesTask: Void = loadEpisodes(forceRefresh: true)
        async let relatedTask: Void = loadRelated()
        async let heroTask: Void = loadHeroArtwork()
        _ = await (episodesTask, relatedTask, heroTask)
        if !Task.isCancelled {
            isInitialLoadInProgress = false
        }
    }

    private func refreshEpisodesIfNeededOnResume() {
        guard !isInitialLoadInProgress else { return }
        guard !isLoadingSources, !showPlayer else { return }
        if let lastEpisodeRefreshAt, Date().timeIntervalSince(lastEpisodeRefreshAt) < 60 {
            return
        }
        Task {
            await loadEpisodes(forceRefresh: true)
        }
    }

    @MainActor
    private func refreshHeroAtmosphere() async {
        let atmosphere = await HeroAtmosphereResolver.shared.atmosphere(for: currentHeroBackdropURL)
        if appState.settings.reduceMotion {
            heroAtmosphere = atmosphere
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                heroAtmosphere = atmosphere
            }
        }
    }

    private func loadHeroArtwork() async {
        tmdbHeroLookupComplete = false
        async let backdropTask = appState.services.metadataService.heroBackdropURL(for: media)
        async let logoTask = appState.services.metadataService.logoURL(for: media)
        let backdrop = await backdropTask
        let logo = await logoTask
        guard !Task.isCancelled else { return }
        tmdbHeroBackdropURL = backdrop
        tmdbHeroLogoURL = logo
        tmdbHeroLookupComplete = true
        let fallback = media.bannerURL ?? media.coverURL
        let urls = [backdrop, fallback, logo].compactMap { $0 }
        await ImageCache.shared.prefetch(urls: urls)
    }

    private func performTMDBMatchSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        tmdbMatchSearchGeneration += 1
        let searchGeneration = tmdbMatchSearchGeneration
        isLoadingTMDBMatch = true
        tmdbMatchError = nil
        tmdbMatchCandidates = []
        Task {
            let results = await appState.services.tmdbMatchingService.searchShows(query: trimmed, media: media)
            await MainActor.run {
                guard searchGeneration == tmdbMatchSearchGeneration else { return }
                tmdbMatchCandidates = results
                if results.isEmpty {
                    tmdbMatchError = "No TMDB shows found."
                }
                isLoadingTMDBMatch = false
            }
        }
    }

    private func reloadTMDBOverrideDependentState() async {
        tmdbManualOverride = appState.services.tmdbMatchingService.manualOverride(for: media.id)
        tmdbHeroBackdropURL = nil
        tmdbHeroLogoURL = nil
        tmdbHeroLookupComplete = false
        episodeMetadata = [:]
        episodeRatings = [:]
        await loadEpisodes()
        await loadHeroArtwork()
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
                        headers: [:],
                        subtitleTracks: local.subtitleTracks
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

    private func downloadEpisodeUsingPreferences(_ episode: SoraEpisode) {
        selectedEpisode = episode
        Task {
            isLoadingSources = true
            defer { isLoadingSources = false }
            do {
                let loadedSources = try await appState.services.episodeService.loadSources(for: episode)
                guard !loadedSources.isEmpty else {
                    errorMessage = "No streams available."
                    return
                }
                if let preferred = preferredSource(in: loadedSources) {
                    enqueueDownload(preferred, episodeNumber: episode.number)
                    downloadMessage = "Queued episode \(episode.number) using your saved stream preference."
                } else {
                    sources = loadedSources
                    showSourceSheet = true
                }
            } catch {
                errorMessage = "Failed to load streams."
                AppLog.error(.network, "download source load failed ep=\(episode.number) \(error.localizedDescription)")
            }
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
        let metadataThumb = episodeMetadata[episode.number]?.thumbnailURL
        let streamingThumb = streamingThumbnail(for: episode)
        return metadataThumb
            ?? streamingThumb
            ?? media.bannerURL
            ?? media.coverURL
    }

    private func episodeSubtitle() -> String {
        let minutes = 24
        return "Tap to play - \(minutes)m"
    }

    private func runtimeText(from meta: EpisodeMetadata?) -> String? {
        guard let minutes = meta?.runtimeMinutes, minutes > 0 else { return nil }
        return "\(minutes)m"
    }

    private var phoneHeroPrimaryInfo: String {
        var parts: [String] = []
        if let eps = media.episodes, eps > 0 {
            parts.append(eps == 1 ? "1 EP" : "\(eps) EPS")
        }
        if let studio = media.studios.first, !studio.isEmpty {
            parts.append(studio)
        }
        if let score = media.averageScore {
            parts.append("\(score)%")
        }
        if let seasonYear = media.seasonYear {
            parts.append("\(seasonYear)")
        }
        return parts.joined(separator: " • ")
    }

    private var phoneHeroGenreInfo: String {
        Array(media.genres.prefix(4)).joined(separator: " • ")
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
        if shouldRequireManualSourceSelection {
            selectedEpisode = episode
            showSourceSheet = true
            return
        }
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

    private var shouldRequireManualSourceSelection: Bool {
        appState.settings.defaultAudio.lowercased() == "manual" ||
        appState.settings.defaultQuality.lowercased() == "manual"
    }

    private func enqueueDownload(_ source: SoraSource, episodeNumber: Int) {
        if source.format.lowercased() == "m3u8" {
            appState.services.downloadManager.enqueueHLS(
                title: media.title.best,
                episode: episodeNumber,
                url: source.url,
                headers: source.headers,
                subtitleTracks: source.subtitleTracks,
                media: detailItem
            )
        } else {
            appState.services.downloadManager.enqueue(
                title: media.title.best,
                episode: episodeNumber,
                url: source.url,
                subtitleTracks: source.subtitleTracks,
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

    var body: some View {
        HStack(alignment: .top, spacing: UIConstants.interCardSpacing) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: UIConstants.cornerRadiusSmall, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: UIConstants.episodeThumbWidth, height: UIConstants.episodeThumbHeight)
                if let resolved = card.imageURL {
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
    var rating: Double
    let totalEpisodes: Int?
    let title: String
    let scoreFormat: AniListScoreFormat
    let startedAt: AniListFuzzyDate?
    let completedAt: AniListFuzzyDate?

    init(item: MediaItem, trackingEntry: AniListTrackingEntry? = nil, scoreFormat: AniListScoreFormat = .point100) {
        self.status = trackingEntry?.status.flatMap(ListManagerViewModel.mediaStatus(from:)) ?? item.status
        self.currentEpisode = trackingEntry?.progress ?? item.currentEpisode
        self.rating = trackingEntry?.score ?? item.userRating
        self.totalEpisodes = item.totalEpisodes
        self.title = item.title
        self.scoreFormat = scoreFormat
        self.startedAt = trackingEntry?.startedAt
        self.completedAt = trackingEntry?.completedAt
    }

    func apply(to item: MediaItem) -> MediaItem {
        var updated = item
        updated.status = status
        updated.currentEpisode = max(currentEpisode, 0)
        updated.userRating = normalizedRating
        return updated
    }

    var normalizedRating: Double {
        let clamped = min(max(rating, scoreFormat.range.lowerBound), scoreFormat.range.upperBound)
        if scoreFormat == .point10Decimal {
            return (clamped * 10).rounded() / 10
        }
        return clamped.rounded()
    }

    var ratingText: String {
        let value = normalizedRating
        switch scoreFormat {
        case .point10Decimal:
            return String(format: "%.1f", value)
        default:
            return String(Int(value.rounded()))
        }
    }

    private static func mediaStatus(from value: String) -> MediaStatus? {
        switch value.uppercased() {
        case "CURRENT":
            return .watching
        case "PLANNING":
            return .planning
        case "COMPLETED":
            return .completed
        case "PAUSED":
            return .paused
        case "DROPPED":
            return .dropped
        default:
            return nil
        }
    }
}

private struct ListManagerView: View {
    let item: MediaItem
    @Bindable var viewModel: ListManagerViewModel
    let onSave: (MediaItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
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
                        ratingControl
                        Text(viewModel.ratingText)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: UIConstants.mediumPadding) {
                        Text("Started")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                        Text(viewModel.startedAt?.displayText ?? "Not set")
                            .foregroundColor(.white)
                        Text("Finished")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                        Text(viewModel.completedAt?.displayText ?? "Not set")
                            .foregroundColor(.white)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(UIConstants.standardPadding)
            }
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

    @ViewBuilder
    private var ratingControl: some View {
        switch viewModel.scoreFormat {
        case .point3:
            Picker("Your Rating", selection: $viewModel.rating) {
                Text("0").tag(0.0)
                Text("1").tag(1.0)
                Text("2").tag(2.0)
                Text("3").tag(3.0)
            }
            .pickerStyle(.segmented)
        default:
            Slider(
                value: $viewModel.rating,
                in: viewModel.scoreFormat.range,
                step: viewModel.scoreFormat.step
            )
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
                                let metadataLine = matchMetadataLine(match)
                                if !metadataLine.isEmpty {
                                    Text(metadataLine)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                if let context = match.matchContext, !context.isEmpty {
                                    Text(context)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                                if let normalizedTitle = match.normalizedTitle,
                                   !normalizedTitle.isEmpty,
                                   normalizedTitle.caseInsensitiveCompare(match.title) != .orderedSame {
                                    Text(normalizedTitle)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Button("Use") {
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

    private func matchMetadataLine(_ match: SoraAnimeMatch) -> String {
        var parts: [String] = []
        if let year = match.year {
            parts.append("\(year)")
        }
        if let episodeCount = match.episodeCount, episodeCount > 0 {
            parts.append(episodeCount == 1 ? "1 ep" : "\(episodeCount) eps")
        }
        if let format = match.format, !format.isEmpty {
            parts.append(format)
        }
        return parts.joined(separator: " | ")
    }
}

private struct TMDBMatchSheet: View {
    let media: AniListMedia
    let currentOverride: TMDBManualOverride?
    @Binding var query: String
    let candidates: [TMDBSearchResult]
    let isLoading: Bool
    let errorMessage: String?
    let onSearch: (String) -> Void
    let loadSeasons: (TMDBSearchResult) async -> [TMDBSeasonChoice]
    let onSave: (TMDBSeasonChoice, Int, Int?) -> Void
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedShow: TMDBSearchResult?
    @State private var seasons: [TMDBSeasonChoice] = []
    @State private var isLoadingSeasons = false
    @State private var seasonError: String?
    @State private var episodeOffsetText = "0"
    @State private var isParentSeries = false

    var body: some View {
        NavigationStack {
            List {
                Section("Current Match") {
                    if let currentOverride {
                        VStack(alignment: .leading, spacing: UIConstants.tinyPadding) {
                            Text(currentOverride.showTitle ?? "Manual TMDB Override")
                                .font(.system(size: 16, weight: .semibold))
                            Text(currentOverride.seasonLabel ?? "\((currentOverride.mediaType ?? "tv") == "movie" ? "Movie" : "Season \(currentOverride.seasonNumber)")")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            if currentOverride.episodeOffset != 0 {
                                Text("Offset \(currentOverride.episodeOffset)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Button("Clear Manual Match", role: .destructive) {
                            onClear()
                            dismiss()
                        }
                    } else {
                        Text("Using automatic TMDB matching.")
                            .foregroundColor(.secondary)
                    }
                }

                if selectedShow == nil {
                    Section("Search") {
                        HStack(spacing: UIConstants.mediumPadding) {
                            TextField("Search TMDB shows...", text: $query)
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
                        Text("Searching TMDB…")
                            .foregroundColor(.secondary)
                    } else if let errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(candidates) { candidate in
                            Button {
                                selectedShow = candidate
                                episodeOffsetText = "0"
                                loadSeasonChoices(for: candidate)
                            } label: {
                                HStack(spacing: UIConstants.interCardSpacing) {
                                    if let posterURL = candidate.posterURL {
                                        CachedImage(
                                            url: posterURL,
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
                                        Text(candidate.title)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.primary)
                                        if let firstAirYear = candidate.firstAirYear {
                                            Text("\(firstAirYear)")
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, UIConstants.tinyPadding)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Section {
                        Button("Back to Results") {
                            selectedShow = nil
                            seasons = []
                            seasonError = nil
                        }
                        .foregroundColor(.secondary)
                    }

                    Section("Match Options") {
                        TextField("Episode Offset", text: $episodeOffsetText)
                            .keyboardType(.numberPad)
                        Toggle("Link as Parent Series", isOn: $isParentSeries)
                            .help("All future seasons/specials for this AniList media will map to this showId.")
                    }

                    if isLoadingSeasons {
                        Text("Loading seasons…")
                            .foregroundColor(.secondary)
                    } else if let seasonError {
                        Text(seasonError)
                            .foregroundColor(.secondary)
                    } else {
                        Section(selectedShow?.title ?? "Seasons") {
                            ForEach(seasons) { season in
                                HStack(spacing: UIConstants.interCardSpacing) {
                                    VStack(alignment: .leading, spacing: UIConstants.microPadding) {
                                        Text(season.displayLabel)
                                            .font(.system(size: 15, weight: .semibold))
                                        Text("\(season.mediaType == "movie" ? "Movie" : "Season \(season.seasonNumber)") • \(season.episodeCount) episodes")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                        if season.isSynthetic || season.episodeOffset > 0 {
                                            Text("\(season.mediaType == "movie" ? "TMDB Movie" : "TMDB Season \(season.tmdbSeasonNumber)")\(season.episodeOffset > 0 ? " • Offset \(season.episodeOffset)" : "")")
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                        }
                                        if let airYear = season.airYear {
                                            Text("\(airYear)")
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                        }
                                        if season.isSynthetic {
                                            Text("AniList-aligned split")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Button("Use") {
                                        let offset = Int(episodeOffsetText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                                        onSave(season, offset, isParentSeries ? season.showId : nil)
                                        dismiss()
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                .padding(.vertical, UIConstants.tinyPadding)
                            }
                        }
                    }
                }
            }
            .navigationTitle("TMDB Match")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func loadSeasonChoices(for candidate: TMDBSearchResult) {
        isLoadingSeasons = true
        seasonError = nil
        seasons = []
        Task {
            let loaded = await loadSeasons(candidate)
            seasons = loaded
            if loaded.isEmpty {
                seasonError = "No TMDB seasons found."
            }
            isLoadingSeasons = false
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
                    if !hasExactPreferredSource {
                        Text("Your exact \(preferredAudio) / \(preferredQuality) stream is unavailable, so the closest valid source will be used.")
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
                                    } else if currentSource?.id == source.id {
                                        Text("Best Match")
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
        guard hasExactPreferredSource else { return nil }
        return StreamSourcePreferenceResolver.preferredSource(
            in: sources,
            preferredAudio: preferredAudio,
            preferredQuality: preferredQuality
        )
    }

    private var hasExactPreferredSource: Bool {
        StreamSourcePreferenceResolver.hasExactPreferredSource(
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

        if let preferred = preferredSource,
           filteredSources.contains(where: { $0.id == preferred.id }) {
            selectedSourceID = preferred.id
        } else {
            selectedSourceID = filteredSources.first?.id
        }
    }

    private var preferredSource: SoraSource? {
        StreamSourcePreferenceResolver.preferredSource(
            in: sources,
            preferredAudio: preferredAudio,
            preferredQuality: preferredQuality
        )
    }
}











