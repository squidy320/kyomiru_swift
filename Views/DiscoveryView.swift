import SwiftUI
import UIKit

struct DiscoveryView: View {
    @State private var query = ""
    @EnvironmentObject private var appState: AppState
    @State private var sections: [AniListDiscoverySection] = []
    @State private var isLoading = false
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
    private let heroTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
                        heroHeader

                        VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
                            SearchField(placeholder: "Search anime...", text: $query)

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
                            } else {
                                ForEach(sections) { section in
                                    VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
                                        Text(section.title)
                                            .font(.system(size: 18, weight: .bold))
                                            .foregroundColor(.white)
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            LazyHStack(spacing: UIConstants.interCardSpacing) {
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
                                                            cornerBadge: nil
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
                        .padding(.horizontal, UIConstants.standardPadding)
                        .padding(.top, -12)
                    }
                    .padding(.top, UIConstants.smallPadding)
                    .padding(.bottom, UIConstants.bottomBarHeight)
                }
                .navigationTitle(isPad ? "Discovery" : "")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(item: $navigateMedia) { media in
                    DetailsView(media: media)
                }
            }
        }
        .task {
            AppLog.debug(.ui, "discovery view load")
            if sections.isEmpty,
               let cached = appState.services.aniListClient.cachedDiscoverySectionsSnapshot() {
                sections = cached
            }
            await loadImdbTrending()
            await loadDiscovery()
        }
        .onChange(of: query) { _, _ in
            runSearch()
        }
        .onChange(of: sections) { _, _ in
            if heroIndex >= heroItems().count {
                heroIndex = 0
            }
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
                withAnimation(.easeInOut(duration: 0.4)) {
                    heroIndex = (heroIndex + 1) % items.count
                }
            }
        )
    }

    private var heroHeader: some View {
        let height = UIScreen.main.bounds.height * 0.5
        let topInset = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first?.safeAreaInsets.top }
            .first ?? 0
        return GeometryReader { proxy in
            let width = proxy.size.width
            let insetTop = proxy.safeAreaInsets.top
            let topFeatherHeight = max(24.0, insetTop * 0.6)
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let heroTrending, let url = heroTrending.backdropURL {
                        AsyncImage(url: url) { image in
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

                VStack(alignment: .leading, spacing: 10) {
                    if let logo = heroTrending?.logoURL {
                        AsyncImage(url: logo) { image in
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
        }
        .frame(height: height)
        .offset(y: -topInset)
    }

    private var imdbCarousel: AnyView {
        if isLoadingImdbTrending {
            return AnyView(erasing:
                GlassCard {
                    Text("Loading IMDb trending…")
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
                Text("Trending on IMDb")
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
                            cornerBadge: nil
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

    func loadDiscovery() async {
        AppLog.debug(.network, "discovery load start")
        isLoading = true
        do {
            sections = try await appState.services.aniListClient.discoverySections()
        } catch {
            sections = []
            AppLog.error(.network, "discovery load failed \(error.localizedDescription)")
        }
        isLoading = false
        AppLog.debug(.network, "discovery load complete sections=\(sections.count)")
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
    }

    func prefetchAniListMappings(items: [TrendingItem]) async {
        for item in items {
            if imdbAniListMap[item.id] != nil { continue }
            if let media = (try? await appState.services.aniListClient.searchAnimeByImdbOrTitle(
                imdbId: item.imdbId,
                title: item.title
            )) ?? nil {
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
            if let media = (try? await appState.services.aniListClient.searchAnimeByImdbOrTitle(
                imdbId: item.imdbId,
                title: item.title
            )) ?? nil {
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
            if let media = (try? await appState.services.aniListClient.searchAnimeByImdbOrTitle(
                imdbId: heroTrending.imdbId,
                title: heroTrending.title
            )) ?? nil {
                imdbAniListMap[heroTrending.id] = media
                heroAnime = media
                navigateMedia = media
            }
        }
    }
}

// Card components moved to UI/MediaCards.swift

private struct CinematicTrendingCard: View {
    let item: TrendingItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let url = item.backdropURL {
                    AsyncImage(url: url) { image in
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
                    AsyncImage(url: logo) { image in
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
                Text("Trending on IMDb")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(12)
        }
        .frame(width: UIConstants.continueCardWidth, height: UIConstants.continueCardHeight * 1.3)
    }
}












