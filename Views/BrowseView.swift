import SwiftUI

struct BrowseView: View {
    @EnvironmentObject private var appState: AppState
    @State private var items: [AniListMedia] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var errorMessage: String?
    @State private var filters = BrowseFilterState()
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            ScrollView {
                LazyVStack(pinnedViews: [.sectionHeaders]) {
                    Section(header: filterBar) {
                        if let errorMessage {
                            GlassCard {
                                Text(errorMessage)
                                    .foregroundColor(Theme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, UIConstants.standardPadding)
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
                                        cornerBadge: nil
                                    )
                                }
                                .buttonStyle(.plain)
                                .onAppear {
                                    if media.id == items.last?.id {
                                        Task { await loadMoreIfNeeded() }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, UIConstants.standardPadding)

                        if isLoading {
                            ProgressView("Loading...")
                                .tint(.white)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, UIConstants.smallPadding)
                        }
                    }
                }
            }
            .refreshable {
                await reload()
            }
        }
        .task {
            await reload()
        }
    }

    private var gridColumns: [GridItem] {
        let count = isPad ? 5 : 2
        return Array(repeating: GridItem(.flexible(), spacing: UIConstants.interCardSpacing), count: count)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: UIConstants.smallPadding) {
            Text("Browse")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, UIConstants.standardPadding)
                .padding(.top, UIConstants.smallPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIConstants.interCardSpacing) {
                    filterMenu(title: "Genre", value: filters.genre ?? "All", options: BrowseFilterState.genres) {
                        filters.genre = $0 == "All" ? nil : $0
                    }
                    filterMenu(title: "Tag", value: filters.tag ?? "All", options: BrowseFilterState.tags) {
                        filters.tag = $0 == "All" ? nil : $0
                    }
                    filterMenu(title: "Format", value: filters.format?.rawValue ?? "All", options: BrowseFilterState.formatOptions) {
                        filters.format = BrowseFormat(rawValue: $0)
                    }
                    filterMenu(title: "Season", value: filters.season?.rawValue ?? "All", options: BrowseFilterState.seasonOptions) {
                        filters.season = BrowseSeason(rawValue: $0)
                    }
                    filterMenu(title: "Year", value: filters.year.map(String.init) ?? "All", options: BrowseFilterState.yearOptions) {
                        filters.year = Int($0)
                    }
                    filterMenu(title: "Sort", value: filters.sort.title, options: BrowseSortOption.allCases.map(\.title)) { selection in
                        if let sort = BrowseSortOption.allCases.first(where: { $0.title == selection }) {
                            filters.sort = sort
                        }
                    }
                }
                .padding(.horizontal, UIConstants.standardPadding)
                .padding(.bottom, UIConstants.smallPadding)
            }
        }
        .background(Theme.baseBackground)
        .onChange(of: filters) { _, _ in
            Task { await reload() }
        }
    }

    private func filterMenu(title: String, value: String, options: [String], onSelect: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option) { onSelect(option) }
            }
        } label: {
            browseChipLabel(text: "\(title): \(value)", isSelected: value != "All")
        }
    }

    private func browseChipLabel(text: String, isSelected: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(isSelected ? .white : Theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.22) : Color.white.opacity(0.06))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(isSelected ? Theme.accent.opacity(0.45) : Color.white.opacity(0.1), lineWidth: 1)
            )
    }

    private func statusBadge(for media: AniListMedia) -> String? {
        guard let item = appState.services.libraryStore.item(forExternalId: media.id) else { return nil }
        return item.status.badgeTitle
    }

    private func reload() async {
        items = []
        page = 1
        hasMore = true
        errorMessage = nil
        await loadMoreIfNeeded()
    }

    private func loadMoreIfNeeded() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        do {
            let newItems = try await appState.services.aniListClient.browseMedia(
                filters: filters,
                page: page,
                perPage: 30
            )
            if newItems.isEmpty {
                hasMore = false
            } else {
                items.append(contentsOf: newItems)
                page += 1
            }
        } catch {
            hasMore = false
            errorMessage = "Failed to load results."
            AppLog.error(.network, "browse load failed \(error.localizedDescription)")
        }
        isLoading = false
    }
}

struct BrowseFilterState: Equatable {
    var genre: String? = nil
    var tag: String? = nil
    var format: BrowseFormat? = nil
    var season: BrowseSeason? = nil
    var year: Int? = nil
    var sort: BrowseSortOption = .trending

    var cacheKey: String {
        [
            "g:\(genre ?? "all")",
            "t:\(tag ?? "all")",
            "f:\(format?.rawValue ?? "all")",
            "s:\(season?.rawValue ?? "all")",
            "y:\(year.map(String.init) ?? "all")",
            "o:\(sort.rawValue)"
        ].joined(separator: "|")
    }

    static let genres: [String] = ["All", "Action", "Adventure", "Comedy", "Drama", "Fantasy", "Romance", "Sci-Fi", "Slice of Life", "Horror", "Mystery", "Psychological", "Supernatural", "Thriller", "Sports", "Music", "Mecha", "Mahou Shoujo", "Ecchi"]
    static let tags: [String] = ["All", "Shounen", "Shoujo", "Seinen", "Josei", "Isekai"]
    static let formatOptions: [String] = ["All", "TV", "Movie", "OVA", "ONA", "Special"]
    static let seasonOptions: [String] = ["All", "Winter", "Spring", "Summer", "Fall"]
    static let yearOptions: [String] = ["All"] + (1980...Calendar.current.component(.year, from: Date())).reversed().map(String.init)
}

enum BrowseFormat: String {
    case TV
    case Movie
    case OVA
    case ONA
    case Special
}

enum BrowseSeason: String {
    case Winter = "Winter"
    case Spring = "Spring"
    case Summer = "Summer"
    case Fall = "Fall"
}

enum BrowseSortOption: String, CaseIterable {
    case trending
    case score
    case popularity
    case title

    var title: String {
        switch self {
        case .trending: return "Trending"
        case .score: return "Score"
        case .popularity: return "Popularity"
        case .title: return "Title"
        }
    }
}
