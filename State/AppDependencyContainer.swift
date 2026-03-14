import Foundation

typealias AniListService = AniListClient
typealias MediaRemuxer = MediaConversionManager

struct DependencyContainer {
    let aniListService: AniListService
    let downloadManager: DownloadManager
    let mediaRemuxer: MediaRemuxer
    let libraryStore: MediaTracker
}

actor AppDependencyContainer {
    static func shared() async -> AppDependencyContainer {
        await AppDependencyContainer()
    }

    let aniListService: AniListService
    let downloadManager: DownloadManager
    let mediaRemuxer: MediaRemuxer
    let libraryStore: MediaTracker

    init(
        aniListService: AniListService? = nil,
        downloadManager: DownloadManager? = nil,
        mediaRemuxer: MediaRemuxer? = nil,
        libraryStore: MediaTracker? = nil
    ) async {
        self.aniListService = aniListService ?? AniListClient(cacheStore: CacheStore())
        if let downloadManager {
            self.downloadManager = downloadManager
        } else {
            self.downloadManager = await MainActor.run { DownloadManager.shared }
        }
        self.mediaRemuxer = mediaRemuxer ?? .shared
        self.libraryStore = libraryStore ?? MediaTracker()
    }

    func container() -> DependencyContainer {
        DependencyContainer(
            aniListService: aniListService,
            downloadManager: downloadManager,
            mediaRemuxer: mediaRemuxer,
            libraryStore: libraryStore
        )
    }
}
