import SwiftUI
import UIKit

struct DownloadsView: View {
    @StateObject private var manager = DownloadManager.shared
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: DownloadsTab = .downloads
    @State private var filterText: String = ""
    @State private var filterMode: DownloadFilter = .all
    @State private var sortMode: DownloadSort = .aToZ
    @State private var isEditing = false
    @State private var selectedTitles: Set<String> = []
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var tabBarInset: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 12 : 80
    }

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
                        if UIDevice.current.userInterfaceIdiom != .pad {
                            Text("Downloads")
                                .font(.system(size: 28, weight: .heavy))
                                .foregroundColor(.white)
                        }

                        Picker("Downloads Tab", selection: $selectedTab) {
                            Text("Downloads").tag(DownloadsTab.downloads)
                            Text("Queue").tag(DownloadsTab.queue)
                        }
                        .pickerStyle(.segmented)

                        if selectedTab == .queue {
                            DownloadsQueueView(items: manager.items.filter { $0.status != "Completed" })
                        } else {
                            downloadsSummary
                            SearchField(placeholder: "Search downloads...", text: $filterText)
                            Picker("Filter", selection: $filterMode) {
                                Text("All").tag(DownloadFilter.all)
                                Text("Watched").tag(DownloadFilter.watched)
                                Text("Unwatched").tag(DownloadFilter.unwatched)
                            }
                            .pickerStyle(.segmented)
                            Picker("Sort", selection: $sortMode) {
                                Text("A-Z").tag(DownloadSort.aToZ)
                                Text("Episodes").tag(DownloadSort.episodes)
                                Text("Size").tag(DownloadSort.size)
                            }
                            .pickerStyle(.segmented)
                            editBar
                            DownloadsGridView(
                                groups: filteredGroups(),
                                mediaLookup: mediaItem(for:),
                                sizeLookup: totalSize(for:),
                                watchedLookup: isGroupWatched(title:items:),
                                isEditing: isEditing,
                                selection: $selectedTitles,
                                isPad: isPad
                            )
                        }
                    }
                    .padding(.horizontal, UIConstants.standardPadding)
                    .padding(.top, UIConstants.smallPadding)
                    .padding(.bottom, UIConstants.bottomBarHeight)
                }
                .navigationTitle(isPad ? "Downloads" : "")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: tabBarInset)
        }
        .onAppear {
            AppLog.debug(.ui, "downloads view appear")
            backfillDownloadMetadata()
        }
    }
}

private enum DownloadsTab: String {
    case downloads
    case queue
}

private enum DownloadFilter: String {
    case all
    case watched
    case unwatched
}

private enum DownloadSort: String {
    case aToZ
    case episodes
    case size
}

private struct DownloadGroup: Identifiable {
    let id = UUID()
    let title: String
    let items: [DownloadItem]
}

private extension DownloadsView {
    func groupedDownloads(_ items: [DownloadItem]) -> [DownloadGroup] {
        let grouped = Dictionary(grouping: items, by: { $0.title })
        let sortedKeys = grouped.keys.sorted { $0.lowercased() < $1.lowercased() }
        return sortedKeys.map { key in
            let episodes = grouped[key, default: []].sorted { $0.episode < $1.episode }
            return DownloadGroup(title: key, items: episodes)
        }
    }

    func mediaItem(forTitle title: String) -> MediaItem? {
        let lookup = normalizeTitle(title)
        return appState.services.libraryStore.items.first {
            let candidate = normalizeTitle($0.title)
            return candidate == lookup || candidate.contains(lookup) || lookup.contains(candidate)
        }
    }

    func mediaItem(for group: DownloadGroup) -> MediaItem? {
        if let item = mediaItem(forTitle: group.title) {
            return item
        }
        guard let fallback = group.items.first else { return nil }
        return MediaItem(
            externalId: fallback.mediaId,
            title: fallback.title,
            posterImageURL: fallback.posterURL,
            heroImageURL: fallback.bannerURL ?? fallback.posterURL,
            totalEpisodes: fallback.totalEpisodes
        )
    }

    func filteredGroups() -> [DownloadGroup] {
        let completed = manager.items.filter { $0.status == "Completed" }
        var groups = groupedDownloads(completed)
        let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmed.isEmpty {
            groups = groups.filter { $0.title.lowercased().contains(trimmed) }
        }
        switch filterMode {
        case .all:
            break
        case .watched:
            groups = groups.filter { isGroupWatched(title: $0.title, items: $0.items) }
        case .unwatched:
            groups = groups.filter { !isGroupWatched(title: $0.title, items: $0.items) }
        }
        switch sortMode {
        case .aToZ:
            return groups.sorted { $0.title.lowercased() < $1.title.lowercased() }
        case .episodes:
            return groups.sorted { $0.items.count > $1.items.count }
        case .size:
            return groups.sorted { totalSize(for: $0.items) > totalSize(for: $1.items) }
        }
    }

    func isGroupWatched(title: String, items: [DownloadItem]) -> Bool {
        let maxEpisode = items.map(\.episode).max() ?? 0
        if maxEpisode == 0 { return false }
        if let mediaItem = mediaItem(forTitle: title) {
            return mediaItem.currentEpisode >= maxEpisode
        }
        if let mediaId = mediaItem(forTitle: title)?.externalId,
           let last = PlaybackHistoryStore.shared.lastEpisodeNumber(for: mediaId) {
            return last >= maxEpisode
        }
        return false
    }

    func totalSize(for items: [DownloadItem]) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for item in items {
            if let url = item.localFile ?? DownloadManager.shared.playableURL(for: item) {
                if let attrs = try? fm.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? NSNumber {
                    total += size.int64Value
                    continue
                }
            }
            if let bytes = item.totalBytes {
                total += bytes
            }
        }
        return total
    }

    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func normalizeTitle(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    func backfillDownloadMetadata() {
        let completed = manager.items.filter { $0.status == "Completed" }
        for group in groupedDownloads(completed) {
            if let media = mediaItem(forTitle: group.title) {
                manager.updateMediaInfo(title: group.title, media: media)
            }
        }
    }

    var downloadsSummary: some View {
        let completed = manager.items.filter { $0.status == "Completed" }
        let totalBytes = totalSize(for: completed)
        return GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloaded")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                HStack(spacing: 8) {
                    Text("\(groupedDownloads(completed).count) titles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    if totalBytes > 0 {
                        Text("• \(formatBytes(totalBytes))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var editBar: some View {
        HStack {
            Button(isEditing ? "Done" : "Select") {
                isEditing.toggle()
                if !isEditing {
                    selectedTitles.removeAll()
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .buttonStyle(.plain)

            Spacer()

            if isEditing && !selectedTitles.isEmpty {
                Button("Delete Selected") {
                    let completed = manager.items.filter { $0.status == "Completed" }
                    let groups = groupedDownloads(completed)
                    for group in groups where selectedTitles.contains(group.title) {
                        for item in group.items {
                            DownloadManager.shared.delete(itemId: item.id)
                        }
                    }
                    selectedTitles.removeAll()
                    isEditing = false
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.red.opacity(0.8)))
                .buttonStyle(.plain)
            }
        }
    }
}

private struct DownloadsQueueView: View {
    let items: [DownloadItem]

    var body: some View {
        if items.isEmpty {
            GlassCard {
                Text("No active downloads.")
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            queueSummary(items)
            ForEach(items) { item in
                queueRow(item)
            }
        }
    }

    @ViewBuilder
    private func queueSummary(_ items: [DownloadItem]) -> some View {
        let totalBytes = items.compactMap { $0.totalBytes }.reduce(0, +)
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Download Queue")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                HStack(spacing: 8) {
                    Text("\(items.count) active")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    if totalBytes > 0 {
                        Text("• \(formatBytes(totalBytes)) total")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func queueRow(_ item: DownloadItem) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(item.title) • Ep \(item.episode)")
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text(displayStatus(for: item))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                ProgressView(value: item.progress)
                    .tint(.white)
                HStack(spacing: 8) {
                    if let downloaded = item.downloadedBytes, let total = item.totalBytes, total > 0 {
                        Text("\(formatBytes(downloaded)) / \(formatBytes(total))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                    } else {
                        Text("\(Int(item.progress * 100))%")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                    }
                    if let speed = item.speedBytesPerSec, speed > 0 {
                        Text("• \(formatSpeed(speed))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private func displayStatus(for item: DownloadItem) -> String {
        if item.status.lowercased().contains("fail") {
            return "Failed"
        }
        return "Downloading"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        let text = formatter.string(fromByteCount: Int64(bytesPerSecond))
        return "\(text)/s"
    }
}

private struct DownloadsGridView: View {
    let groups: [DownloadGroup]
    let mediaLookup: (DownloadGroup) -> MediaItem?
    let sizeLookup: ([DownloadItem]) -> Int64
    let watchedLookup: (String, [DownloadItem]) -> Bool
    let isEditing: Bool
    @Binding var selection: Set<String>
    let isPad: Bool

    private var gridColumns: [GridItem] {
        let minWidth: CGFloat = isPad ? 200 : 150
        return [GridItem(.adaptive(minimum: minWidth), spacing: UIConstants.interCardSpacing)]
    }

    var body: some View {
        if groups.isEmpty {
            GlassCard {
                Text("No downloads yet.")
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            LazyVGrid(columns: gridColumns, spacing: UIConstants.interCardSpacing) {
                ForEach(groups) { group in
                    let mediaItem = mediaLookup(group)
                    let totalBytes = sizeLookup(group.items)
                    let sizeText = totalBytes > 0 ? " • \(formatBytes(totalBytes))" : ""
                    let watched = watchedLookup(group.title, group.items)
                    let posterURL = mediaItem?.posterImageURL ?? group.items.first?.posterURL
                    Group {
                        if isEditing {
                            Button {
                                toggleSelection(group.title)
                            } label: {
                                MediaPosterCard(
                                    title: group.title,
                                    subtitle: "\(group.items.count) Episodes\(sizeText)",
                                    imageURL: posterURL,
                                    media: nil,
                                    score: nil,
                                    statusBadge: watched ? "Watched" : mediaItem?.status.badgeTitle,
                                    cornerBadge: nil
                                )
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: selection.contains(group.title) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(selection.contains(group.title) ? Theme.accent : Theme.textSecondary)
                                        .padding(8)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                DownloadsDetailView(
                                    title: group.title,
                                    items: group.items,
                                    mediaItem: mediaItem
                                )
                            } label: {
                                MediaPosterCard(
                                    title: group.title,
                                    subtitle: "\(group.items.count) Episodes\(sizeText)",
                                    imageURL: posterURL,
                                    media: nil,
                                    score: nil,
                                    statusBadge: watched ? "Watched" : mediaItem?.status.badgeTitle,
                                    cornerBadge: nil
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete All Downloads") {
                                    for item in group.items {
                                        DownloadManager.shared.delete(itemId: item.id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func toggleSelection(_ title: String) {
        if selection.contains(title) {
            selection.remove(title)
        } else {
            selection.insert(title)
        }
    }
}

private struct DownloadsDetailView: View {
    let title: String
    let items: [DownloadItem]
    let mediaItem: MediaItem?
    @EnvironmentObject private var appState: AppState
    @State private var selectedItem: DownloadItem?
    @State private var showPlayer = false
    @State private var playURL: URL?
    @State private var playbackError: String?
    @State private var episodeMetadata: [Int: EpisodeMetadata] = [:]
    @State private var showImportPicker = false
    @State private var showImportReview = false
    @State private var importCandidates: [EpisodeImportCandidate] = []
    @State private var importMessage: String?
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if isPad {
                ipadEpisodeCarousel
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
                        ForEach(sortedItems) { item in
                            let meta = episodeMetadata[item.episode]
                            EpisodeRowView(
                                episodeNumber: item.episode,
                                title: meta?.title ?? "Episode \(item.episode)",
                                ratingText: nil,
                                description: nil,
                                thumbnailURL: meta?.thumbnailURL,
                                isPlayable: true,
                                isWatched: isEpisodeWatched(item.episode),
                                isDownloaded: true,
                                isNew: false,
                                onTap: {
                                    play(item)
                                }
                            )
                            .contextMenu {
                                Button("Delete") {
                                    DownloadManager.shared.delete(itemId: item.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, UIConstants.standardPadding)
                    .padding(.top, UIConstants.smallPadding)
                    .padding(.bottom, UIConstants.bottomBarHeight)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Import") {
                    showImportPicker = true
                }
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let item = selectedItem, let fileURL = playURL {
                let format = fileURL.pathExtension.lowercased()
                let source = SoraSource(
                    id: "local|\(item.id)",
                    url: fileURL,
                    quality: "Local",
                    subOrDub: "Sub",
                    format: format.isEmpty ? "mp4" : format,
                    headers: [:]
                )
                let episode = SoraEpisode(id: item.id, number: item.episode, playURL: fileURL)
                PlayerView(episode: episode, sources: [source], mediaId: mediaId, malId: nil, mediaTitle: title)
            } else {
                VStack(spacing: 12) {
                    Text("Unable to play this download.")
                        .foregroundColor(.white)
                    Button("Close") {
                        showPlayer = false
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
            }
        }
        .alert("Playback Error", isPresented: Binding(
            get: { playbackError != nil },
            set: { _ in playbackError = nil }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(playbackError ?? "Unknown error")
        }
        .sheet(isPresented: $showImportPicker) {
            EpisodeImportPicker { urls in
                handleImportSelection(urls)
            } onCancel: {
                showImportPicker = false
            }
        }
        .sheet(isPresented: $showImportReview) {
            EpisodeImportReviewSheet(candidates: $importCandidates) { candidates in
                performImport(candidates: candidates)
            } onCancel: {
                showImportReview = false
            }
        }
        .alert("Import", isPresented: Binding(
            get: { importMessage != nil },
            set: { _ in importMessage = nil }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importMessage ?? "")
        }
        .task {
            loadCachedMetadata()
        }
    }

    private var mediaId: Int {
        if let external = mediaItem?.externalId, external > 0 { return external }
        return items.first?.mediaId ?? 0
    }

    private var posterURL: URL? {
        mediaItem?.posterImageURL ?? items.first?.posterURL
    }

    private var bannerURL: URL? {
        mediaItem?.heroImageURL ?? items.first?.bannerURL ?? posterURL
    }

    private var totalEpisodes: Int? {
        mediaItem?.totalEpisodes ?? items.first?.totalEpisodes
    }

    private var importMedia: MediaItem {
        if let mediaItem {
            return mediaItem
        }
        return MediaItem(
            externalId: items.first?.mediaId,
            title: title,
            posterImageURL: posterURL,
            heroImageURL: bannerURL,
            totalEpisodes: totalEpisodes
        )
    }

    private var sortedItems: [DownloadItem] {
        items.sorted { $0.episode < $1.episode }
    }

    private var ipadEpisodeCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: UIConstants.interCardSpacing) {
                ForEach(sortedItems) { item in
                    let meta = episodeMetadata[item.episode]
                    let title = meta?.title ?? "Episode \(item.episode)"
                    let subtitle = "Episode \(item.episode)"
                    Button {
                        play(item)
                    } label: {
                        DownloadEpisodeThumbCard(
                            title: title,
                            subtitle: subtitle,
                            imageURL: meta?.thumbnailURL,
                            isWatched: isEpisodeWatched(item.episode),
                            isDownloaded: true
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete") {
                            DownloadManager.shared.delete(itemId: item.id)
                        }
                    }
                }
            }
            .padding(.horizontal, UIConstants.tinyPadding)
            .padding(.vertical, UIConstants.heroTopPadding)
        }
        .scrollClipDisabled()
    }

    private func loadCachedMetadata() {
        guard mediaId > 0 else { return }
        let media = AniListMedia(
            id: mediaId,
            idMal: nil,
            title: AniListTitle(romaji: mediaItem?.title ?? title, english: mediaItem?.title ?? title, native: nil),
            coverURL: posterURL,
            bannerURL: bannerURL,
            averageScore: mediaItem?.ratingScore,
            episodes: totalEpisodes,
            seasonYear: nil,
            startDate: nil,
            format: nil,
            status: nil,
            isAdult: false,
            genres: mediaItem?.genres ?? [],
            studios: []
        )
        let fallbackURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let episodes = sortedItems.map { item in
            let url = DownloadManager.shared.playableURL(for: item) ?? fallbackURL
            return SoraEpisode(id: item.id, number: item.episode, playURL: url)
        }
        if let cached = appState.services.episodeMetadataService.cachedEpisodes(for: media, episodes: episodes) {
            episodeMetadata = cached
        }
    }

    private func handleImportSelection(_ urls: [URL]) {
        showImportPicker = false
        let candidates = DownloadManager.shared.buildImportCandidates(urls: urls)
        if candidates.isEmpty {
            importMessage = "No supported video files were selected."
            return
        }
        importCandidates = candidates
        if candidates.allSatisfy({ $0.episodeNumber != nil }) {
            performImport(candidates: candidates)
        } else {
            showImportReview = true
        }
    }

    private func performImport(candidates: [EpisodeImportCandidate]) {
        showImportReview = false
        Task { @MainActor in
            let result = await DownloadManager.shared.importEpisodes(media: importMedia, candidates: candidates)
            if !result.failed.isEmpty {
                importMessage = "Imported \(result.imported), skipped \(result.skipped), failed \(result.failed.count)."
            } else {
                importMessage = "Imported \(result.imported), skipped \(result.skipped)."
            }
        }
    }

    private func isEpisodeWatched(_ episode: Int) -> Bool {
        if let progress = mediaItem?.currentEpisode, progress > 0 {
            return episode <= progress
        }
        if let last = PlaybackHistoryStore.shared.lastEpisodeNumber(for: mediaId) {
            return episode <= last
        }
        return false
    }

    private func play(_ item: DownloadItem) {
        var fileURL = DownloadManager.shared.playableURL(for: item) ?? item.localFile
        if fileURL == nil {
            let fallback = DownloadManager.shared.localFileURL(for: item.title, episode: item.episode)
            if FileManager.default.fileExists(atPath: fallback.path) {
                fileURL = fallback
            }
        }
        guard let resolved = fileURL else {
            playbackError = "Missing local file for this episode."
            return
        }
        selectedItem = item
        playURL = resolved
        showPlayer = true
    }
}

private struct DownloadEpisodeThumbCard: View {
    let title: String
    let subtitle: String
    let imageURL: URL?
    let isWatched: Bool
    let isDownloaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIConstants.tinyPadding) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: UIConstants.cornerRadiusSmall, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 260, height: 140)
                if let imageURL {
                    CachedImage(
                        url: imageURL,
                        targetSize: CGSize(width: 260, height: 140)
                    ) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.white.opacity(0.08)
                    }
                    .frame(width: 260, height: 140)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: UIConstants.cornerRadiusSmall, style: .continuous))
                }
                if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(
                            Circle().fill(Color.black.opacity(0.4))
                        )
                        .padding(6)
                }
            }

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(isWatched ? 0.5 : 1.0))
                .lineLimit(2)

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 260, alignment: .leading)
    }
}
