import SwiftUI

enum SearchContext {
    case discovery
    case library(snapshot: LibrarySearchSnapshot)

    var navigationTitle: String {
        switch self {
        case .discovery:
            return "Search"
        case .library:
            return "Search Library"
        }
    }

    var prompt: String {
        switch self {
        case .discovery:
            return "Search anime..."
        case .library:
            return "Search in library..."
        }
    }
}

struct LibrarySearchSnapshot {
    let sections: [AniListLibrarySection]
    let availabilityById: [Int: AniListEpisodeAvailability]
    let sortOption: LibrarySortOption
    let formatFilter: LibraryFormatFilter
    let orderedCatalogs: [MediaStatus]
}

struct SearchView: View {
    let context: SearchContext

    @EnvironmentObject private var appState: AppState
    @State private var query = ""
    @State private var isSearching = false
    @State private var searchResults: [AniListMedia] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
                    content
                }
                .padding(.horizontal, UIConstants.standardPadding)
                .padding(.top, UIConstants.smallPadding)
                .padding(.bottom, UIConstants.bottomBarHeight)
            }
        }
        .navigationTitle(context.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: context.prompt
        )
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onChange(of: query) { _, newValue in
            switch context {
            case .discovery:
                runDiscoverySearch(for: newValue)
            case .library:
                break
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch context {
        case .discovery:
            discoveryContent
        case .library(let snapshot):
            libraryContent(snapshot: snapshot)
        }
    }

    private var discoveryContent: some View {
        VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
            if isSearching {
                GlassCard {
                    Text("Searching AniList...")
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if trimmedQuery.isEmpty {
                GlassCard {
                    Text("Start typing to search anime.")
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if searchResults.isEmpty {
                GlassCard {
                    Text("No results found.")
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
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
    }

    private func libraryContent(snapshot: LibrarySearchSnapshot) -> some View {
        let filtered = filteredLibrarySections(snapshot: snapshot, query: query)

        return VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
            if !appState.authState.isSignedIn {
                GlassCard {
                    Text("No account connected. Sign in from Library to search your lists.")
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if filtered.isEmpty {
                GlassCard {
                    Text("No library sections available.")
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(filtered) { section in
                    LibrarySection(
                        section: section,
                        filterText: query,
                        availabilityById: snapshot.availabilityById
                    )
                }
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runDiscoverySearch(for value: String) {
        searchTask?.cancel()
        let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func statusBadge(for media: AniListMedia) -> String? {
        guard let item = appState.services.libraryStore.item(forExternalId: media.id) else { return nil }
        return item.status.badgeTitle
    }

    private func filteredLibrarySections(
        snapshot: LibrarySearchSnapshot,
        query: String
    ) -> [AniListLibrarySection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sectionMap = Dictionary(grouping: snapshot.sections, by: { MediaStatus.fromSectionTitle($0.title) })
            .compactMapValues { $0.first }
        let ordered = snapshot.orderedCatalogs.compactMap { sectionMap[$0] }

        return ordered.map { section in
            var items = section.items
            if snapshot.formatFilter != .all {
                items = items.filter { formatMatches($0.media, filter: snapshot.formatFilter) }
            }
            if !trimmed.isEmpty {
                items = items.filter { $0.media.title.best.lowercased().contains(trimmed) }
            }
            items = sortItems(items, by: snapshot.sortOption)
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
}
