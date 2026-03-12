import SwiftUI

struct DownloadsView: View {
    @StateObject private var manager = DownloadManager.shared
    @State private var selectedItem: DownloadItem?
    @State private var showPlayer = false
    @State private var filterCompleted = false

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Downloads")
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundColor(.white)
                    Toggle("Completed Only", isOn: $filterCompleted)
                        .foregroundColor(.white)
                    let visible = manager.items.filter { filterCompleted ? $0.status == "Completed" : true }
                    if visible.isEmpty {
                        GlassCard {
                            Text("No downloads yet.")
                                .foregroundColor(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        ForEach(visible) { item in
                            GlassCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("\(item.title) ??? EP \(item.episode)")
                                        .foregroundColor(.white)
                                    ProgressView(value: item.progress)
                                    Text(item.status)
                                        .foregroundColor(Theme.textSecondary)
                                        .font(.system(size: 12))
                                    if let _ = item.localFile {
                                        Button("Play Offline") {
                                            AppLog.debug(.ui, "offline play tapped id=\(item.id)")
                                            selectedItem = item
                                            showPlayer = true
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                    Button("Delete") {
                                        AppLog.debug(.downloads, "download delete tapped id=\(item.id)")
                                        DownloadManager.shared.delete(itemId: item.id)
                                    }
                                    .buttonStyle(.bordered)
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
        .fullScreenCover(isPresented: $showPlayer) {
            if let item = selectedItem, let fileURL = item.localFile {
                let source = SoraSource(
                    id: "local|\(item.id)",
                    url: fileURL,
                    quality: "Local",
                    subOrDub: "Sub",
                    format: "mp4",
                    headers: [:]
                )
                let episode = SoraEpisode(id: item.id, number: item.episode, playURL: fileURL)
                PlayerView(episode: episode, sources: [source], mediaId: 0)
            }
        }
        .onChange(of: showPlayer) {
            if showPlayer, let item = selectedItem {
                AppLog.debug(.ui, "offline player present id=\(item.id)")
            }
        }
        .onAppear {
            AppLog.debug(.ui, "downloads view appear")
        }
    }
}

