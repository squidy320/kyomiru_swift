import Foundation

struct StreamingExtensionRecord: Identifiable, Equatable {
    let provider: StreamingProvider
    let installedVersion: String
    let remoteVersion: String?
    let sourceURL: URL
    let scriptURL: URL
    let lastCheckedAt: Date?
    let hasUpdate: Bool

    var id: String { provider.rawValue }
}

final class StreamingExtensionManager {
    private let defaults = UserDefaults.standard
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let session: URLSession
    private let checkInterval: TimeInterval = 6 * 60 * 60

    init(session: URLSession = .custom) {
        self.session = session
    }

    func installedRecords() -> [StreamingExtensionRecord] {
        StreamingProvider.allCases.map { provider in
            let installed = Self.cachedMetadata(for: provider) ?? provider.fallbackMetadata
            let remote = cachedRemoteMetadata(for: provider)
            return makeRecord(provider: provider, installed: installed, remote: remote)
        }
    }

    func refreshIfNeeded() async {
        let staleProviders = StreamingProvider.allCases.filter { provider in
            guard let lastChecked = lastCheckedAt(for: provider) else { return true }
            return Date().timeIntervalSince(lastChecked) >= checkInterval
        }
        guard !staleProviders.isEmpty else { return }
        _ = await refresh(providers: staleProviders)
    }

    func refreshAll(force: Bool = false) async -> [StreamingExtensionRecord] {
        let providers = force ? StreamingProvider.allCases : StreamingProvider.allCases.filter { provider in
            guard let lastChecked = lastCheckedAt(for: provider) else { return true }
            return Date().timeIntervalSince(lastChecked) >= checkInterval
        }
        if providers.isEmpty {
            return installedRecords()
        }
        return await refresh(providers: providers)
    }

    func update(provider: StreamingProvider) async throws -> StreamingExtensionRecord {
        let remote = try await fetchManifest(for: provider)
        try saveMetadata(remote, for: provider, keyPrefix: "streaming.extension.installed")
        try saveMetadata(remote, for: provider, keyPrefix: "streaming.extension.remote")
        defaults.set(Date().timeIntervalSince1970, forKey: lastCheckedKey(for: provider))
        return makeRecord(provider: provider, installed: remote, remote: remote)
    }

    static func cachedMetadata(for provider: StreamingProvider) -> ServiceMetadata? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: metadataKey(for: provider, prefix: "streaming.extension.installed")) else {
            return nil
        }
        return try? JSONDecoder().decode(ServiceMetadata.self, from: data)
    }

    private func refresh(providers: [StreamingProvider]) async -> [StreamingExtensionRecord] {
        for provider in providers {
            do {
                let remote = try await fetchManifest(for: provider)
                let installed = Self.cachedMetadata(for: provider) ?? provider.fallbackMetadata
                if remote.version != installed.version || remote.scriptUrl != installed.scriptUrl || remote.baseUrl != installed.baseUrl {
                    try saveMetadata(remote, for: provider, keyPrefix: "streaming.extension.installed")
                    AppLog.debug(.network, "extension auto-updated provider=\(provider.title) version=\(remote.version)")
                }
                try saveMetadata(remote, for: provider, keyPrefix: "streaming.extension.remote")
                defaults.set(Date().timeIntervalSince1970, forKey: lastCheckedKey(for: provider))
            } catch {
                AppLog.error(.network, "extension refresh failed provider=\(provider.title) \(error.localizedDescription)")
            }
        }
        return installedRecords()
    }

    private func fetchManifest(for provider: StreamingProvider) async throws -> ServiceMetadata {
        AppLog.debug(.network, "extension manifest fetch start provider=\(provider.title)")
        var request = URLRequest(url: provider.manifestURL)
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        let metadata = try decoder.decode(ServiceMetadata.self, from: data)
        AppLog.debug(.network, "extension manifest fetch success provider=\(provider.title) version=\(metadata.version)")
        return metadata
    }

    private func cachedRemoteMetadata(for provider: StreamingProvider) -> ServiceMetadata? {
        guard let data = defaults.data(forKey: Self.metadataKey(for: provider, prefix: "streaming.extension.remote")) else {
            return nil
        }
        return try? decoder.decode(ServiceMetadata.self, from: data)
    }

    private func lastCheckedAt(for provider: StreamingProvider) -> Date? {
        let timestamp = defaults.double(forKey: lastCheckedKey(for: provider))
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func makeRecord(
        provider: StreamingProvider,
        installed: ServiceMetadata,
        remote: ServiceMetadata?
    ) -> StreamingExtensionRecord {
        let installedVersion = installed.version
        let remoteVersion = remote?.version
        let hasUpdate = remoteVersion.map { $0 != installedVersion } ?? false
        let scriptURL = URL(string: installed.scriptUrl) ?? URL(string: provider.fallbackMetadata.scriptUrl)!
        return StreamingExtensionRecord(
            provider: provider,
            installedVersion: installedVersion,
            remoteVersion: remoteVersion,
            sourceURL: provider.manifestURL,
            scriptURL: scriptURL,
            lastCheckedAt: lastCheckedAt(for: provider),
            hasUpdate: hasUpdate
        )
    }

    private func saveMetadata(_ metadata: ServiceMetadata, for provider: StreamingProvider, keyPrefix: String) throws {
        let data = try encoder.encode(metadata)
        defaults.set(data, forKey: Self.metadataKey(for: provider, prefix: keyPrefix))
    }

    private func lastCheckedKey(for provider: StreamingProvider) -> String {
        "streaming.extension.lastChecked.\(provider.rawValue)"
    }

    private static func metadataKey(for provider: StreamingProvider, prefix: String) -> String {
        "\(prefix).\(provider.rawValue)"
    }
}
