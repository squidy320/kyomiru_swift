import Foundation

struct SoraAnimeMatch: Identifiable, Equatable {
    let id: String
    let title: String
    let imageURL: URL?
    let session: String
    let year: Int?
    let format: String?
    let episodeCount: Int?
}

struct SoraEpisode: Identifiable, Equatable {
    let id: String
    let number: Int
    let playURL: URL
}

struct SoraSource: Identifiable, Equatable {
    let id: String
    let url: URL
    let quality: String
    let subOrDub: String
    let format: String
    let headers: [String: String]
}
