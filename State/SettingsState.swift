import SwiftUI

final class SettingsState: ObservableObject {
    @AppStorage("settings.defaultAudio") private var defaultAudioRaw: String = "Sub"
    @AppStorage("settings.defaultQuality") private var defaultQualityRaw: String = "Auto"
    @AppStorage("settings.autoSyncAniList") private var autoSyncAniListRaw: Bool = true
    @AppStorage("settings.showPlayerDebugOverlay") private var showPlayerDebugOverlayRaw: Bool = false
    @AppStorage("settings.cardImageSource") private var cardImageSourceRaw: String = CardImageSource.tmdb.rawValue
    @AppStorage("settings.playerSkipIntervalSeconds") private var playerSkipIntervalRaw: Double = 85
    @AppStorage("settings.playerHoldSpeed") private var playerHoldSpeedRaw: Double = PlayerHoldSpeed.twoX.rawValue
    @AppStorage("settings.appearanceThemeMode") private var appearanceThemeModeRaw: String = AppearanceThemeMode.system.rawValue
    @AppStorage("settings.reduceMotion") private var reduceMotionRaw: Bool = false
    @AppStorage("settings.useComfortableLayout") private var useComfortableLayoutRaw: Bool = true

    var defaultAudio: String {
        get { defaultAudioRaw }
        set {
            defaultAudioRaw = newValue
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

    var autoSyncAniList: Bool {
        get { autoSyncAniListRaw }
        set {
            autoSyncAniListRaw = newValue
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

    var cardImageSource: CardImageSource {
        get { CardImageSource(rawValue: cardImageSourceRaw) ?? .tmdb }
        set {
            cardImageSourceRaw = newValue.rawValue
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
}

enum CardImageSource: String, CaseIterable, Identifiable {
    case tmdb
    case anilist

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tmdb: return "TMDB"
        case .anilist: return "AniList"
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
