import Foundation

struct AniZipMapping: Codable {
    let tmdb_id: Int?
    let tvdb_id: Int?
    let mal_id: Int?
}

struct AniZipClient {
    static func fetchMapping(aniListId: Int) async -> AniZipMapping? {
        let url = URL(string: "https://ani.zip/anilist/\(aniListId)")!
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(AniZipMapping.self, from: data)
        } catch {
            AppLog.error(.network, "ani.zip fetch failed for \(aniListId): \(error)")
            return nil
        }
    }
}