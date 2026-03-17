import SwiftUI

struct BrowseView: View {
    @EnvironmentObject private var appState: AppState
    @State private var items: [AniListMedia] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var errorMessage: String?
    @State private var filters = BrowseFilterState()
    @State private var pendingFilters = BrowseFilterState()
    @State private var showFilters = false
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

                        GeometryReader { proxy in
                            let horizontalPadding = UIConstants.standardPadding
                            let availableWidth = proxy.size.width - (horizontalPadding * 2)
                            let (columns, cardSize) = gridLayout(for: availableWidth)
                            LazyVGrid(columns: columns, spacing: gridSpacing) {
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
                                            size: cardSize
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
                            .padding(.horizontal, horizontalPadding)
                        }
                        .frame(minHeight: 0)

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
        .task { await reload() }
        .sheet(isPresented: $showFilters) {
            BrowseFilterSheet(
                filters: $pendingFilters,
                onApply: {
                    filters = pendingFilters
                    showFilters = false
                    Task { await reload() }
                },
                onClear: {
                    pendingFilters = BrowseFilterState()
                }
            )
        }
    }

    private var gridSpacing: CGFloat { 10 }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: UIConstants.tinyPadding) {
            HStack {
                Text("Browse")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button {
                    pendingFilters = filters
                    showFilters = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                        Text(filterButtonTitle)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, UIConstants.standardPadding)
            .padding(.top, UIConstants.microPadding)

            if !activeChips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(activeChips, id: \.label) { chip in
                            browseChipLabel(text: "\(chip.label): \(chip.value)", isSelected: true)
                        }
                    }
                    .padding(.horizontal, UIConstants.standardPadding)
                    .padding(.bottom, UIConstants.smallPadding)
                }
            } else {
                Spacer().frame(height: 4)
            }
        }
        .background(Theme.baseBackground)
    }

    private func browseChipLabel(text: String, isSelected: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(isSelected ? .white : Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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

    private func gridLayout(for availableWidth: CGFloat) -> ([GridItem], CGSize) {
        let targetColumns: Int
        if isPad {
            targetColumns = availableWidth > 1024 ? 5 : 4
        } else {
            targetColumns = 2
        }
        let totalSpacing = CGFloat(targetColumns - 1) * gridSpacing
        let cardWidth = floor((availableWidth - totalSpacing) / CGFloat(targetColumns))
        let cardHeight = cardWidth * 1.47
        let items = Array(repeating: GridItem(.fixed(cardWidth), spacing: gridSpacing), count: targetColumns)
        return (items, CGSize(width: cardWidth, height: cardHeight))
    }

    private var activeChips: [(label: String, value: String)] {
        var chips: [(String, String)] = []
        if let genre = filters.genre { chips.append(("Genre", genre)) }
        if let tag = filters.tag { chips.append(("Tag", tag)) }
        if let format = filters.format { chips.append(("Format", format.rawValue)) }
        if let season = filters.season { chips.append(("Season", season.rawValue)) }
        if let year = filters.year { chips.append(("Year", String(year))) }
        if filters.sort != .trending { chips.append(("Sort", filters.sort.title)) }
        return chips
    }

    private var filterButtonTitle: String {
        let count = activeChips.count
        return count == 0 ? "Filters" : "Filters (\(count))"
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

private struct BrowseFilterSheet: View {
    @Binding var filters: BrowseFilterState
    let onApply: () -> Void
    let onClear: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Genre") {
                    Picker("Genre", selection: genreBinding) {
                        ForEach(BrowseFilterState.genres, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Tag") {
                    Picker("Tag", selection: tagBinding) {
                        ForEach(BrowseFilterState.tags, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Format") {
                    Picker("Format", selection: formatBinding) {
                        ForEach(BrowseFilterState.formatOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Season") {
                    Picker("Season", selection: seasonBinding) {
                        ForEach(BrowseFilterState.seasonOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Year") {
                    Picker("Year", selection: yearBinding) {
                        ForEach(BrowseFilterState.yearOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Sort") {
                    Picker("Sort", selection: sortBinding) {
                        ForEach(BrowseSortOption.allCases, id: \.self) { option in
                            Text(option.title).tag(option.title)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.baseBackground)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { onClear() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onApply() }
                }
            }
        }
    }

    private var genreBinding: Binding<String> {
        Binding(
            get: { filters.genre ?? "All" },
            set: { filters.genre = $0 == "All" ? nil : $0 }
        )
    }

    private var tagBinding: Binding<String> {
        Binding(
            get: { filters.tag ?? "All" },
            set: { filters.tag = $0 == "All" ? nil : $0 }
        )
    }

    private var formatBinding: Binding<String> {
        Binding(
            get: { filters.format?.rawValue ?? "All" },
            set: { filters.format = BrowseFormat(rawValue: $0) }
        )
    }

    private var seasonBinding: Binding<String> {
        Binding(
            get: { filters.season?.rawValue ?? "All" },
            set: { filters.season = BrowseSeason(rawValue: $0) }
        )
    }

    private var yearBinding: Binding<String> {
        Binding(
            get: { filters.year.map(String.init) ?? "All" },
            set: { filters.year = Int($0) }
        )
    }

    private var sortBinding: Binding<String> {
        Binding(
            get: { filters.sort.title },
            set: { selection in
                if let sort = BrowseSortOption.allCases.first(where: { $0.title == selection }) {
                    filters.sort = sort
                }
            }
        )
    }
}
