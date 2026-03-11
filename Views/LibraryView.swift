import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var sections: [AniListLibrarySection] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var filterText: String = ""
    @State private var sortMode: LibrarySort = .anilist

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        LibraryTopBar(
                            title: "Library",
                            subtitle: "Currently watching and synced lists",
                            avatarURL: appState.authState.user?.avatarURL,
                            onAvatarTap: {
                                if !appState.authState.isSignedIn {
                                    Task { await appState.authState.signIn() }
                                }
                            }
                        )

                        LibraryHero()
                        LibraryControls(filterText: $filterText, sortMode: $sortMode)

                        if appState.authState.isSignedIn {
                            if isLoading {
                                GlassCard {
                                    Text("Loading AniList library...")
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
                                ForEach(sections) { section in
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(section.title)
                                            .font(.system(size: 18, weight: .bold))
                                            .foregroundColor(.white)
                                        let visible = filteredItems(for: section)
                                        if visible.isEmpty, !filterText.isEmpty {
                                            GlassCard {
                                                Text("No matches in this list.")
                                                    .foregroundColor(Theme.textSecondary)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        } else {
                                            LazyVGrid(
                                                columns: [
                                                    GridItem(.adaptive(minimum: 152), spacing: 12),
                                                ],
                                                spacing: 12
                                            ) {
                                                ForEach(visible, id: \.id) { entry in
                                                    NavigationLink {
                                                        DetailsView(media: entry.media)
                                                    } label: {
                                                        AnimeCard(media: entry.media, subtitle: "Ep \(entry.progress)")
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            GlassCard {
                                Text("No account connected. Tap the avatar to sign in.")
                                    .foregroundColor(Theme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
            AppLog.debug(.ui, "library view load")
            await appState.bootstrap()
            await loadLibrary()
        }
    }

    private func filteredItems(for section: AniListLibrarySection) -> [AniListLibraryEntry] {
        var items = section.items
        if !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let query = filterText.lowercased()
            items = items.filter { $0.media.title.best.lowercased().contains(query) }
        }
        switch sortMode {
        case .anilist:
            return items
        case .title:
            return items.sorted { $0.media.title.best.lowercased() < $1.media.title.best.lowercased() }
        case .score:
            return items.sorted { ($0.media.averageScore ?? 0) > ($1.media.averageScore ?? 0) }
        case .progress:
            return items.sorted { $0.progress > $1.progress }
        }
    }

    private func loadLibrary() async {
        guard appState.authState.isSignedIn,
              let token = appState.authState.token else { return }
        AppLog.debug(.network, "library load start")
        isLoading = true
        errorMessage = nil
        do {
            let items = try await appState.services.aniListClient.librarySections(token: token)
            sections = items
        } catch {
            errorMessage = "Failed to load AniList library."
            AppLog.error(.network, "library load failed \(error.localizedDescription)")
        }
        isLoading = false
        AppLog.debug(.network, "library load complete sections=\(sections.count)")
    }
}

private enum LibrarySort: String, CaseIterable, Identifiable {
    case anilist = "AniList Order"
    case title = "Title A-Z"
    case score = "Score High -> Low"
    case progress = "Progress High -> Low"

    var id: String { rawValue }
}

private struct LibraryControls: View {
    @Binding var filterText: String
    @Binding var sortMode: LibrarySort

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(Theme.textSecondary)
                    TextField("Filter library titles...", text: $filterText)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                }
                Divider().background(Color.white.opacity(0.12))
                HStack {
                    Text("Sort")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Menu {
                        ForEach(LibrarySort.allCases) { mode in
                            Button(mode.rawValue) { sortMode = mode }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(sortMode.rawValue)
                                .foregroundColor(.white)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                }
            }
        }
    }
}

private struct LibraryTopBar: View {
    let title: String
    let subtitle: String
    let avatarURL: URL?
    let onAvatarTap: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundColor(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Button(action: onAvatarTap) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 38, height: 38)
                    if let url = avatarURL {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(width: 38, height: 38)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct LibraryHero: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.15, blue: 0.24),
                            Color(red: 0.05, green: 0.07, blue: 0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 220)

            VStack(alignment: .leading, spacing: 6) {
                Text("Hero Spotlight")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text("Current highlights will appear here.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(16)
        }
    }
}

private struct AnimeCard: View {
    let media: AniListMedia
    let subtitle: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 232)
                if let coverURL = media.coverURL {
                    AsyncImage(url: coverURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.white.opacity(0.08)
                    }
                    .frame(height: 232)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                LinearGradient(
                    colors: [Color.black.opacity(0.85), Color.clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(media.title.best)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(12)
            }

            RatingBadge(rating: media.averageScore.map { Double($0) / 10.0 })
                .padding(10)
        }
        .overlay(alignment: .topLeading) {
            UnwatchedBadge(mediaId: media.id)
                .padding(10)
        }
    }
}

