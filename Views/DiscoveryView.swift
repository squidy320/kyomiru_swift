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
    private let heroTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
                        if UIDevice.current.userInterfaceIdiom != .pad {
                            Text("Discovery")
                                .font(.system(size: 28, weight: .heavy))
                                .foregroundColor(.white)
                        }

                        heroCarousel

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
                                                        subtitle: "New release",
                                                        imageURL: media.coverURL,
                                                        media: media,
                                                        score: media.averageScore,
                                                        isWatched: isWatched(media)
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
                    .padding(.top, UIConstants.smallPadding)
                    .padding(.bottom, UIConstants.bottomBarHeight)
                }
                .navigationTitle(isPad ? "Discovery" : "")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            AppLog.debug(.ui, "discovery view load")
            if sections.isEmpty,
               let cached = appState.services.aniListClient.cachedDiscoverySectionsSnapshot() {
                sections = cached
            }
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
    private var heroCarousel: some View {
        let items = heroItems()
        if items.isEmpty {
            return AnyView(
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

        return AnyView(
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
                            isWatched: isWatched(media)
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

    func isWatched(_ media: AniListMedia) -> Bool {
        guard let item = appState.services.libraryStore.item(forExternalId: media.id) else { return false }
        if item.status == .completed { return true }
        if let total = media.episodes, total > 0, item.currentEpisode >= total { return true }
        return false
    }
}

// Card components moved to UI/MediaCards.swift












