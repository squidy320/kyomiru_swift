import Foundation

struct SoraSubtitleTrack: Identifiable, Equatable, Codable, Hashable {
    let id: String
    let url: URL
    let label: String
    let languageCode: String?
    let format: String

    init(
        id: String? = nil,
        url: URL,
        label: String,
        languageCode: String? = nil,
        format: String? = nil
    ) {
        self.id = id ?? url.absoluteString
        self.url = url
        self.label = label
        self.languageCode = languageCode
        let explicitFormat = format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let inferred = url.pathExtension.lowercased()
        self.format = (explicitFormat?.isEmpty == false ? explicitFormat! : inferred.isEmpty ? "unknown" : inferred)
    }
}

struct SoraAnimeMatch: Identifiable, Equatable {
    let id: String
    let title: String
    let imageURL: URL?
    let session: String
    let detailURL: URL?
    let year: Int?
    let format: String?
    let episodeCount: Int?
    let normalizedTitle: String?
    let matchScore: Double?
    let matchContext: String?

    init(
        id: String,
        title: String,
        imageURL: URL?,
        session: String,
        detailURL: URL?,
        year: Int?,
        format: String?,
        episodeCount: Int?,
        normalizedTitle: String? = nil,
        matchScore: Double? = nil,
        matchContext: String? = nil
    ) {
        self.id = id
        self.title = title
        self.imageURL = imageURL
        self.session = session
        self.detailURL = detailURL
        self.year = year
        self.format = format
        self.episodeCount = episodeCount
        self.normalizedTitle = normalizedTitle
        self.matchScore = matchScore
        self.matchContext = matchContext
    }
}

struct SoraEpisode: Identifiable, Equatable, Codable {
    let id: String
    let sourceNumber: Int
    let displayNumber: Int
    let playURL: URL

    var number: Int { displayNumber }

    init(id: String, number: Int, playURL: URL) {
        self.id = id
        self.sourceNumber = number
        self.displayNumber = number
        self.playURL = playURL
    }

    init(id: String, sourceNumber: Int, displayNumber: Int, playURL: URL) {
        self.id = id
        self.sourceNumber = sourceNumber
        self.displayNumber = displayNumber
        self.playURL = playURL
    }
}

struct SoraSource: Identifiable, Equatable {
    let id: String
    let url: URL
    let quality: String
    let subOrDub: String
    let format: String
    let headers: [String: String]
    let subtitleTracks: [SoraSubtitleTrack]

    init(
        id: String,
        url: URL,
        quality: String,
        subOrDub: String,
        format: String,
        headers: [String: String],
        subtitleTracks: [SoraSubtitleTrack] = []
    ) {
        self.id = id
        self.url = url
        self.quality = quality
        self.subOrDub = subOrDub
        self.format = format
        self.headers = headers
        self.subtitleTracks = subtitleTracks
    }
}
