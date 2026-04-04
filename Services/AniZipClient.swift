import Foundation

public struct AniZipMapping: Codable {
    public let tmdb_id: Int?
    public let tvdb_id: Int?
    public let mal_id: Int?
}

public struct AniZipClient {
    public static func fetchMapping(aniListId: Int) async -> AniZipMapping? {
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