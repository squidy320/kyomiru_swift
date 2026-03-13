import Foundation

typealias AniListService = AniListClient
typealias MediaRemuxer = MediaConversionManager

final class LibraryStore {
    static let shared = LibraryStore()
    private init() {}
}

struct DependencyContainer: Sendable {
    let aniListService: AniListService
    let downloadManager: DownloadManager
    let mediaRemuxer: MediaRemuxer
    let libraryStore: LibraryStore
}

actor AppDependencyContainer {
    static let shared = AppDependencyContainer()

    let aniListService: AniListService
    let downloadManager: DownloadManager
    let mediaRemuxer: MediaRemuxer
    let libraryStore: LibraryStore

    init(
        aniListService: AniListService = AniListClient(cacheStore: CacheStore()),
        downloadManager: DownloadManager = .shared,
        mediaRemuxer: MediaRemuxer = .shared,
        libraryStore: LibraryStore = .shared
    ) {
        self.aniListService = aniListService
        self.downloadManager = downloadManager
        self.mediaRemuxer = mediaRemuxer
        self.libraryStore = libraryStore
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
