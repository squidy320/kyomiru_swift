import SwiftUI
import UIKit

struct DownloadsView: View {
    @StateObject private var manager = DownloadManager.shared
    @State private var selectedItem: DownloadItem?
    @State private var showPlayer = false
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var tabBarInset: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 12 : 80
    }

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if UIDevice.current.userInterfaceIdiom != .pad {
                        Text("Downloads")
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundColor(.white)
                    }

                    let completed = manager.items.filter { $0.status == "Completed" }
                    let active = manager.items.filter { $0.status != "Completed" }
                    if !active.isEmpty {
                        queueSummary(active)
                        ForEach(active) { item in
                            queueRow(item)
                        }
                    }
                    if completed.isEmpty {
                        GlassCard {
                            Text("No downloads yet.")
                                .foregroundColor(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        ForEach(groupedDownloads(completed), id: \.title) { group in
                            VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
                                Text(group.title)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                ForEach(group.items) { item in
                                    EpisodeRowView(
                                        episodeNumber: item.episode,
                                        title: "Episode \(item.episode)",
                                        ratingText: nil,
                                        description: nil,
                                        thumbnailURL: nil,
                                        isPlayable: true,
                                        isWatched: false,
                                        isDownloaded: true,
                                        isNew: false,
                                        onTap: {
                                            AppLog.debug(.ui, "offline play tapped id=\(item.id)")
                                            selectedItem = item
                                            showPlayer = true
                                        }
                                    )
                                    .contextMenu {
                                        Button("Delete") {
                                            AppLog.debug(.downloads, "download delete tapped id=\(item.id)")
                                            DownloadManager.shared.delete(itemId: item.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .navigationTitle(isPad ? "Downloads" : "")
            .navigationBarTitleDisplayMode(.inline)
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: tabBarInset)
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let item = selectedItem, let fileURL = manager.playableURL(for: item) {
                Group {
                    let _ = AppLog.debug(.downloads, "offline play resolved url=\(fileURL.path)")
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
                    PlayerView(episode: episode, sources: [source], mediaId: 0, malId: nil, mediaTitle: item.title)
                }
            }
        }
        .onChange(of: showPlayer) { _, _ in
            if showPlayer, let item = selectedItem {
                AppLog.debug(.ui, "offline player present id=\(item.id)")
            }
        }
        .onAppear {
            AppLog.debug(.ui, "downloads view appear")
        }
    }
}

private struct DownloadGroup: Identifiable {
    let id = UUID()
    let title: String
    let items: [DownloadItem]
}

private extension DownloadsView {
    @ViewBuilder
    func queueSummary(_ items: [DownloadItem]) -> some View {
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
    func queueRow(_ item: DownloadItem) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(item.title) • Ep \(item.episode)")
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text(item.status)
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

    func groupedDownloads(_ items: [DownloadItem]) -> [DownloadGroup] {
        let grouped = Dictionary(grouping: items, by: { $0.title })
        let sortedKeys = grouped.keys.sorted { $0.lowercased() < $1.lowercased() }
        return sortedKeys.map { key in
            let episodes = grouped[key, default: []].sorted { $0.episode < $1.episode }
            return DownloadGroup(title: key, items: episodes)
        }
    }

    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func formatSpeed(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        let text = formatter.string(fromByteCount: Int64(bytesPerSecond))
        return "\(text)/s"
    }
}
