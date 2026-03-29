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
    func loadLibraryStoreIfNeeded(forceRefresh: Bool = false) async {
        guard let token = authState.token, authState.isSignedIn else { return }
        if !forceRefresh, let cached = services.aniListClient.cachedLibrarySections(token: token, allowStale: true), !cached.isEmpty {
            updateLibraryStore(with: cached)
        }
        do {
            let sections = try await services.aniListClient.librarySections(token: token, forceRefresh: forceRefresh)
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
                    userRating: entry.score ?? 0,
                    studio: entry.media.studios.first,
                    status: status
                )
            }
        }
        services.libraryStore.setItems(mediaItems)
    }

    func syncListUpdate(_ item: MediaItem, refresh: Bool = true) async {
        services.libraryStore.upsert(item)
        guard settings.autoSyncAniList,
              authState.isSignedIn,
              let token = authState.token,
              let mediaId = item.externalId else { return }
        let status = aniListStatus(for: item.status)
        do {
            let existing = try await services.aniListClient.trackingEntry(token: token, mediaId: mediaId)
            let dates = resolvedTrackingDates(
                existing: existing,
                status: item.status,
                progress: item.currentEpisode,
                totalEpisodes: item.totalEpisodes
            )
            let score = item.userRating > 0 ? item.userRating : existing?.score
            _ = try await services.aniListClient.saveMediaListEntry(
                token: token,
                mediaId: mediaId,
                status: status,
                progress: item.currentEpisode,
                score: score,
                startedAt: dates.startedAt,
                completedAt: dates.completedAt
            )
            services.aniListClient.clearLibraryCache(token: token)
            services.aniListClient.clearTrackingCaches(for: mediaId)
            if refresh {
                await loadLibraryStoreIfNeeded(forceRefresh: true)
            }
        } catch {
            AppLog.error(.network, "list sync failed mediaId=\(mediaId) \(error.localizedDescription)")
        }
    }

    func markEpisodeWatched(mediaId: Int, episodeNumber: Int) async {
        let currentItem = services.libraryStore.item(forExternalId: mediaId)
        let currentProgress = currentItem?.currentEpisode ?? 0
        let newProgress = max(currentProgress, episodeNumber)
        var newStatus = currentItem?.status ?? .planning
        if newStatus != .watching {
            newStatus = .watching
        }

        var totalEpisodes: Int? = currentItem?.totalEpisodes
        var availability: AniListEpisodeAvailability?
        if authState.isSignedIn, let token = authState.token {
            availability = try? await services.aniListClient.episodeAvailability(token: token, mediaId: mediaId)
            if let availTotal = availability?.totalEpisodes, availTotal > 0 {
                totalEpisodes = availTotal
            }
        }

        if let status = availability?.status?.uppercased(),
           status == "FINISHED",
           let totalEpisodes, totalEpisodes > 0,
           newProgress >= totalEpisodes {
            newStatus = .completed
        }

        if let currentItem {
            let updated = MediaItem(
                externalId: mediaId,
                title: currentItem.title,
                subtitle: currentItem.subtitle,
                posterImageURL: currentItem.posterImageURL,
                heroImageURL: currentItem.heroImageURL,
                ratingScore: currentItem.ratingScore,
                matchPercent: currentItem.matchPercent,
                contentRating: currentItem.contentRating,
                genres: currentItem.genres,
                totalEpisodes: totalEpisodes ?? currentItem.totalEpisodes,
                currentEpisode: newProgress,
                userRating: currentItem.userRating,
                studio: currentItem.studio,
                status: newStatus
            )
            services.libraryStore.upsert(updated)
        }

        await syncAniListTracking(
            mediaId: mediaId,
            status: newStatus,
            progress: newProgress,
            userRating: currentItem?.userRating ?? 0,
            totalEpisodes: totalEpisodes
        )
    }

    func markEpisodeUnwatched(mediaId: Int, episodeNumber: Int) async {
        let currentItem = services.libraryStore.item(forExternalId: mediaId)
        let currentProgress = currentItem?.currentEpisode ?? 0
        let targetProgress = max(episodeNumber - 1, 0)
        let newProgress = min(currentProgress, targetProgress)
        var newStatus = currentItem?.status ?? .watching
        if newStatus != .watching {
            newStatus = .watching
        }

        if let currentItem {
            let updated = MediaItem(
                externalId: mediaId,
                title: currentItem.title,
                subtitle: currentItem.subtitle,
                posterImageURL: currentItem.posterImageURL,
                heroImageURL: currentItem.heroImageURL,
                ratingScore: currentItem.ratingScore,
                matchPercent: currentItem.matchPercent,
                contentRating: currentItem.contentRating,
                genres: currentItem.genres,
                totalEpisodes: currentItem.totalEpisodes,
                currentEpisode: newProgress,
                userRating: currentItem.userRating,
                studio: currentItem.studio,
                status: newStatus
            )
            services.libraryStore.upsert(updated)
        }

        await syncAniListTracking(
            mediaId: mediaId,
            status: newStatus,
            progress: newProgress,
            userRating: currentItem?.userRating ?? 0,
            totalEpisodes: currentItem?.totalEpisodes
        )
    }

    func markMediaCompleted(mediaId: Int) async {
        let currentItem = services.libraryStore.item(forExternalId: mediaId)
        var totalEpisodes: Int? = currentItem?.totalEpisodes
        if authState.isSignedIn, let token = authState.token {
            if let availability = try? await services.aniListClient.episodeAvailability(token: token, mediaId: mediaId) {
                let availTotal = availability.totalEpisodes
                if availTotal > 0 {
                    totalEpisodes = availTotal
                }
            }
        }
        let newProgress = totalEpisodes ?? currentItem?.currentEpisode ?? 0
        if let currentItem {
            let updated = MediaItem(
                externalId: mediaId,
                title: currentItem.title,
                subtitle: currentItem.subtitle,
                posterImageURL: currentItem.posterImageURL,
                heroImageURL: currentItem.heroImageURL,
                ratingScore: currentItem.ratingScore,
                matchPercent: currentItem.matchPercent,
                contentRating: currentItem.contentRating,
                genres: currentItem.genres,
                totalEpisodes: totalEpisodes ?? currentItem.totalEpisodes,
                currentEpisode: newProgress,
                userRating: currentItem.userRating,
                studio: currentItem.studio,
                status: .completed
            )
            services.libraryStore.upsert(updated)
        }

        await syncAniListTracking(
            mediaId: mediaId,
            status: .completed,
            progress: newProgress,
            userRating: currentItem?.userRating ?? 0,
            totalEpisodes: totalEpisodes
        )
    }

    private func aniListStatus(for status: MediaStatus) -> String {
        switch status {
        case .watching:
            return "CURRENT"
        case .planning:
            return "PLANNING"
        case .completed:
            return "COMPLETED"
        case .paused:
            return "PAUSED"
        case .dropped:
            return "DROPPED"
        }
    }

    private func syncAniListTracking(
        mediaId: Int,
        status: MediaStatus,
        progress: Int,
        userRating: Double,
        totalEpisodes: Int?
    ) async {
        guard settings.autoSyncAniList,
              authState.isSignedIn,
              let token = authState.token else { return }

        do {
            let existing = try await services.aniListClient.trackingEntry(token: token, mediaId: mediaId)
            let dates = resolvedTrackingDates(
                existing: existing,
                status: status,
                progress: progress,
                totalEpisodes: totalEpisodes
            )
            let score = userRating > 0 ? userRating : existing?.score
            _ = try await services.aniListClient.saveMediaListEntry(
                token: token,
                mediaId: mediaId,
                status: aniListStatus(for: status),
                progress: progress,
                score: score,
                startedAt: dates.startedAt,
                completedAt: dates.completedAt
            )
            services.aniListClient.clearLibraryCache(token: token)
            services.aniListClient.clearTrackingCaches(for: mediaId)
        } catch {
            AppLog.error(.network, "tracking sync failed mediaId=\(mediaId) \(error.localizedDescription)")
        }
    }

    private func resolvedTrackingDates(
        existing: AniListTrackingEntry?,
        status: MediaStatus,
        progress: Int,
        totalEpisodes: Int?
    ) -> (startedAt: AniListFuzzyDate?, completedAt: AniListFuzzyDate?) {
        let today = AniListFuzzyDate.today()
        var startedAt = existing?.startedAt
        var completedAt = existing?.completedAt

        if startedAt == nil,
           progress > 0 || status == .watching || status == .completed {
            startedAt = today
        }

        let shouldComplete = status == .completed || (totalEpisodes ?? 0) > 0 && progress >= (totalEpisodes ?? 0)
        if shouldComplete {
            if completedAt == nil {
                completedAt = today
            }
            if startedAt == nil {
                startedAt = today
            }
        } else {
            completedAt = nil
        }

        return (startedAt, completedAt)
    }
}

