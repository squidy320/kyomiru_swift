import SwiftUI

final class SettingsState: ObservableObject {
    @AppStorage("settings.streamingProvider") private var streamingProviderRaw: String = StreamingProvider.animePahe.rawValue
    @AppStorage("settings.defaultAudio") private var defaultAudioRaw: String = "Sub"
    @AppStorage("settings.defaultQuality") private var defaultQualityRaw: String = "Auto"
    @AppStorage("settings.playerBackend") private var playerBackendRaw: String = PlayerBackend.mpv.rawValue
    @AppStorage("settings.autoSyncAniList") private var autoSyncAniListRaw: Bool = true
    @AppStorage("settings.autoSkipSegments") private var autoSkipSegmentsRaw: Bool = false
    @AppStorage("settings.showPlayerDebugOverlay") private var showPlayerDebugOverlayRaw: Bool = false
    @AppStorage("settings.playerSkipIntervalSeconds") private var playerSkipIntervalRaw: Double = 85
    @AppStorage("settings.playerHoldSpeed") private var playerHoldSpeedRaw: Double = PlayerHoldSpeed.twoX.rawValue
    @AppStorage("settings.appearanceThemeMode") private var appearanceThemeModeRaw: String = AppearanceThemeMode.system.rawValue
    @AppStorage("settings.reduceMotion") private var reduceMotionRaw: Bool = false
    @AppStorage("settings.useComfortableLayout") private var useComfortableLayoutRaw: Bool = true
    @AppStorage("settings.accentColor.red") private var accentColorRedRaw: Double = 0.47
    @AppStorage("settings.accentColor.green") private var accentColorGreenRaw: Double = 0.72
    @AppStorage("settings.accentColor.blue") private var accentColorBlueRaw: Double = 1.0

    var defaultAudio: String {
        get { defaultAudioRaw }
        set {
            defaultAudioRaw = newValue
            objectWillChange.send()
        }
    }

    var streamingProvider: StreamingProvider {
        get { StreamingProvider(rawValue: streamingProviderRaw) ?? .animePahe }
        set {
            streamingProviderRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    var defaultQuality: String {
        get { defaultQualityRaw }
        set {
            defaultQualityRaw = newValue
            objectWillChange.send()
        }
    }

    var playerBackend: PlayerBackend {
        get {
            let stored = PlayerBackend(rawValue: playerBackendRaw) ?? .mpv
            return stored == .ksplayer ? .mpv : stored
        }
        set {
            playerBackendRaw = (newValue == .ksplayer ? PlayerBackend.mpv : newValue).rawValue
            objectWillChange.send()
        }
    }

    var autoSyncAniList: Bool {
        get { autoSyncAniListRaw }
        set {
            autoSyncAniListRaw = newValue
            objectWillChange.send()
        }
    }

    var autoSkipSegments: Bool {
        get { autoSkipSegmentsRaw }
        set {
            autoSkipSegmentsRaw = newValue
            objectWillChange.send()
        }
    }

    var showPlayerDebugOverlay: Bool {
        get { showPlayerDebugOverlayRaw }
        set {
            showPlayerDebugOverlayRaw = newValue
            objectWillChange.send()
        }
    }

    var playerSkipIntervalSeconds: Double {
        get { playerSkipIntervalRaw }
        set {
            playerSkipIntervalRaw = newValue
            objectWillChange.send()
        }
    }

    var playerHoldSpeed: PlayerHoldSpeed {
        get { PlayerHoldSpeed(rawValue: playerHoldSpeedRaw) ?? .twoX }
        set {
            playerHoldSpeedRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    var appearanceThemeMode: AppearanceThemeMode {
        get { AppearanceThemeMode(rawValue: appearanceThemeModeRaw) ?? .system }
        set {
            appearanceThemeModeRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    var reduceMotion: Bool {
        get { reduceMotionRaw }
        set {
            reduceMotionRaw = newValue
            objectWillChange.send()
        }
    }

    var useComfortableLayout: Bool {
        get { useComfortableLayoutRaw }
        set {
            useComfortableLayoutRaw = newValue
            objectWillChange.send()
        }
    }

    var accentColor: Color {
        get {
            Color(
                red: accentColorRedRaw,
                green: accentColorGreenRaw,
                blue: accentColorBlueRaw
            )
        }
        set {
            let uiColor = UIColor(newValue)
            var red: CGFloat = 0.47
            var green: CGFloat = 0.72
            var blue: CGFloat = 1.0
            var alpha: CGFloat = 1.0
            guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                return
            }
            accentColorRedRaw = red
            accentColorGreenRaw = green
            accentColorBlueRaw = blue
            objectWillChange.send()
        }
    }
}

enum StreamingProvider: String, CaseIterable, Identifiable, Codable {
    case animePahe
    case animeKai

    static let storageKey = "settings.streamingProvider"

    static var current: StreamingProvider {
        let raw = UserDefaults.standard.string(forKey: storageKey)
        return StreamingProvider(rawValue: raw ?? "") ?? .animePahe
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .animePahe: return "AnimePahe"
        case .animeKai: return "AnimeKai"
        }
    }

    var summary: String {
        switch self {
        case .animePahe:
            return "Fast direct API fallback when AnimePahe is healthy."
        case .animeKai:
            return "Luna-powered AnimeKai source with alternate search, episodes, and streams."
        }
    }

    var manifestURL: URL {
        switch self {
        case .animePahe:
            return URL(string: "https://git.luna-app.eu/50n50/sources/raw/branch/main/animepahe/animepahe.json")!
        case .animeKai:
            return URL(string: "https://git.luna-app.eu/50n50/sources/raw/branch/main/animekai/animekai.json")!
        }
    }

    var fallbackMetadata: ServiceMetadata {
        switch self {
        case .animePahe:
            return ServiceMetadata(
                sourceName: "AnimePahe",
                author: .init(
                    name: "50/50",
                    icon: "https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQ3122kQwublLkZ6rf1fEpUP79BxZOFmH9BSA&s"
                ),
                iconUrl: "https://files.catbox.moe/fu5sq7.png",
                version: "1.0.1",
                language: "English",
                baseUrl: "https://animepahe.si/",
                streamType: "HLS",
                quality: "1080p",
                searchBaseUrl: "https://animepahe.si/",
                scriptUrl: "https://git.luna-app.eu/50n50/sources/raw/branch/main/animepahe/animepahe.js",
                softsub: true,
                type: "anime"
            )
        case .animeKai:
            return ServiceMetadata(
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
        }
    }
}

enum PlayerBackend: String, CaseIterable, Identifiable {
    case avPlayer
    case mpv
    case ksplayer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .avPlayer:
            return "AVPlayer"
        case .mpv:
            return "mpv"
        case .ksplayer:
            return "KSPlayer"
        }
    }

    var summary: String {
        switch self {
        case .avPlayer:
            return "Best iOS integration with Picture in Picture support."
        case .mpv:
            return "Advanced playback pipeline with broader codec and subtitle handling."
        case .ksplayer:
            return "Lightweight player with hardware acceleration support."
        }
    }
}

enum AppearanceThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum PlayerHoldSpeed: Double, CaseIterable, Identifiable {
    case onePointFive = 1.5
    case twoX = 2.0
    case twoPointFive = 2.5
    case threeX = 3.0

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .onePointFive: return "1.5x"
        case .twoX: return "2x"
        case .twoPointFive: return "2.5x"
        case .threeX: return "3x"
        }
    }
}

enum LibrarySortOption: String, CaseIterable, Identifiable {
    case lastUpdated
    case score
    case alphabetical

    var id: String { rawValue }
    var title: String {
        switch self {
        case .lastUpdated: return "Last Updated"
        case .score: return "Score"
        case .alphabetical: return "Alphabetical"
        }
    }
}

enum LibraryFormatFilter: String, CaseIterable, Identifiable {
    case all
    case tv
    case movie
    case ova

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All Formats"
        case .tv: return "TV"
        case .movie: return "Movie"
        case .ova: return "OVA"
        }
    }
}

final class LibrarySettingsManager: ObservableObject {
    @AppStorage("library.visibleCatalogs") private var visibleRaw: String = "watching,planning,completed,paused,dropped"
    @AppStorage("library.catalogOrder") private var orderRaw: String = "watching,planning,completed,paused,dropped"
    @AppStorage("library.sort") private var sortRaw: String = LibrarySortOption.lastUpdated.rawValue
    @AppStorage("library.formatFilter") private var formatRaw: String = LibraryFormatFilter.all.rawValue

    @Published var showSettingsSheet: Bool = false

    var sortOption: LibrarySortOption {
        get { LibrarySortOption(rawValue: sortRaw) ?? .lastUpdated }
        set { sortRaw = newValue.rawValue }
    }

    var formatFilter: LibraryFormatFilter {
        get { LibraryFormatFilter(rawValue: formatRaw) ?? .all }
        set { formatRaw = newValue.rawValue }
    }

    var orderedCatalogs: [MediaStatus] {
        let order = parseStatuses(from: orderRaw)
        let visibleSet = Set(parseStatuses(from: visibleRaw))
        let filtered = order.filter { visibleSet.contains($0) }
        if filtered.isEmpty {
            return [.watching, .planning, .completed]
        }
        return filtered
    }

    var visibleStatuses: Set<MediaStatus> {
        Set(parseStatuses(from: visibleRaw))
    }

    var catalogOrder: [MediaStatus] {
        get { parseStatuses(from: orderRaw) }
        set { orderRaw = serializeStatuses(newValue) }
    }

    func toggleVisibility(_ status: MediaStatus) {
        var set = visibleStatuses
        if set.contains(status) {
            set.remove(status)
        } else {
            set.insert(status)
        }
        visibleRaw = serializeStatuses(Array(set))
    }

    func setVisibility(_ status: MediaStatus, isVisible: Bool) {
        var set = visibleStatuses
        if isVisible {
            set.insert(status)
        } else {
            set.remove(status)
        }
        visibleRaw = serializeStatuses(Array(set))
    }

    func move(from offsets: IndexSet, to destination: Int) {
        var list = parseStatuses(from: orderRaw)
        list.move(fromOffsets: offsets, toOffset: destination)
        orderRaw = serializeStatuses(list)
    }

    private func parseStatuses(from raw: String) -> [MediaStatus] {
        raw.split(separator: ",")
            .compactMap { MediaStatus(rawValue: String($0)) }
    }

    private func serializeStatuses(_ list: [MediaStatus]) -> String {
        list.map { $0.rawValue }.joined(separator: ",")
    }
}
