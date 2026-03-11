import SwiftUI

@MainActor
final class AuthState: ObservableObject {
    @Published var isLoading = false
    @Published var token: String? = nil
    @Published var user: AniListUser? = nil

    private let services: AppServices
    private let tokenKey = "anilist_token"

    init(services: AppServices) {
        self.services = services
    }

    var isSignedIn: Bool {
        let t = token ?? ""
        return !t.isEmpty
    }

    func bootstrap() async {
        AppLog.auth.debug("auth bootstrap start")
        if let saved = services.keychain.readToken(key: tokenKey) {
            token = saved
            await loadViewer()
        }
        AppLog.auth.debug("auth bootstrap complete signedIn=\(isSignedIn)")
    }

    func signIn() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            AppLog.auth.debug("auth sign in start")
            let newToken = try await services.aniListAuth.signIn()
            token = newToken
            services.keychain.saveToken(newToken, key: tokenKey)
            await loadViewer()
            AppLog.auth.debug("auth sign in success")
        } catch {
            AppLog.auth.error("auth sign in failed \(error.localizedDescription, privacy: .public)")
            token = nil
            user = nil
        }
    }

    func signOut() {
        AppLog.auth.debug("auth sign out")
        token = nil
        user = nil
        services.keychain.deleteToken(key: tokenKey)
    }

    func loadViewer() async {
        guard let token else { return }
        do {
            AppLog.auth.debug("auth viewer load start")
            let viewer = try await services.aniListClient.viewer(token: token)
            user = viewer
            AppLog.auth.debug("auth viewer load success")
        } catch {
            AppLog.auth.error("auth viewer load failed \(error.localizedDescription, privacy: .public)")
            user = nil
        }
    }
}
