import SwiftUI
import UIKit
import Kingfisher

struct DiscoveryView: View {
    @State private var query = ""
    @EnvironmentObject private var appState: AppState
    @AppStorage("library.sort") private var librarySortRaw: String = LibrarySortOption.lastUpdated.rawValue
    @State private var sections: [AniListDiscoverySection] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isSearching = false
    @State private var searchResults: [AniListMedia] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var heroIndex = 0
    @State private var imdbTrending: [TrendingItem] = []
    @State private var heroTrending: TrendingItem?
    @State private var heroAnime: AniListMedia?
    @State private var isLoadingImdbTrending = false
    @State private var imdbAniListMap: [Int: AniListMedia] = [:]
    @State private var navigateMedia: AniListMedia?
    @State private var discoveryLoadGeneration = 0
    @StateObject private var networkMonitor = NetworkMonitor.shared
    private let heroTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private var isPad: Bool { PlatformSupport.prefersTabletLayout }
    private var coreSections: [AniListDiscoverySection] {
        let order = ["trending", "hotNow", "upcoming", "allTime"]
        let lookup = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })
        return order.compactMap { lookup[$0] }
    }

    var body: some View {
        let useComfortableLayout = appState.settings.useComfortableLayout
        let screenSpacing = UIConstants.interCardSpacing + (useComfortableLayout ? 2 : 0)
        let screenPadding = UIConstants.standardPadding + (useComfortableLayout ? 4 : 0)
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: screenSpacing) {
                        heroHeader
                            .ignoresSafeArea(edges: .top)

                        VStack(alignment: .leading, spacing: screenSpacing) {
                            SearchField(placeholder: "Search anime...", text: $query)
                            GenreFilterCarousel(genres: GenreFilterCarousel.defaultGenres)

                            if isSearching {
                                GlassCard {
                                    Text("Searching AniList...")
                                        .foregroundColor(Theme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else if !trimmedQuery().isEmpty {
                                searchResultsSection
                            }

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
                    }
                    .padding(.bottom, UIConstants.bottomBarHeight)
                }
                .ignoresSafeArea(edges: .top)
                .refreshable {
                    await loadDiscovery(forceRefresh: true)
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $navigateMedia) { media in
                    DetailsView(media: media)
                }
            }
        }
        .task {
            AppLog.debug(.ui, "discovery view load")
            if sections.isEmpty,
               let cached = appState.services.aniListClient.cachedDiscoverySectionsSnapshot(sort: discoverySort(), allowStale: true) {
                sections = cached
            }
            await loadImdbTrending()
            if sections.isEmpty {
                await loadDiscovery(forceRefresh: false)
            }
        }
        .onChange(of: query) { _, _ in
            runSearch()
        }
        .onChange(of: sections) { _, _ in
            if heroIndex >= heroItems().count {
                heroIndex = 0
            }
        }
        .onChange(of: librarySortRaw) { _, _ in
            Task { await loadDiscovery(forceRefresh: true) }
        }
    }
    private var heroCarousel: AnyView {
        let items = heroItems()
        if items.isEmpty {
            return AnyView(erasing:
                HeroHeader(
                    title: "Easygoing Territory Defense",
                    subtitle: "Top rated, new releases, and hot anime",
                    imageURL: nil,
                    media: nil,
                    pills: [],
                    tags: [],
                    height: UIConstants.heroHeight
                )
            )
        }

        return AnyView(erasing:
            TabView(selection: $heroIndex) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, media in
                    NavigationLink {
                        DetailsView(media: media)
                    } label: {
                        heroHeader(for: media)
                    }
                    .buttonStyle(.plain)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(height: UIConstants.heroHeight)
            .padding(.top, UIConstants.heroTopPadding)
            .onReceive(heroTimer) { _ in
                guard !items.isEmpty else { return }
                if appState.settings.reduceMotion {
                    heroIndex = (heroIndex + 1) % items.count
                } else {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        heroIndex = (heroIndex + 1) % items.count
                    }
                }
            }
        )
    }

    private var heroHeader: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let insetTop = proxy.safeAreaInsets.top
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let heroTrending, let url = heroTrending.backdropURL {
                        CachedImage(url: url) { image in
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

                VStack(alignment: .leading, spacing: 10) {
                    if let logo = heroTrending?.logoURL {
                        CachedImage(url: logo) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Color.clear
                        }
                        .frame(maxWidth: 220)
                    } else if let title = heroTrending?.title {
                        Text(title)
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
            .contentShape(Rectangle())
            .onTapGesture {
                handleHeroTap()
            }
            .offset(y: -insetTop)
        }
        .frame(height: UIConstants.heroHeight)
    }

    private var imdbCarousel: AnyView {
        if isLoadingImdbTrending {
            return AnyView(erasing:
                GlassCard {
                    Text("Loading trending…")
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            )
        }
        if imdbTrending.isEmpty {
            return heroCarousel
        }

        return AnyView(erasing:
            VStack(alignment: .leading, spacing: UIConstants.microPadding) {
                Text("Trending")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: UIConstants.interCardSpacing) {
                        ForEach(imdbTrending, id: \.id) { item in
                            Button {
                                handleImdbTap(item)
                            } label: {
                                CinematicTrendingCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, UIConstants.heroTopPadding)
                }
                .scrollClipDisabled()
            }
            .padding(.top, UIConstants.heroTopPadding)
        )
    }

    private func heroHeader(for heroMedia: AniListMedia) -> some View {
        let match = heroMedia.averageScore ?? 91
        let rating = heroMedia.averageScore ?? 83
        let contentRating = heroMedia.isAdult ? "TV-MA" : "TV-14"
        let pills = [
            HeroPill(icon: "hand.thumbsup.fill", text: "\(match)% Match"),
            HeroPill(icon: "star.fill", text: "Score \(rating)%"),
            HeroPill(icon: "shield.fill", text: contentRating),
        ]
        let tags = Array(heroMedia.genres.prefix(2))

        return HeroHeader(
            title: heroMedia.title.best,
            subtitle: "Top rated, new releases, and hot anime",
            imageURL: heroMedia.bannerURL ?? heroMedia.coverURL,
            media: heroMedia,
            pills: pills,
            tags: tags,
            height: UIConstants.heroHeight
        )
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
            Text("Search Results")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: UIConstants.interCardSpacing) {
                    ForEach(searchResults, id: \.id) { media in
                    NavigationLink {
                        DetailsView(media: media)
                    } label: {
                        MediaPosterCard(
                            title: media.title.best,
                            subtitle: media.format ?? "Result",
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

private extension DiscoveryView {
    func trimmedQuery() -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func runSearch() {
        searchTask?.cancel()
        let term = trimmedQuery()
        if term.isEmpty {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            do {
                let results = try await appState.services.aniListClient.searchAnime(query: term)
                if Task.isCancelled { return }
                await MainActor.run {
                    searchResults = results
                    isSearching = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    searchResults = []
                    isSearching = false
                }
            }
        }
    }

    func heroItems() -> [AniListMedia] {
        if let trending = sections.first(where: { $0.id == "trending" }) {
            return Array(trending.items.prefix(5))
        }
        let items = sections.first?.items ?? []
        return Array(items.prefix(5))
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

    func loadImdbTrending() async {
        await MainActor.run {
            isLoadingImdbTrending = true
        }
        if heroTrending == nil {
            let randomHero = await appState.services.trendingService.fetchRandomDiscoverAnime(minVoteCount: 50)
            await MainActor.run {
                if let randomHero {
                    heroTrending = randomHero
                }
            }
        }
        let items = await appState.services.trendingService.fetchTrending()
        await MainActor.run {
            imdbTrending = items
            if heroTrending == nil {
                heroTrending = items.randomElement()
            }
        }
        if let heroTrending {
            await prefetchAniListMappings(items: [heroTrending])
        } else {
            await prefetchAniListMappings(items: Array(items.prefix(5)))
        }
        await MainActor.run {
            isLoadingImdbTrending = false
        }
        await prefetchDiscoveryImages()
    }

    func prefetchAniListMappings(items: [TrendingItem]) async {
        for item in items {
            if imdbAniListMap[item.id] != nil { continue }
            if let media = (try? await appState.services.aniListClient.searchAnimeByTitle(item.title)) ?? nil {
                imdbAniListMap[item.id] = media
            }
        }
    }

    func handleImdbTap(_ item: TrendingItem) {
        if let media = imdbAniListMap[item.id] {
            navigateMedia = media
            return
        }
        Task {
            if let media = (try? await appState.services.aniListClient.searchAnimeByTitle(item.title)) ?? nil {
                imdbAniListMap[item.id] = media
                navigateMedia = media
            }
        }
    }

    func handleHeroTap() {
        guard let heroTrending else { return }
        if let media = imdbAniListMap[heroTrending.id] {
            heroAnime = media
            navigateMedia = media
            return
        }
        Task {
            if let media = (try? await appState.services.aniListClient.searchAnimeByTitle(heroTrending.title)) ?? nil {
                imdbAniListMap[heroTrending.id] = media
                heroAnime = media
                navigateMedia = media
            }
        }
    }

    func prefetchDiscoveryImages(limit: Int = 4) async {
        guard networkMonitor.isOnWiFi else { return }
        var urls: [URL] = []
        let trendingItems = imdbTrending.prefix(limit)
        for item in trendingItems {
            if let backdrop = item.backdropURL { urls.append(backdrop) }
            if let logo = item.logoURL { urls.append(logo) }
        }
        if let heroTrending {
            if let backdrop = heroTrending.backdropURL { urls.append(backdrop) }
            if let logo = heroTrending.logoURL { urls.append(logo) }
        }
        await ImageCache.shared.prefetch(urls: urls)
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
                colors: [Color.black.opacity(0.9), Color.black.opacity(0.5), Color.clear],
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












