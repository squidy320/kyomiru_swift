import Foundation

struct AniSkipSegment: Codable, Equatable, Hashable {
    let type: String
    let start: Double
    let end: Double
}

final class AniSkipService {
    private let session: URLSession

    init(session: URLSession = .custom) {
        self.session = session
    }

    func fetchSkipSegments(malId: Int, episode: Int) async -> [AniSkipSegment] {
        guard let url = URL(string: "https://api.aniskip.com/v2/skip-times/\(malId)/\(episode)?types=op,ed,recap,preview") else {
            return []
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            let decoded = try JSONDecoder().decode(AniSkipResponse.self, from: data)
            let segments = decoded.results.map {
                AniSkipSegment(
                    type: $0.skipType,
                    start: $0.interval.startTime,
                    end: $0.interval.endTime
                )
            }
            return segments
        } catch {
            return []
        }
    }
}

private struct AniSkipResponse: Decodable {
    let results: [AniSkipResult]
}

private struct AniSkipResult: Decodable {
    let skipType: String
    let interval: AniSkipInterval
}

private struct AniSkipInterval: Decodable {
    let startTime: Double
    let endTime: Double
}
