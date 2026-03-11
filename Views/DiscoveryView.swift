import SwiftUI

struct DiscoveryView: View {
    @State private var query = ""
    @EnvironmentObject private var appState: AppState
    @State private var sections: [AniListDiscoverySection] = []
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Discovery")
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundColor(.white)

                        hero

                        searchBar

                        if isLoading {
                            GlassCard {
                                Text("Loading discovery...")
                                    .foregroundColor(Theme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            ForEach(sections) { section in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(section.title)
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(.white)
                                    LazyVGrid(
                                        columns: [
                                            GridItem(.adaptive(minimum: 152), spacing: 12),
                                        ],
                                        spacing: 12
                                    ) {
                                        ForEach(section.items, id: \.id) { media in
                                            NavigationLink {
                                                DetailsView(media: media)
                                            } label: {
                                                DiscoveryCard(
                                                    title: media.title.best,
                                                    rating: media.averageScore.map { Double($0) / 10.0 },
                                                    mediaId: media.id
                                                )
                                            }
                                            .buttonStyle(.plain)
                                        }
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
        }
        .task {
            AppLog.ui.debug("discovery view load")
            await loadDiscovery()
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.14, blue: 0.24),
                            Color(red: 0.05, green: 0.07, blue: 0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 240)

            // Scrim
            LinearGradient(
                colors: [Color.black.opacity(0.8), Color.clear],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: 100)
            .frame(maxWidth: .infinity, alignment: .bottom)
            .cornerRadius(22)

            VStack(alignment: .leading, spacing: 6) {
                Text("There was a Cute Girl...")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Text("Featured Hero")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(16)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.white.opacity(0.7))
            TextField("Search anime...", text: $query)
                .foregroundColor(.white)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private extension DiscoveryView {
    func loadDiscovery() async {
        AppLog.network.debug("discovery load start")
        isLoading = true
        do {
            sections = try await appState.services.aniListClient.discoverySections()
        } catch {
            sections = []
            AppLog.network.error("discovery load failed \(error.localizedDescription, privacy: .public)")
        }
        isLoading = false
        AppLog.network.debug("discovery load complete sections=\(sections.count)")
    }
}

private struct DiscoveryCard: View {
    let title: String
    let rating: Double?
    let mediaId: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(height: 232)
                .overlay(
                    VStack(alignment: .leading, spacing: 6) {
                        Spacer()
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                        Text("Unwatched: 2")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(12),
                    alignment: .bottomLeading
                )

            RatingBadge(rating: rating)
                .padding(10)
        }
        .overlay(alignment: .topLeading) {
            UnwatchedBadge(mediaId: mediaId)
                .padding(10)
        }
    }
}
