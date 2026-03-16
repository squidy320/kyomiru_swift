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
    func groupedDownloads(_ items: [DownloadItem]) -> [DownloadGroup] {
        let grouped = Dictionary(grouping: items, by: { $0.title })
        let sortedKeys = grouped.keys.sorted { $0.lowercased() < $1.lowercased() }
        return sortedKeys.map { key in
            let episodes = grouped[key, default: []].sorted { $0.episode < $1.episode }
            return DownloadGroup(title: key, items: episodes)
        }
    }
}
