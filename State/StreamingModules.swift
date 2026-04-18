import Foundation

enum StreamingProvider: String, CaseIterable, Identifiable, Codable {
    case animePahe
    case animeKai
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .animePahe: return "AnimePahe"
        case .animeKai: return "AnimeKai"
        case .custom: return "Custom"
        }
    }

    var summary: String {
        switch self {
        case .animePahe:
            return "Fast direct API fallback when AnimePahe is healthy."
        case .animeKai:
            return "Luna-powered AnimeKai source with alternate search, episodes, and streams."
        case .custom:
            return "User-added module using its own manifest and script."
        }
    }
}

enum StreamingModuleStoreError: LocalizedError {
    case invalidJSON
    case missingField(String)
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Invalid module JSON."
        case .missingField(let field):
            return "Missing required field: \(field)"
        case .invalidURL(let field):
            return "Invalid URL in field: \(field)"
        }
    }
}

struct StreamingModule: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var behavior: StreamingProvider
    var manifestJSON: String
    var metadata: ServiceMetadata
    var manifestURLString: String?
    var isBuiltIn: Bool

    var manifestURL: URL? {
        manifestURLString.flatMap(URL.init(string:))
    }

    var title: String {
        name.isEmpty ? metadata.sourceName : name
    }

    var summary: String {
        behavior.summary
    }
}

struct StreamingExtensionRecord: Identifiable, Equatable {
    let moduleID: String
    let title: String
    let behavior: StreamingProvider
    let installedVersion: String
    let remoteVersion: String?
    let sourceURL: URL?
    let scriptURL: URL
    let lastCheckedAt: Date?
    let hasUpdate: Bool
    let isBuiltIn: Bool

    var id: String { moduleID }
}

enum StreamPreferenceMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case manual = "Manual"

    var id: String { rawValue }
}

enum AudioPreferenceOption: String, CaseIterable, Identifiable {
    case sub = "Sub"
    case dub = "Dub"
    case any = "Any"
    case manual = "Manual"

    var id: String { rawValue }
}

enum QualityPreferenceOption: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case q1080 = "1080p"
    case q720 = "720p"
    case q360 = "360p"
    case manual = "Manual"

    var id: String { rawValue }
}

final class StreamingModuleStore {
    static let shared = StreamingModuleStore()

    private let defaults = UserDefaults.standard
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let modulesKey = "streaming.modules"
    private let selectedModuleKey = "settings.streamingModuleID"
    private let legacySelectedProviderKey = "settings.streamingProvider"
    private let animePaheID = "builtin.animepahe"
    private let animeKaiID = "builtin.animekai"

    private init() {
        seedIfNeeded()
    }

    func seedIfNeeded() {
        if defaults.data(forKey: modulesKey) != nil {
            reconcileBuiltInsIfNeeded()
            migrateSelectedModuleIfNeeded()
            return
        }

        let modules = builtInModules()
        if let data = try? encoder.encode(modules) {
            defaults.set(data, forKey: modulesKey)
        }
        migrateSelectedModuleIfNeeded()
    }

    func modules() -> [StreamingModule] {
        seedIfNeeded()
        guard let modules = decodedModules(),
              !modules.isEmpty else {
            return builtInModules()
        }
        return modules
    }

    func module(id: String?) -> StreamingModule? {
        let modules = modules()
        if let id, let module = modules.first(where: { $0.id == id }) {
            return module
        }
        return modules.first
    }

    func currentModule() -> StreamingModule {
        module(id: selectedModuleID()) ?? builtInModules()[0]
    }

    func selectedModuleID() -> String {
        seedIfNeeded()
        let selected = defaults.string(forKey: selectedModuleKey)
        let available = availableModulesWithoutSeeding()
        if let selected, available.contains(where: { $0.id == selected }) {
            return selected
        }
        return available.first?.id ?? animePaheID
    }

    func setSelectedModuleID(_ id: String) {
        defaults.set(id, forKey: selectedModuleKey)
    }

    func upsertModule(moduleID: String?, name: String?, behavior: StreamingProvider, manifestJSON: String, manifestURLString: String?) throws -> StreamingModule {
        let metadata = try validatedMetadata(from: manifestJSON)
        var modules = modules()
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let module = StreamingModule(
            id: moduleID ?? "custom.\(UUID().uuidString.lowercased())",
            name: (trimmedName?.isEmpty == false ? trimmedName! : metadata.sourceName),
            behavior: behavior,
            manifestJSON: manifestJSON,
            metadata: metadata,
            manifestURLString: manifestURLString,
            isBuiltIn: moduleID == animePaheID || moduleID == animeKaiID
        )

        if let index = modules.firstIndex(where: { $0.id == module.id }) {
            modules[index] = module
        } else {
            modules.append(module)
        }
        try persist(modules)
        return module
    }

    func deleteModule(id: String) {
        var modules = modules()
        guard let index = modules.firstIndex(where: { $0.id == id }), !modules[index].isBuiltIn else { return }
        modules.remove(at: index)
        try? persist(modules)
        if selectedModuleID() == id {
            defaults.set(modules.first?.id ?? animePaheID, forKey: selectedModuleKey)
        }
    }

    func migrateMatchProvider(_ rawProvider: String?) -> String {
        switch rawProvider {
        case StreamingProvider.animeKai.rawValue:
            return animeKaiID
        case StreamingProvider.animePahe.rawValue, nil:
            return animePaheID
        default:
            return rawProvider ?? animePaheID
        }
    }

    static func builtInModuleIDs() -> [String] {
        [shared.animePaheID, shared.animeKaiID]
    }

    private func persist(_ modules: [StreamingModule]) throws {
        let data = try encoder.encode(modules)
        defaults.set(data, forKey: modulesKey)
    }

    private func reconcileBuiltInsIfNeeded() {
        guard var existing = decodedModules() else { return }
        let builtIns = builtInModules()
        var didChange = false

        for builtIn in builtIns.reversed() {
            if existing.contains(where: { $0.id == builtIn.id }) == false {
                existing.insert(builtIn, at: 0)
                didChange = true
            }
        }

        if didChange {
            try? persist(existing)
        }
    }

    private func decodedModules() -> [StreamingModule]? {
        guard let data = defaults.data(forKey: modulesKey) else {
            return nil
        }
        return try? decoder.decode([StreamingModule].self, from: data)
    }

    private func migrateSelectedModuleIfNeeded() {
        let availableIDs = Set(availableModulesWithoutSeeding().map(\.id))
        if let selected = defaults.string(forKey: selectedModuleKey),
           availableIDs.contains(selected) {
            return
        }

        let legacy = defaults.string(forKey: legacySelectedProviderKey)
        let migrated = migrateMatchProvider(legacy)
        defaults.set(availableIDs.contains(migrated) ? migrated : (availableModulesWithoutSeeding().first?.id ?? animePaheID), forKey: selectedModuleKey)
    }

    private func builtInModules() -> [StreamingModule] {
        [
            builtInModule(
                id: animePaheID,
                behavior: .animePahe,
                manifestURLString: "https://git.luna-app.eu/ibro/services/raw/branch/main/animepahe/animepahe.json",
                metadata: ServiceMetadata(
                    sourceName: "AnimePahe",
                    author: .init(
                        name: "50/50",
                        icon: "https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQ3122kQwublLkZ6rf1fEpUP79BxZOFmH9BSA&s"
                    ),
                    iconUrl: "https://files.catbox.moe/fu5sq7.png",
                    version: "1.0.1",
                    language: "English",
                    baseUrl: "https://animepahe.pw/",
                    streamType: "HLS",
                    quality: "1080p",
                    searchBaseUrl: "https://animepahe.pw/",
                    scriptUrl: "https://git.luna-app.eu/50n50/sources/raw/branch/main/animepahe/animepahe.js",
                    softsub: true,
                    type: "anime"
                )
            ),
            builtInModule(
                id: animeKaiID,
                behavior: .animeKai,
                manifestURLString: "https://git.luna-app.eu/50n50/sources/raw/branch/main/animekai/animekai.json",
                metadata: ServiceMetadata(
                    sourceName: "AnimeKai",
                    author: .init(
                        name: "50/50",
                        icon: "https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQ3122kQwublLkZ6rf1fEpUP79BxZOFmH9BSA&s"
                    ),
                    iconUrl: "https://apktodo.io/uploads/2025/5/animekai-icon.jpg",
                    version: "1.0.1",
                    language: "English",
                    baseUrl: "https://animekai.to/",
                    streamType: "HLS",
                    quality: "1080p",
                    searchBaseUrl: "https://animekai.to/",
                    scriptUrl: "https://git.luna-app.eu/50n50/sources/raw/branch/main/animekai/animekai.js",
                    softsub: false,
                    type: "anime"
                )
            )
        ]
    }

    private func builtInModule(
        id: String,
        behavior: StreamingProvider,
        manifestURLString: String,
        metadata: ServiceMetadata
    ) -> StreamingModule {
        let manifestJSON = prettyJSONString(for: metadata)
        return StreamingModule(
            id: id,
            name: metadata.sourceName,
            behavior: behavior,
            manifestJSON: manifestJSON,
            metadata: metadata,
            manifestURLString: manifestURLString,
            isBuiltIn: true
        )
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

    private func availableModulesWithoutSeeding() -> [StreamingModule] {
        guard let decoded = decodedModules(), !decoded.isEmpty else {
            return builtInModules()
        }
        return decoded
    }

    private func validatedMetadata(from manifestJSON: String) throws -> ServiceMetadata {
        guard let data = manifestJSON.data(using: .utf8) else {
            throw StreamingModuleStoreError.invalidJSON
        }
        let metadata: ServiceMetadata
        do {
            metadata = try decoder.decode(ServiceMetadata.self, from: data)
        } catch {
            throw StreamingModuleStoreError.invalidJSON
        }

        if metadata.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || metadata.sourceName == "Unknown" {
            throw StreamingModuleStoreError.missingField("sourceName")
        }
        if metadata.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw StreamingModuleStoreError.missingField("baseUrl")
        }
        if metadata.scriptUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw StreamingModuleStoreError.missingField("scriptUrl")
        }
        if metadata.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw StreamingModuleStoreError.missingField("version")
        }
        guard URL(string: metadata.baseUrl) != nil else {
            throw StreamingModuleStoreError.invalidURL("baseUrl")
        }
        guard URL(string: metadata.scriptUrl) != nil else {
            throw StreamingModuleStoreError.invalidURL("scriptUrl")
        }
        if metadata.searchBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           URL(string: metadata.searchBaseUrl) == nil {
            throw StreamingModuleStoreError.invalidURL("searchBaseUrl")
        }
        if metadata.iconUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           URL(string: metadata.iconUrl) == nil {
            throw StreamingModuleStoreError.invalidURL("iconUrl")
        }
        return metadata
    }
}
