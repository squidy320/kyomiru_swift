import Foundation

final class AppServices {
    let keychain = KeychainService()
    let cacheStore = CacheStore()
    let aniListClient: AniListClient
    let aniListAuth: AniListAuthService

    init() {
        self.aniListClient = AniListClient(cacheStore: cacheStore)
        self.aniListAuth = AniListAuthService()
    }
}
