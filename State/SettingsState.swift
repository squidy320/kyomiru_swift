import SwiftUI

final class SettingsState: ObservableObject {
    @Published var defaultAudio: String = "Sub"
    @Published var defaultQuality: String = "Auto"
    @Published var autoSyncAniList: Bool = true
    @Published var showPlayerDebugOverlay: Bool = false
    @AppStorage("settings.cardImageSource") private var cardImageSourceRaw: String = CardImageSource.tmdb.rawValue

    var cardImageSource: CardImageSource {
        get { CardImageSource(rawValue: cardImageSourceRaw) ?? .tmdb }
        set { cardImageSourceRaw = newValue.rawValue }
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
