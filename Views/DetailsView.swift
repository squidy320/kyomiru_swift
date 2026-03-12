import SwiftUI

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
    @State private var trackingProgress: Int?
    @State private var currentMatch: SoraAnimeMatch?
    @State private var matchIsManual = false
    @State private var showMatchSheet = false
    @State private var isLoadingMatch = false
    @State private var matchCandidates: [SoraAnimeMatch] = []
    @State private var matchError: String?
    private let episodeService = EpisodeService()

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    hero

                    HStack(spacing: 10) {
                        RatingBadge(rating: media.averageScore.map { Double($0) / 10.0 })
                        if let episodesCount = media.episodes {
                            Text("\(episodesCount) EPS")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                        }
                        if let status = media.status {
                            Text(status)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }

                    GlassCard {
                        HStack(alignment: .center, spacing: 12) {
                            if let url = currentMatch?.imageURL {
                                AsyncImage(url: url) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Color.white.opacity(0.1)
                                }
                                .frame(width: 42, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Source Match")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Theme.textSecondary)
                                Text(currentMatch?.title ?? "Not matched yet")
                                    .foregroundColor(.white)
                                    .font(.system(size: 16, weight: .semibold))
                                if matchIsManual {
                                    Text("Manual")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.orange)
                                }
                            }
                            Spacer()
                            Button("Change") {
                                openMatchPicker()
                            }
                            .buttonStyle(.bordered)
                        }
                        if matchIsManual {
                            Button("Reset to Auto") {
                                episodeService.clearManualMatch(media: media)
                                AppLog.debug(.matching, "manual match cleared mediaId=\(media.id)")
                                Task { await loadEpisodes() }
                            }
                            .buttonStyle(.bordered)
                            .padding(.top, 8)
                        }
                    }

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
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Episodes")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                            Button("Download All Episodes") {
                                downloadAllEpisodes()
                            }
                            .buttonStyle(.borderedProminent)
                            LazyVStack(spacing: 8) {
                                ForEach(episodes) { ep in
                                    Button {
                                        selectEpisode(ep)
                                    } label: {
                                        HStack {
                                            Text("Episode \(ep.number)")
                                                .foregroundColor(.white)
                                            Spacer()
                                            if let progress = trackingProgress, ep.number <= progress {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundColor(.green)
                                            }
                                            Image(systemName: "play.fill")
                                                .foregroundColor(.white.opacity(0.8))
                                        }
                                        .padding(12)
                                        .background(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .fill(Color.white.opacity(0.06))
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 120)
            }
        }
        .task {
            AppLog.debug(.ui, "details view load mediaId=\(media.id)")
            await loadEpisodes()
            await loadTracking()
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let episode = selectedEpisode, !sources.isEmpty {
                PlayerView(episode: episode, sources: sources)
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
                    episodeService.setManualMatch(media: media, match: match)
                    AppLog.debug(.matching, "manual match selected mediaId=\(media.id) session=\(match.session)")
                    Task { await loadEpisodes() }
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

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(height: 260)
                .overlay(
                    Group {
                        if let url = media.bannerURL ?? media.coverURL {
                            AsyncImage(url: url) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                Color.white.opacity(0.08)
                            }
                        }
                    }
                )
                .clipped()

            LinearGradient(
                colors: [Color.black.opacity(0.7), Color.clear],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: 120)

            VStack(alignment: .leading, spacing: 6) {
                Text(media.title.best)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                if !media.genres.isEmpty {
                    Text(media.genres.prefix(2).joined(separator: "  "))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .padding(16)
        }
    }

    private func loadEpisodes() async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await episodeService.loadEpisodes(media: media)
            currentMatch = result.match
            matchIsManual = result.isManual
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

    private func loadTracking() async {
        guard appState.authState.isSignedIn,
              let token = appState.authState.token else { return }
        do {
            let tracking = try await appState.services.aniListClient.trackingEntry(token: token, mediaId: media.id)
            trackingProgress = tracking?.progress
            AppLog.debug(.network, "details tracking loaded mediaId=\(media.id) progress=\(trackingProgress ?? 0)")
        } catch {
            trackingProgress = nil
            AppLog.error(.network, "details tracking failed mediaId=\(media.id) \(error.localizedDescription)")
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

    private func downloadAllEpisodes() {
        AppLog.debug(.downloads, "download all start mediaId=\(media.id) count=\(episodes.count)")
        Task {
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

