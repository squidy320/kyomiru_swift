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
    @State private var heroTrending: TrendingItem?
    @State private var heroAtmosphere: HeroAtmosphere = .fallback
    @State private var navigateMedia: AniListMedia?
    private var isPad: Bool { PlatformSupport.prefersTabletLayout }

    var body: some View {
        ZStack {
            heroAtmosphere.baseBackground.ignoresSafeArea()
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        heroHeader
                            .applyIf(!isPad) { view in
                                view.ignoresSafeArea(edges: .top)
                            }
                        
                        VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
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

                                    let horizontalPadding = UIConstants.standardPadding
                                    let availableWidth = UIScreen.main.bounds.width - (horizontalPadding * 2)
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
                                                    size: cardSize,
                                                    overlayOpacity: 0.45,
                                                    allowFallbackWhileLoading: false,
                                                    enablesTMDBArtworkLookup: true
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

                                    if isLoading {
                                        ProgressView("Loading...")
                                            .tint(.white)
                                            .frame(maxWidth: .infinity, alignment: .center)
                                            .padding(.vertical, UIConstants.smallPadding)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, UIConstants.bottomBarHeight)
                    .background(
                        LinearGradient(
                            colors: [heroAtmosphere.bottomFeather.opacity(0.16), heroAtmosphere.baseBackground],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .navigationDestination(item: $navigateMedia) { media in
                    DetailsView(media: media)
                }
                .refreshable {
                    await reload()
                }
            }
            .background(heroAtmosphere.baseBackground.ignoresSafeArea())
        }
        .task {
            await loadHero()
            await reload()
        }
        .task(id: currentHeroBackdropURL) {
            await refreshHeroAtmosphere()
        }
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
        .background(heroAtmosphere.baseBackground)
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

    private var heroHeader: some View {
        let height = UIScreen.main.bounds.height * 0.5
        let topInset = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first?.safeAreaInsets.top }
            .first ?? 0
        let fallbackURL = items.first?.bannerURL ?? items.first?.coverURL
        return GeometryReader { proxy in
            let width = proxy.size.width
            let insetTop = proxy.safeAreaInsets.top
            let topFeatherHeight = max(24.0, insetTop * 0.6)
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let heroTrending, let url = heroTrending.backdropURL {
                        CachedImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Theme.surface
                        }
                    } else if let fallbackURL {
                        CachedImage(url: fallbackURL) { image in
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
                    colors: [heroAtmosphere.bottomFeather.opacity(0.95), heroAtmosphere.bottomFeather.opacity(0.5), Color.clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(width: width, height: height + insetTop)

                LinearGradient(
                    colors: [heroAtmosphere.topFeather.opacity(0.55), heroAtmosphere.topFeather.opacity(0.15), Color.clear],
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
        }
        .frame(height: height)
        .offset(y: -topInset)
    }

    private var currentHeroBackdropURL: URL? {
        heroTrending?.backdropURL ?? items.first?.bannerURL ?? items.first?.coverURL
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

    private func loadHero() async {
        if heroTrending == nil {
            let randomHero = await appState.services.trendingService.fetchRandomDiscoverAnime(minVoteCount: 50)
            await MainActor.run {
                if let randomHero {
                    heroTrending = randomHero
                }
            }
        }
        if heroTrending == nil {
            let items = await appState.services.trendingService.fetchTrending()
            await MainActor.run {
                heroTrending = items.first(where: { $0.backdropURL != nil }) ?? items.randomElement()
            }
        }
    }

    private func handleHeroTap() {
        guard let heroTrending else { return }
        Task {
            if let media = (try? await appState.services.aniListClient.searchAnimeByTitle(heroTrending.title)) ?? nil {
                await MainActor.run {
                    navigateMedia = media
                }
            }
        }
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
