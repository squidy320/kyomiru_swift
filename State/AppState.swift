import SwiftUI

enum AppTab: Hashable {
    case home
    case library
    case notifications
    case downloads
    case settings
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: AppTab = .home
    @Published var settings = SettingsState()
    let services: AppServices
    @Published var authState: AuthState
    private var hasBootstrapped = false

    init() {
        let services = AppServices()
        self.services = services
        self.authState = AuthState(services: services)
    }

    @MainActor
    func bootstrap() async {
        if hasBootstrapped { return }
        hasBootstrapped = true
        AppLog.debug(.ui, "app bootstrap start")
        await authState.bootstrap()
        await loadLibraryStoreIfNeeded()
        AppLog.debug(.ui, "app bootstrap complete")
    }

    @MainActor
    func loadLibraryStoreIfNeeded() async {
        guard let token = authState.token, authState.isSignedIn else { return }
        if let cached = services.aniListClient.cachedLibrarySections(token: token), !cached.isEmpty {
            updateLibraryStore(with: cached)
        }
        do {
            let sections = try await services.aniListClient.librarySections(token: token)
            updateLibraryStore(with: sections)
        } catch {
            AppLog.error(.network, "library preload failed \(error.localizedDescription)")
        }
    }

    @MainActor
    func updateLibraryStore(with sections: [AniListLibrarySection]) {
        let mediaItems = sections.flatMap { section -> [MediaItem] in
            let status = MediaStatus.fromSectionTitle(section.title)
            return section.items.map { entry in
                MediaItem(
                    externalId: entry.media.id,
                    title: entry.media.title.best,
                    subtitle: entry.media.format,
                    posterImageURL: entry.media.coverURL,
                    heroImageURL: entry.media.bannerURL ?? entry.media.coverURL,
                    ratingScore: entry.media.averageScore,
                    matchPercent: entry.media.averageScore,
                    contentRating: entry.media.isAdult ? "TV-MA" : "TV-14",
                    genres: entry.media.genres,
                    totalEpisodes: entry.media.episodes,
                    currentEpisode: entry.progress,
                    userRating: entry.media.averageScore ?? 0,
                    studio: entry.media.studios.first,
                    status: status
                )
            }
        }
        services.libraryStore.setItems(mediaItems)
    }
}

