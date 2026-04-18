import Foundation

final class StreamingExtensionManager {
    private let defaults = UserDefaults.standard
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let session: URLSession
    private let checkInterval: TimeInterval = 6 * 60 * 60
    private let moduleStore = StreamingModuleStore.shared

    init(session: URLSession = .custom) {
        self.session = session
    }

    func installedRecords() -> [StreamingExtensionRecord] {
        moduleStore.modules().map { module in
            let remote = cachedRemoteMetadata(for: module.id)
            return makeRecord(module: module, installed: module.metadata, remote: remote)
        }
    }

    func refreshIfNeeded() async {
        let staleModules = moduleStore.modules().filter { module in
            guard module.manifestURL != nil else { return false }
            guard let lastChecked = lastCheckedAt(for: module.id) else { return true }
            return Date().timeIntervalSince(lastChecked) >= checkInterval
        }
        guard !staleModules.isEmpty else { return }
        _ = await refresh(modules: staleModules)
    }

    func refreshAll(force: Bool = false) async -> [StreamingExtensionRecord] {
        let modules = moduleStore.modules().filter { $0.manifestURL != nil }
        let eligible = force ? modules : modules.filter { module in
            guard let lastChecked = lastCheckedAt(for: module.id) else { return true }
            return Date().timeIntervalSince(lastChecked) >= checkInterval
        }
        if eligible.isEmpty {
            return installedRecords()
        }
        return await refresh(modules: eligible)
    }

    func update(moduleID: String) async throws -> StreamingExtensionRecord {
        guard let module = moduleStore.module(id: moduleID) else {
            throw URLError(.badURL)
        }
        let remote = try await fetchManifest(for: module)
        let updated = try moduleStore.upsertModule(
            moduleID: module.id,
            name: module.name,
            behavior: module.behavior,
            manifestJSON: prettyJSONString(for: remote),
            manifestURLString: module.manifestURLString
        )
        try saveMetadata(remote, for: module.id, keyPrefix: "streaming.extension.remote")
        defaults.set(Date().timeIntervalSince1970, forKey: lastCheckedKey(for: module.id))
        return makeRecord(module: updated, installed: updated.metadata, remote: remote)
    }

    private func refresh(modules: [StreamingModule]) async -> [StreamingExtensionRecord] {
        for module in modules {
            do {
                let remote = try await fetchManifest(for: module)
                try saveMetadata(remote, for: module.id, keyPrefix: "streaming.extension.remote")
                defaults.set(Date().timeIntervalSince1970, forKey: lastCheckedKey(for: module.id))
            } catch {
                AppLog.error(.network, "extension refresh failed module=\(module.title) \(error.localizedDescription)")
            }
        }
        return installedRecords()
    }

    private func fetchManifest(for module: StreamingModule) async throws -> ServiceMetadata {
        guard let manifestURL = module.manifestURL else {
            throw URLError(.badURL)
        }
        AppLog.debug(.network, "extension manifest fetch start module=\(module.title)")
        var request = URLRequest(url: manifestURL)
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        let metadata = try decoder.decode(ServiceMetadata.self, from: data)
        AppLog.debug(.network, "extension manifest fetch success module=\(module.title) version=\(metadata.version)")
        return metadata
    }

    private func cachedRemoteMetadata(for moduleID: String) -> ServiceMetadata? {
        guard let data = defaults.data(forKey: Self.metadataKey(for: moduleID, prefix: "streaming.extension.remote")) else {
            return nil
        }
        return try? decoder.decode(ServiceMetadata.self, from: data)
    }

    private func lastCheckedAt(for moduleID: String) -> Date? {
        let timestamp = defaults.double(forKey: lastCheckedKey(for: moduleID))
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func makeRecord(
        module: StreamingModule,
        installed: ServiceMetadata,
        remote: ServiceMetadata?
    ) -> StreamingExtensionRecord {
        let installedVersion = installed.version
        let remoteVersion = remote?.version
        let hasUpdate = remote.map {
            $0.version != installed.version ||
            $0.scriptUrl != installed.scriptUrl ||
            $0.baseUrl != installed.baseUrl ||
            $0.searchBaseUrl != installed.searchBaseUrl
        } ?? false
        let scriptURL = URL(string: installed.scriptUrl) ?? URL(string: module.metadata.scriptUrl)!
        return StreamingExtensionRecord(
            moduleID: module.id,
            title: module.title,
            behavior: module.behavior,
            installedVersion: installedVersion,
            remoteVersion: remoteVersion,
            sourceURL: module.manifestURL,
            scriptURL: scriptURL,
            lastCheckedAt: lastCheckedAt(for: module.id),
            hasUpdate: hasUpdate,
            isBuiltIn: module.isBuiltIn
        )
    }

    private func saveMetadata(_ metadata: ServiceMetadata, for moduleID: String, keyPrefix: String) throws {
        let data = try encoder.encode(metadata)
        defaults.set(data, forKey: Self.metadataKey(for: moduleID, prefix: keyPrefix))
    }

    private func lastCheckedKey(for moduleID: String) -> String {
        "streaming.extension.lastChecked.\(moduleID)"
    }

    private static func metadataKey(for moduleID: String, prefix: String) -> String {
        "\(prefix).\(moduleID)"
    }

    private func prettyJSONString(for metadata: ServiceMetadata) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(metadata),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

@MainActor
final class AppServices {
    let keychain = KeychainService()
    let cacheStore = CacheStore()
    let metadataCacheManager = MetadataCacheManager()
    let aniListClient: AniListClient
    let aniListAuth: AniListAuthService
    let mediaTracker: MediaTracker
    let playbackEngine: PlaybackEngine
    let offlineManager: OfflineManager
    let metadataService: MetadataService
    let episodeMetadataService: EpisodeMetadataService
    let tmdbMatchingService: TMDBMatchingService
    let aniSkipService: AniSkipService
    let trendingService: TrendingService
    let ratingService: RatingService
    let downloadManager: DownloadManager
    let libraryStore: MediaTracker
    let episodeService: EpisodeService
    let streamingExtensionManager: StreamingExtensionManager

    init() {
        self.aniListClient = AniListClient(cacheStore: cacheStore)
        self.aniListAuth = AniListAuthService()
        self.mediaTracker = MediaTracker()
        self.playbackEngine = PlaybackEngine()
        self.offlineManager = OfflineManager()
        self.tmdbMatchingService = TMDBMatchingService(cacheStore: cacheStore, cacheManager: metadataCacheManager, aniListClient: aniListClient)
        self.metadataService = MetadataService(cacheStore: cacheStore, tmdbMatcher: tmdbMatchingService, metadataCacheManager: metadataCacheManager)
        self.episodeMetadataService = EpisodeMetadataService(
            cacheStore: cacheStore,
            aniListClient: aniListClient,
            provider: .tvdb,
            tmdbMatcher: tmdbMatchingService,
            cacheManager: metadataCacheManager
        )
        self.aniSkipService = AniSkipService()
        self.trendingService = TrendingService(cacheStore: cacheStore)
        self.ratingService = RatingService(cacheStore: cacheStore, tmdbMatcher: tmdbMatchingService)
        self.downloadManager = DownloadManager.shared
        self.libraryStore = MediaTracker()
        self.episodeService = EpisodeService(tmdbMatcher: tmdbMatchingService, cacheStore: cacheStore)
        self.streamingExtensionManager = StreamingExtensionManager()
    }
}
