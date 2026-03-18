import Foundation

struct EpisodeImportCandidate: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let fileName: String
    var episodeNumber: Int?
}
