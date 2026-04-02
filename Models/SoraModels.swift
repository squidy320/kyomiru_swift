import Foundation

struct SoraAnimeMatch: Identifiable, Equatable {
    let id: String
    let title: String
    let imageURL: URL?
    let session: String
    let detailURL: URL?
    let year: Int?
    let format: String?
    let episodeCount: Int?
}

struct SoraEpisode: Identifiable, Equatable {
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
}
