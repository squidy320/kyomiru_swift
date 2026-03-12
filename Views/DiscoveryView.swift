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
    @State private var selectedFilter: DiscoveryFilter = .all
    @State private var heroIndex = 0
    private let heroTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Discovery")
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundColor(.white)

                        heroCarousel

                        SearchField(placeholder: "Search anime...", text: $query)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(DiscoveryFilter.allCases) { filter in
                                    FilterChip(
                                        title: filter.title,
                                        isSelected: selectedFilter == filter,
                                        action: { selectedFilter = filter }
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                        }

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
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(section.title)
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(.white)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 12) {
                                            ForEach(section.items, id: \.id) { media in
                                                NavigationLink {
                                                    DetailsView(media: media)
                                                } label: {
                                                    MediaPosterCard(
                                                        title: media.title.best,
                                                        subtitle: "New release",
                                                        imageURL: media.coverURL,
                                                        score: media.averageScore
                                                    )
                                                    .frame(width: 150)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.horizontal, 2)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: tabBarInset)
        }
        .task {
            AppLog.debug(.ui, "discovery view load")
            if sections.isEmpty,
               let cached = appState.services.aniListClient.cachedDiscoverySections() {
                sections = cached
            }
            await loadDiscovery()
        }
        .onChange(of: query) { _ in
            runSearch()
        }
        .onChange(of: sections) { _ in
            if heroIndex >= heroItems().count {
                heroIndex = 0
            }
        }
    }
    private var tabBarInset: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 12 : 80
    }

    private var heroCarousel: some View {
        let items = heroItems()
        if items.isEmpty {
            return AnyView(
                HeroHeader(
                    title: "Easygoing Territory Defense",
                    subtitle: "Top rated, new releases, and hot anime",
                    imageURL: nil,
                    pills: [],
                    tags: []
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
            .frame(height: 260)
            .tabViewStyle(.page(indexDisplayMode: .always))
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
            pills: pills,
            tags: tags
        )
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search Results")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(searchResults, id: \.id) { media in
                        NavigationLink {
                            DetailsView(media: media)
                        } label: {
                            MediaPosterCard(
                                title: media.title.best,
                                subtitle: media.format ?? "Result",
                                imageURL: media.coverURL,
                                score: media.averageScore
                            )
                            .frame(width: 150)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }
}

private enum DiscoveryFilter: String, CaseIterable, Identifiable {
    case all
    case watching
    case planning
    case completed

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
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
}

// Card components moved to UI/MediaCards.swift












