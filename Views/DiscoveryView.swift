import SwiftUI
import UIKit
import Kingfisher

struct DiscoveryView: View {
    private struct FeaturedBannerAsset: Identifiable, Equatable {
        let media: AniListMedia
        let backdropURL: URL
        let logoURL: URL?

        var id: Int { media.id }
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("library.sort") private var librarySortRaw: String = LibrarySortOption.lastUpdated.rawValue
    @State private var sections: [AniListDiscoverySection] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var featuredMedia: AniListMedia?
    @State private var featuredHeroBackdropURL: URL?
    @State private var featuredHeroLogoURL: URL?
    @State private var heroAtmosphere: HeroAtmosphere = .fallback
    @State private var isLoadingFeaturedBanner = false
    @State private var queuedFeaturedBanners: [FeaturedBannerAsset] = []
    @State private var featuredBannerPool: [AniListMedia] = []
    @State private var featuredBannerPoolCursor = 0
    @State private var isPreparingFeaturedBanners = false
    @State private var navigateMedia: AniListMedia?
    @State private var discoveryLoadGeneration = 0
    @State private var launchHeroImageKey: String?
    @State private var launchHeroImageReady = false
    @State private var launchHeroAtmosphereReady = false
    private var isPad: Bool { PlatformSupport.prefersTabletLayout }
    private var coreSections: [AniListDiscoverySection] {
        let order = ["trending", "hotNow", "upcoming", "allTime"]
        let lookup = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })
        return order.compactMap { lookup[$0] }
    }
    private var bannerAtmosphereEnabled: Bool { appState.settings.enableBannerAtmosphere }
    private var activeHeroAtmosphere: HeroAtmosphere {
        bannerAtmosphereEnabled ? heroAtmosphere : .neutralBlack
    }
    private var pageBackground: Color {
        bannerAtmosphereEnabled ? activeHeroAtmosphere.baseBackground : Theme.baseBackground
    }

    var body: some View {
        let useComfortableLayout = appState.settings.useComfortableLayout
        let screenSpacing = UIConstants.interCardSpacing + (useComfortableLayout ? 2 : 0)
        let screenPadding = UIConstants.standardPadding + (useComfortableLayout ? 4 : 0)
        ZStack {
            Group {
                if bannerAtmosphereEnabled {
                    LinearGradient(
                        colors: [
                            activeHeroAtmosphere.baseBackground,
                            activeHeroAtmosphere.bottomFeather,
                            activeHeroAtmosphere.bottomFeather,
                            activeHeroAtmosphere.bottomFeather,
                            activeHeroAtmosphere.bottomFeather
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                } else {
                    Theme.baseBackground.ignoresSafeArea()
                }
            }
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        featuredBanner
                            .ignoresSafeArea(edges: .top)

                        VStack(alignment: .leading, spacing: screenSpacing) {
                            GenreFilterCarousel(genres: GenreFilterCarousel.defaultGenres)
                                .padding(.top, screenSpacing)

                            if isLoading {
                                GlassCard {
                                    Text("Loading discovery...")
                                        .foregroundColor(Theme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else if let errorMessage, coreSections.isEmpty {
                                GlassCard {
                                    Text(errorMessage)
                                        .foregroundColor(Theme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                ForEach(coreSections) { section in
                                    VStack(alignment: .leading, spacing: screenSpacing) {
                                        HStack {
                                            Text(section.title)
                                                .font(.system(size: 18, weight: .bold))
                                                .foregroundColor(.white)
                                            Spacer()
                                            NavigationLink {
                                                DiscoverySectionView(
                                                    sectionId: section.id,
                                                    title: section.title,
                                                    sort: discoverySort()
                                                )
                                            } label: {
                                                Text("Show More")
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundColor(Theme.textSecondary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            LazyHStack(spacing: screenSpacing) {
                                                ForEach(section.items, id: \.id) { media in
                                                    NavigationLink {
                                                        DetailsView(media: media)
                                                    } label: {
                                                        MediaPosterCard(
                                                            title: media.title.best,
                                                            subtitle: nil,
                                                            imageURL: media.coverURL,
                                                            media: media,
                                                            score: media.averageScore,
                                                            statusBadge: statusBadge(for: media),
                                                            cornerBadge: nil,
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
                            }
                        }
                        .padding(.horizontal, screenPadding)
                        .padding(.top, -12)
                        .background(
                            Group {
                                if bannerAtmosphereEnabled {
                                    LinearGradient(
                                        colors: [activeHeroAtmosphere.baseBackground, activeHeroAtmosphere.bottomFeather.opacity(0.18)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                } else {
                                    Theme.baseBackground
                                }
                            }
                        )
                    }
                    .padding(.bottom, UIConstants.bottomBarHeight)
                }
                .ignoresSafeArea(edges: .top)
                .refreshable {
                    if featuredMedia == nil {
                        await loadFeaturedBanner()
                    }
                    await loadDiscovery(forceRefresh: true)
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarColorScheme(colorScheme, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            SearchView(context: .discovery)
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.white)
                        }
                    }
                }
                .navigationDestination(item: $navigateMedia) { media in
                    DetailsView(media: media)
                }
            }
            .background(pageBackground.ignoresSafeArea())
        }
        .task {
            AppLog.debug(.ui, "discovery view load")
            if sections.isEmpty,
               let cached = appState.services.aniListClient.cachedDiscoverySectionsSnapshot(sort: discoverySort(), allowStale: true) {
                sections = cached
            }
            await loadFeaturedBanner()
            if sections.isEmpty {
                await loadDiscovery(forceRefresh: false)
            }
            if featuredMedia == nil {
                await loadFeaturedBanner()
            }
            appState.markDiscoveryLaunchReady()
            if featuredMedia == nil {
                updateLaunchHeroState(for: nil)
            }
        }
        .onChange(of: librarySortRaw) { _, _ in
            Task { await loadDiscovery(forceRefresh: true) }
        }
        .task(id: currentHeroImageURL?.absoluteString) {
            let heroURL = currentHeroImageURL
            updateLaunchHeroState(for: heroURL)
            await refreshHeroAtmosphere(for: heroURL)
        }
    }

    private var featuredBanner: some View {
        let heroBottomAllowance: CGFloat = (PlatformSupport.prefersTabletLayout ? 72 : 64) * 0.5 + 16
        return GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let insetTop = proxy.safeAreaInsets.top
            let heroImageAlignment: Alignment = isPad ? .center : .bottom
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = currentHeroImageURL {
                        CachedImage(url: url, onLoaded: handleLaunchHeroImageLoaded(_:)) { image in
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: width, height: height + insetTop, alignment: heroImageAlignment)
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
                        ? [activeHeroAtmosphere.bottomFeather.opacity(0.48), activeHeroAtmosphere.bottomFeather.opacity(0.28), Color.clear]
                        : [Theme.baseBackground.opacity(0.48), Theme.baseBackground.opacity(0.28), Color.clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(width: width, height: (height + insetTop) * 0.66)
                .frame(maxHeight: .infinity, alignment: .bottom)

                LinearGradient(
                    colors: bannerAtmosphereEnabled
                        ? [activeHeroAtmosphere.topFeather.opacity(0.72), activeHeroAtmosphere.topFeather.opacity(0.24), Color.clear]
                        : [Theme.baseBackground.opacity(0.72), Theme.baseBackground.opacity(0.24), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: width, height: (height + insetTop) * 0.30)
                .frame(maxHeight: .infinity, alignment: .top)

                LinearGradient(
                    colors: bannerAtmosphereEnabled
                        ? [activeHeroAtmosphere.topFeather.opacity(0.34), activeHeroAtmosphere.topFeather.opacity(0.14), Color.clear]
                        : [Theme.baseBackground.opacity(0.34), Theme.baseBackground.opacity(0.14), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: width, height: max(52, insetTop + 28))
                .frame(maxHeight: .infinity, alignment: .top)

                LinearGradient(
                    colors: bannerAtmosphereEnabled
                        ? [Color.clear, Color.clear, activeHeroAtmosphere.baseBackground.opacity(0.20), activeHeroAtmosphere.baseBackground.opacity(0.45), activeHeroAtmosphere.baseBackground.opacity(0.70), activeHeroAtmosphere.baseBackground, activeHeroAtmosphere.baseBackground]
                        : [Color.clear, Color.clear, Theme.baseBackground.opacity(0.20), Theme.baseBackground.opacity(0.45), Theme.baseBackground.opacity(0.70), Theme.baseBackground, Theme.baseBackground],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: (height + insetTop) * 0.26)
                .frame(maxHeight: .infinity, alignment: .bottom)

                VStack(alignment: .leading, spacing: 12) {
                    if let logo = featuredHeroLogoURL {
                        CachedImage(url: logo) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Color.clear
                        }
                        .frame(maxWidth: isPad ? 320 : 260, alignment: .leading)
                    } else if let title = featuredMedia?.title.best {
                        Text(title)
                            .font(.system(size: isPad ? 34 : 26, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
                    }
                }
                .padding(.horizontal, UIConstants.standardPadding)
                .padding(.bottom, 28)
            }
            .frame(width: width, height: height + insetTop)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture {
                handleHeroTap()
            }
            .offset(y: -insetTop)
        }
        .frame(height: UIConstants.heroHeight + heroBottomAllowance)
    }
}

private extension DiscoveryView {
    var currentHeroImageURL: URL? {
        featuredHeroBackdropURL ?? featuredMedia?.bannerURL ?? featuredMedia?.coverURL
    }

    @MainActor
    func refreshHeroAtmosphere(for url: URL?) async {
        let atmosphere = await HeroAtmosphereResolver.shared.atmosphere(for: url)
        if appState.settings.reduceMotion {
            heroAtmosphere = atmosphere
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                heroAtmosphere = atmosphere
            }
        }
        launchHeroAtmosphereReady = true
        updateLaunchVisualReadiness()
    }

    func loadFeaturedBanner() async {
        if featuredMedia != nil {
            await ensureFeaturedBannerBufferIfNeeded()
            return
        }

        await MainActor.run {
            isLoadingFeaturedBanner = true
        }

        if let existing = appState.discoveryFeaturedMedia {
            if let asset = await makeFeaturedBannerAsset(for: existing) {
                await MainActor.run {
                    applyFeaturedBannerAsset(asset)
                }
                await ensureFeaturedBannerBufferIfNeeded()
            }
            await MainActor.run {
                isLoadingFeaturedBanner = false
            }
            return
        }

        do {
            try await loadFeaturedBannerPoolIfNeeded()
            if let asset = await prepareInitialFeaturedBannerAsset() {
                await MainActor.run {
                    applyFeaturedBannerAsset(asset)
                }
                await ensureFeaturedBannerBufferIfNeeded(force: true)
            }
        } catch {
            AppLog.error(.network, "discovery featured banner load failed \(error.localizedDescription)")
            if let fallback = featuredMedia ?? sections.first(where: { $0.id == "allTime" })?.items.first ?? sections.first?.items.first {
                if let asset = await makeFeaturedBannerAsset(for: fallback) {
                    await MainActor.run {
                        applyFeaturedBannerAsset(asset)
                    }
                }
            }
        }

        await MainActor.run {
            isLoadingFeaturedBanner = false
        }
    }

    func makeFeaturedBannerAsset(for media: AniListMedia) async -> FeaturedBannerAsset? {
        let cachedArtwork = appState.services.metadataService.cachedHeroArtwork(for: media)
        let initialBackdrop = cachedArtwork.backdrop
        let initialLogo = cachedArtwork.logo

        async let backdropTask = appState.services.metadataService.heroBackdropURL(for: media, preferTextless: true)
        async let logoTask = appState.services.metadataService.logoURL(for: media)
        let resolvedBackdrop = await backdropTask
        let resolvedLogo = await logoTask
        let finalBackdrop = resolvedBackdrop ?? initialBackdrop ?? media.bannerURL ?? media.coverURL
        guard let finalBackdrop else { return nil }
        let finalLogo = resolvedLogo ?? initialLogo

        await ImageCache.shared.prefetch(urls: [finalBackdrop, finalLogo].compactMap { $0 })
        return FeaturedBannerAsset(media: media, backdropURL: finalBackdrop, logoURL: finalLogo)
    }

    func loadDiscovery(forceRefresh: Bool) async {
        if isLoading { return }
        discoveryLoadGeneration += 1
        let loadGeneration = discoveryLoadGeneration
        AppLog.debug(.network, "discovery load start")
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await appState.services.aniListClient.discoverySections(
                sort: discoverySort(),
                forceRefresh: forceRefresh
            )
            guard loadGeneration == discoveryLoadGeneration else { return }
            sections = loaded
        } catch is CancellationError {
            guard loadGeneration == discoveryLoadGeneration else { return }
            AppLog.debug(.network, "discovery load cancelled")
        } catch {
            guard loadGeneration == discoveryLoadGeneration else { return }
            if sections.isEmpty {
                sections = []
                errorMessage = "AniList is temporarily unavailable. Showing fallback content until it comes back."
            }
            AppLog.error(.network, "discovery load failed \(error.localizedDescription)")
        }
        guard loadGeneration == discoveryLoadGeneration else { return }
        isLoading = false
        AppLog.debug(.network, "discovery load complete sections=\(sections.count)")
    }

    func hasAllCoreSections(_ items: [AniListDiscoverySection]) -> Bool {
        let ids = Set(items.map(\.id))
        return ids.contains("trending")
            && ids.contains("hotNow")
            && ids.contains("upcoming")
            && ids.contains("allTime")
    }

    func discoverySort() -> String {
        let option = LibrarySortOption(rawValue: librarySortRaw) ?? .lastUpdated
        switch option {
        case .lastUpdated:
            return "TRENDING_DESC"
        case .score:
            return "SCORE_DESC"
        case .alphabetical:
            return "TITLE_ROMAJI"
        }
    }

    func statusBadge(for media: AniListMedia) -> String? {
        guard let item = appState.services.libraryStore.item(forExternalId: media.id) else { return nil }
        return item.status.badgeTitle
    }

    func handleHeroTap() {
        guard let featuredMedia else { return }
        navigateMedia = featuredMedia
    }

    @MainActor
    func applyFeaturedBannerAsset(_ asset: FeaturedBannerAsset) {
        appState.setDiscoveryFeaturedMedia(asset.media)
        featuredMedia = asset.media
        featuredHeroBackdropURL = asset.backdropURL
        featuredHeroLogoURL = asset.logoURL
    }

    @MainActor
    func popNextFeaturedBannerAsset() -> FeaturedBannerAsset? {
        guard !queuedFeaturedBanners.isEmpty else { return nil }
        let asset = queuedFeaturedBanners.removeFirst()
        return asset
    }

    func loadFeaturedBannerPoolIfNeeded() async throws {
        if !featuredBannerPool.isEmpty { return }
        let pool = try await appState.services.aniListClient.discoveryTopRatedAnimePool(limit: 1000)
        await MainActor.run {
            featuredBannerPool = pool.shuffled()
            featuredBannerPoolCursor = 0
        }
    }

    @MainActor
    func takeNextFeaturedBannerCandidate() -> AniListMedia? {
        guard !featuredBannerPool.isEmpty else { return nil }
        if featuredBannerPoolCursor >= featuredBannerPool.count {
            featuredBannerPool.shuffle()
            featuredBannerPoolCursor = 0
        }
        let media = featuredBannerPool[featuredBannerPoolCursor]
        featuredBannerPoolCursor += 1
        return media
    }

    func prepareInitialFeaturedBannerAsset() async -> FeaturedBannerAsset? {
        var attempts = 0
        let limit = max(1, featuredBannerPool.count)
        while attempts < limit {
            guard let candidate = await MainActor.run(body: { takeNextFeaturedBannerCandidate() }) else {
                return nil
            }
            if let asset = await makeFeaturedBannerAsset(for: candidate) {
                return asset
            }
            attempts += 1
        }
        return nil
    }

    func ensureFeaturedBannerBufferIfNeeded(force: Bool = false) async {
        if isPreparingFeaturedBanners { return }
        if !force && queuedFeaturedBanners.count > 1 { return }

        await MainActor.run {
            isPreparingFeaturedBanners = true
        }
        defer {
            Task { @MainActor in
                isPreparingFeaturedBanners = false
            }
        }

        do {
            try await loadFeaturedBannerPoolIfNeeded()
        } catch {
            return
        }

        let batchSize = 10
        let existingIDs = Set(queuedFeaturedBanners.map(\.id) + [featuredMedia?.id, appState.discoveryFeaturedMedia?.id].compactMap { $0 })
        var candidates: [AniListMedia] = []
        var localPool: [AniListMedia] = []
        var localCursor = 0
        await MainActor.run {
            localPool = featuredBannerPool
            localCursor = featuredBannerPoolCursor
        }

        var seenIDs = existingIDs
        var attempts = 0
        while candidates.count < batchSize && !localPool.isEmpty && attempts < localPool.count * 2 {
            if localCursor >= localPool.count {
                localPool.shuffle()
                localCursor = 0
            }
            let media = localPool[localCursor]
            localCursor += 1
            attempts += 1
            if seenIDs.insert(media.id).inserted {
                candidates.append(media)
            }
        }

        var builtAssets: [(index: Int, asset: FeaturedBannerAsset)] = []
        await withTaskGroup(of: (Int, FeaturedBannerAsset?).self) { group in
            for (index, media) in candidates.enumerated() {
                group.addTask {
                    let asset = await makeFeaturedBannerAsset(for: media)
                    return (index, asset)
                }
            }
            for await result in group {
                if let asset = result.1 {
                    builtAssets.append((result.0, asset))
                }
            }
        }

        let orderedAssets = builtAssets
            .sorted { $0.index < $1.index }
            .map(\.asset)

        await MainActor.run {
            featuredBannerPool = localPool
            featuredBannerPoolCursor = localCursor
            for asset in orderedAssets where !queuedFeaturedBanners.contains(where: { $0.id == asset.id }) {
                queuedFeaturedBanners.append(asset)
            }
        }
    }

    @MainActor
    func updateLaunchHeroState(for url: URL?) {
        let hasResolvedHeroSource = featuredMedia != nil || !isLoadingFeaturedBanner
        launchHeroImageKey = url?.absoluteString
        launchHeroImageReady = hasResolvedHeroSource && url == nil
        launchHeroAtmosphereReady = !bannerAtmosphereEnabled || (hasResolvedHeroSource && url == nil)
        updateLaunchVisualReadiness()
    }

    @MainActor
    func handleLaunchHeroImageLoaded(_ url: URL) {
        guard currentHeroImageURL?.absoluteString == url.absoluteString else { return }
        launchHeroImageReady = true
        updateLaunchVisualReadiness()
    }

    @MainActor
    func updateLaunchVisualReadiness() {
        guard launchHeroImageReady, launchHeroAtmosphereReady else { return }
        appState.markDiscoveryLaunchVisualReady()
    }
}

struct GenreFilterCarousel: View {
    let genres: [String]

    static let defaultGenres: [String] = [
        "Action", "Adventure", "Comedy", "Drama", "Fantasy", "Romance",
        "Sci-Fi", "Slice of Life", "Mystery", "Thriller", "Horror",
        "Supernatural", "Sports", "Music", "Mecha"
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: UIConstants.interCardSpacing) {
                ForEach(genres, id: \.self) { genre in
                    NavigationLink {
                        GenreDetailGridView(genre: genre)
                    } label: {
                        Text(genre)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, UIConstants.tinyPadding)
            .padding(.vertical, UIConstants.tinyPadding)
        }
        .scrollClipDisabled()
    }
}

struct GenreDetailGridView: View {
    let genre: String
    @EnvironmentObject private var appState: AppState
    @State private var items: [AniListMedia] = []
    @State private var isLoading = false
    @State private var page = 1
    @State private var hasMore = true

    private let gridSpacing = UIConstants.interCardSpacing
    private var gridItems: [GridItem] {
        [GridItem(.adaptive(minimum: UIConstants.posterCardWidth, maximum: UIConstants.posterCardWidth), spacing: gridSpacing, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: gridItems, spacing: gridSpacing) {
                ForEach(items, id: \.id) { media in
                    NavigationLink {
                        DetailsView(media: media)
                    } label: {
                        MediaPosterCard(
                            title: media.title.best,
                            subtitle: nil,
                            imageURL: media.coverURL,
                            media: media,
                            score: media.averageScore,
                            statusBadge: nil,
                            cornerBadge: nil,
                            enablesTMDBArtworkLookup: true
                        )
                        .frame(width: UIConstants.posterCardWidth)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if media.id == items.last?.id {
                            Task { await loadMoreIfNeeded() }
                        }
                    }
                }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, UIConstants.standardPadding)
                }
            }
            .padding(.horizontal, UIConstants.standardPadding)
            .padding(.top, UIConstants.smallPadding)
            .padding(.bottom, UIConstants.bottomBarHeight)
        }
        .navigationTitle(genre)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if items.isEmpty {
                await loadPage(reset: true)
            }
        }
        .refreshable {
            await loadPage(reset: true)
        }
    }

    private func loadMoreIfNeeded() async {
        guard !isLoading, hasMore else { return }
        await loadPage(reset: false)
    }

    private func loadPage(reset: Bool) async {
        await MainActor.run { isLoading = true }
        if reset {
            page = 1
            hasMore = true
        }
        do {
            let filters = BrowseFilterState(
                genre: genre,
                tag: nil,
                format: nil,
                season: nil,
                year: nil,
                sort: .trending
            )
            let result = try await appState.services.aniListClient.browseMedia(filters: filters, page: page, perPage: 30)
            await MainActor.run {
                if reset {
                    items = result
                } else {
                    items += result
                }
                hasMore = result.count >= 30
                if hasMore { page += 1 }
            }
        } catch {
            await MainActor.run {
                hasMore = false
            }
        }
        await MainActor.run { isLoading = false }
    }

}

// Card components moved to UI/MediaCards.swift

private struct CinematicTrendingCard: View {
    let item: TrendingItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let url = item.backdropURL {
                    CachedImage(
                        url: url,
                        targetSize: CGSize(width: UIConstants.continueCardWidth, height: UIConstants.continueCardHeight * 1.3)
                    ) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Theme.surface
                    }
                } else {
                    Theme.surface
                }
            }
            .frame(width: UIConstants.continueCardWidth, height: UIConstants.continueCardHeight * 1.3)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous))

            LinearGradient(
                colors: [Theme.baseBackground.opacity(0.9), Theme.baseBackground.opacity(0.5), Color.clear],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(width: UIConstants.continueCardWidth, height: UIConstants.continueCardHeight * 1.3)
            .clipShape(RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                if let logo = item.logoURL {
                    CachedImage(
                        url: logo,
                        targetSize: CGSize(width: 180, height: 80)
                    ) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(maxWidth: 180)
                } else {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                }
                Text("Trending")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(12)
        }
        .frame(width: UIConstants.continueCardWidth, height: UIConstants.continueCardHeight * 1.3)
    }
}

private struct DiscoverySectionView: View {
    let sectionId: String
    let title: String
    let sort: String
    @EnvironmentObject private var appState: AppState
    @State private var items: [AniListMedia] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var errorMessage: String?
    private var isPad: Bool { PlatformSupport.prefersTabletLayout }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
                if let errorMessage {
                    GlassCard {
                        Text(errorMessage)
                            .foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                LazyVGrid(columns: gridColumns, spacing: UIConstants.interCardSpacing) {
                    ForEach(items, id: \.id) { media in
                        NavigationLink {
                            DetailsView(media: media)
                        } label: {
                            MediaPosterCard(
                                title: media.title.best,
                                subtitle: nil,
                                imageURL: media.coverURL,
                                media: media,
                                score: media.averageScore,
                                statusBadge: statusBadge(for: media),
                                cornerBadge: nil,
                                enablesTMDBArtworkLookup: true
                            )
                            .frame(width: UIConstants.posterCardWidth)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if media.id == items.last?.id {
                                Task { await loadMoreIfNeeded() }
                            }
                        }
                    }
                }
                if isLoading {
                    ProgressView("Loading...")
                        .tint(.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, UIConstants.smallPadding)
                }
            }
            .padding(UIConstants.standardPadding)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadMoreIfNeeded(reset: true)
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: UIConstants.posterCardWidth, maximum: UIConstants.posterCardWidth), spacing: UIConstants.interCardSpacing, alignment: .top)]
    }

    private func statusBadge(for media: AniListMedia) -> String? {
        guard let item = appState.services.libraryStore.item(forExternalId: media.id) else { return nil }
        return item.status.badgeTitle
    }

    private func loadMoreIfNeeded(reset: Bool = false) async {
        if reset {
            items = []
            page = 1
            hasMore = true
            errorMessage = nil
        }
        guard !isLoading, hasMore else { return }
        isLoading = true
        do {
            let results = try await appState.services.aniListClient.discoverySectionItems(
                sectionId: sectionId,
                sort: sort,
                page: page,
                perPage: 30
            )
            if results.isEmpty {
                hasMore = false
            } else {
                items.append(contentsOf: results)
                page += 1
            }
        } catch {
            hasMore = false
            errorMessage = "Failed to load more."
            AppLog.error(.network, "discovery section load failed id=\(sectionId) \(error.localizedDescription)")
        }
        isLoading = false
    }
}












