import SwiftUI
import UIKit

struct DetailsView: View {
    let media: AniListMedia
    @EnvironmentObject private var appState: AppState
    @State private var episodes: [SoraEpisode] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedEpisode: SoraEpisode?
    @State private var sources: [SoraSource] = []
    @State private var showPlayer = false
    @State private var isLoadingSources = false
    @State private var showSourceSheet = false
    @State private var showMatchSheet = false
    @State private var isLoadingMatch = false
    @State private var matchCandidates: [SoraAnimeMatch] = []
    @State private var matchError: String?
    @State private var selectedEpisodeTab: EpisodeTab = .currentSeries
    @State private var isBookmarked = false
    @State private var relatedSections: [AniListRelatedSection] = []
    private let episodeService = EpisodeService()

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    actionRow

                    episodeTabs

                    if isLoading {
                        GlassCard {
                            Text("Loading episodes...")
                                .foregroundColor(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if let errorMessage {
                        GlassCard {
                            Text(errorMessage)
                                .foregroundColor(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        episodeGrid
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, contentBottomPadding)
            }
        }
        .task {
            AppLog.debug(.ui, "details view load mediaId=\(media.id)")
            await loadEpisodes()
            await loadRelated()
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let episode = selectedEpisode, !sources.isEmpty {
                PlayerView(episode: episode, sources: sources, mediaId: media.id)
            }
        }
        .sheet(isPresented: $showSourceSheet) {
            SourcePickerSheet(
                media: media,
                episode: selectedEpisode,
                sources: sources,
                onPlay: { picked in
                    if let picked {
                        self.sources = [picked]
                    }
                    showPlayer = true
                },
                onDownload: { source in
                    if source.format.lowercased() == "m3u8" {
                        DownloadManager.shared.enqueueHLS(
                            title: media.title.best,
                            episode: selectedEpisode?.number ?? 0,
                            url: source.url,
                            headers: source.headers
                        )
                    } else {
                        DownloadManager.shared.enqueue(
                            title: media.title.best,
                            episode: selectedEpisode?.number ?? 0,
                            url: source.url
                        )
                    }
                }
            )
        }
        .sheet(isPresented: $showMatchSheet) {
            MatchPickerSheet(
                media: media,
                candidates: matchCandidates,
                isLoading: isLoadingMatch,
                errorMessage: matchError,
                onSelect: { match in
                    Task {
                        _ = await appState.services.metadataService.manualMatch(local: detailItem, remoteId: match.session)
                        episodeService.setManualMatch(media: media, match: match)
                        AppLog.debug(.matching, "manual match selected mediaId=\(media.id) session=\(match.session)")
                        await loadEpisodes()
                    }
                }
            )
        }
        .overlay(alignment: .bottom) {
            if isLoadingSources {
                GlassCard {
                    Text("Loading streams...")
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(14)
            }
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Theme.surface)
                .frame(height: 280)
                .overlay(
                    Group {
                        if let url = media.bannerURL ?? media.coverURL {
                            AsyncImage(url: url) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                Theme.surface
                            }
                        }
                    }
                )
                .clipped()

            LinearGradient(
                colors: [Color.black.opacity(0.85), Color.black.opacity(0.25), Color.clear],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Text(media.title.best)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let episodesCount = media.episodes {
                        MetadataPill(icon: "rectangle.stack.fill", text: "\(episodesCount) EPS")
                    }
                    MetadataPill(icon: "building.2.fill", text: media.studios.first ?? media.format ?? "Studio")
                    MetadataPill(icon: "star.fill", text: "Score \(media.averageScore ?? 0)")
                }
            }
            .padding(18)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                playFirstEpisode()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(Theme.accent)
                )
            }
            .buttonStyle(.plain)

            Button {
                isBookmarked.toggle()
            } label: {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle().fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)

            Button {
                openMatchPicker()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                    Text("Manual Match")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)

            Button {
                downloadAllEpisodes()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down")
                    Text(appState.services.offlineManager.isDownloading(detailItem) ? "Downloading" : "Download All")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var episodeTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
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
        return VStack(alignment: .leading, spacing: 10) {
            if selectedEpisodeTab != .currentSeries {
                Text(selectedEpisodeTab.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            LazyVGrid(
                columns: episodeColumns(),
                spacing: 12
            ) {
                ForEach(cards) { card in
                    if card.isPlayable, let ep = card.episode {
                        Button {
                            selectEpisode(ep)
                        } label: {
                            EpisodeCard(
                                title: card.title,
                                subtitle: card.subtitle,
                                imageURL: card.imageURL,
                                progressFraction: card.progressFraction,
                                badgeText: card.badgeText,
                                score: card.score,
                                tags: card.tags,
                                timeBadgeText: card.timeBadgeText
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        EpisodeCard(
                            title: card.title,
                            subtitle: card.subtitle,
                            imageURL: card.imageURL,
                            progressFraction: card.progressFraction,
                            badgeText: card.badgeText,
                            score: card.score,
                            tags: card.tags,
                            timeBadgeText: card.timeBadgeText
                        )
                    }
                }
            }
        }
    }

    private var contentBottomPadding: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 24 : 32
    }

    private var detailItem: MediaItem {
        MediaItem(
            title: media.title.best,
            subtitle: media.format,
            posterImageURL: media.coverURL,
            heroImageURL: media.bannerURL ?? media.coverURL,
            ratingScore: media.averageScore,
            matchPercent: media.averageScore,
            contentRating: media.isAdult ? "TV-MA" : "TV-14",
            genres: media.genres,
            totalEpisodes: media.episodes,
            studio: media.studios.first ?? media.format,
            status: .planning
        )
    }

    private func loadEpisodes() async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await episodeService.loadEpisodes(media: media)
            episodes = result.episodes
        } catch {
            errorMessage = "Failed to load episodes."
            AppLog.error(.network, "details episodes load failed mediaId=\(media.id) \(error.localizedDescription)")
        }
        isLoading = false
    }

    private func openMatchPicker() {
        showMatchSheet = true
        isLoadingMatch = true
        matchError = nil
        matchCandidates = []
        Task {
            do {
                let candidates = try await episodeService.searchCandidates(media: media)
                matchCandidates = candidates
                if candidates.isEmpty {
                    matchError = "No matches found."
                }
            } catch {
                matchError = "Failed to search matches."
                AppLog.error(.matching, "manual match search failed mediaId=\(media.id) \(error.localizedDescription)")
            }
            isLoadingMatch = false
        }
    }

    private func selectEpisode(_ episode: SoraEpisode) {
        selectedEpisode = episode
        AppLog.debug(.ui, "episode selected ep=\(episode.number)")
        Task {
            isLoadingSources = true
            do {
                sources = try await episodeService.loadSources(for: episode)
                if sources.isEmpty {
                    errorMessage = "No streams available."
                } else {
                    showSourceSheet = true
                }
            } catch {
                errorMessage = "Failed to load streams."
                AppLog.error(.network, "sources load failed ep=\(episode.number) \(error.localizedDescription)")
            }
            isLoadingSources = false
        }
    }

    private func playFirstEpisode() {
        guard let first = episodes.first else { return }
        selectEpisode(first)
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
                    imageURL: media.bannerURL ?? media.coverURL,
                    progressFraction: progress,
                    badgeText: nil,
                    score: nil,
                    tags: [],
                    timeBadgeText: remaining,
                    isPlayable: true,
                    episode: ep
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
                    episode: nil
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
                episode: nil
            )
        }
    }

    private func episodeColumns() -> [GridItem] {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
        }
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)
    }

    private func episodeSubtitle() -> String {
        let minutes = 24
        return "Tap to play • \(minutes)m"
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
            relatedSections = try await appState.services.aniListClient.relatedSections(mediaId: media.id)
        } catch {
            relatedSections = []
            AppLog.error(.network, "related sections load failed mediaId=\(media.id) \(error.localizedDescription)")
        }
    }

    private func downloadAllEpisodes() {
        AppLog.debug(.downloads, "download all start mediaId=\(media.id) count=\(episodes.count)")
        Task {
            appState.services.offlineManager.beginDownload(for: detailItem)
            for ep in episodes {
                do {
                    let sources = try await episodeService.loadSources(for: ep)
                    guard let best = sources.first else { continue }
                    if best.format.lowercased() == "m3u8" {
                        DownloadManager.shared.enqueueHLS(
                            title: media.title.best,
                            episode: ep.number,
                            url: best.url,
                            headers: best.headers
                        )
                    } else {
                        DownloadManager.shared.enqueue(
                            title: media.title.best,
                            episode: ep.number,
                            url: best.url
                        )
                    }
                } catch {
                    continue
                }
            }
            appState.services.offlineManager.endDownload(for: detailItem)
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
}

private struct EpisodeCard: View {
    let title: String
    let subtitle: String
    let imageURL: URL?
    let progressFraction: Double?
    let badgeText: String?
    let score: Int?
    let tags: [String]
    let timeBadgeText: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(height: 120)
            if let imageURL {
                AsyncImage(url: imageURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            LinearGradient(
                colors: [Color.black.opacity(0.8), Color.clear],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(Theme.textSecondary)
                if !tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(tags.prefix(2), id: \.self) { tag in
                            TagPill(text: tag)
                        }
                    }
                }
                if let progressFraction {
                    ProgressView(value: progressFraction)
                        .tint(Theme.accent)
                }
            }
            .padding(10)

            if let badgeText {
                Text(badgeText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.6))
                    )
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if let score {
                RatingBadge(score: score)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if let timeBadgeText {
                Text(timeBadgeText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.6))
                    )
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }
}

private struct SourcePickerSheet: View {
    let media: AniListMedia
    let episode: SoraEpisode?
    let sources: [SoraSource]
    let onPlay: (SoraSource?) -> Void
    let onDownload: (SoraSource) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAudio: String = "Sub"
    @State private var selectedQuality: String = "Auto"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Audio", selection: $selectedAudio) {
                        ForEach(audioOptions(), id: \.self) { a in
                            Text(a).tag(a)
                        }
                    }
                    Picker("Quality", selection: $selectedQuality) {
                        ForEach(qualityOptions(), id: \.self) { q in
                            Text(q).tag(q)
                        }
                    }
                }
                ForEach(filteredSources()) { source in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(source.quality) ??? \(source.subOrDub)")
                        Text(source.format.uppercased())
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        HStack {
                            Button("Play") {
                                dismiss()
                                onPlay(bestSource())
                            }
                            .buttonStyle(.borderedProminent)
                            if source.format.lowercased() == "mp4" || source.format.lowercased() == "m3u8" {
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
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("\(media.title.best) ??? Ep \(episode?.number ?? 0)")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func audioKey(_ value: String) -> String {
        let v = value.lowercased()
        if v.contains("sub") || v.contains("jpn") || v.contains("jp") { return "sub" }
        if v.contains("dub") || v.contains("eng") { return "dub" }
        return "sub"
    }

    private func audioOptions() -> [String] {
        let options = Set(sources.map { audioKey($0.subOrDub) == "dub" ? "Dub" : "Sub" })
        return options.isEmpty ? ["Sub"] : Array(options)
    }

    private func qualityOptions() -> [String] {
        let key = audioKey(selectedAudio)
        let pool = sources.filter { audioKey($0.subOrDub) == key }
        let list = pool.isEmpty ? sources : pool
        let qualities = Set(list.map { $0.quality.isEmpty ? "Auto" : $0.quality })
        return qualities.sorted { a, b in
            if a == "Auto" { return true }
            if b == "Auto" { return false }
            return a > b
        }
    }

    private func filteredSources() -> [SoraSource] {
        let key = audioKey(selectedAudio)
        var list = sources.filter { audioKey($0.subOrDub) == key }
        if list.isEmpty { list = sources }
        if selectedQuality.lowercased() != "auto" {
            if let exact = list.first(where: { $0.quality.lowercased().contains(selectedQuality.lowercased()) }) {
                return [exact]
            }
        }
        return list
    }

    private func bestSource() -> SoraSource? {
        let filtered = filteredSources()
        let ranked = filtered.sorted { qualityRank($0.quality) > qualityRank($1.quality) }
        return ranked.first
    }

    private func qualityRank(_ q: String) -> Int {
        let digits = q.filter { $0.isNumber }
        return Int(digits) ?? 0
    }
}

private struct MatchPickerSheet: View {
    let media: AniListMedia
    let candidates: [SoraAnimeMatch]
    let isLoading: Bool
    let errorMessage: String?
    let onSelect: (SoraAnimeMatch) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    Text("Searching matches...")
                        .foregroundColor(.secondary)
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(candidates) { match in
                        HStack(spacing: 12) {
                            if let url = match.imageURL {
                                AsyncImage(url: url) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Color.white.opacity(0.1)
                                }
                                .frame(width: 42, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(match.title)
                                    .font(.system(size: 16, weight: .semibold))
                                if let year = match.year {
                                    Text("\(year)")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button("Use") {
                                dismiss()
                                onSelect(match)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 6)
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
}






