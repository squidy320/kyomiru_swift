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
        AppLog.debug(.auth, "auth bootstrap start")
        if let saved = services.keychain.readToken(key: tokenKey) {
            token = saved
            await loadViewer()
        }
        AppLog.debug(.auth, "auth bootstrap complete signedIn=\(self.isSignedIn)")
    }

    func signIn() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            AppLog.debug(.auth, "auth sign in start")
            let newToken = try await services.aniListAuth.signIn()
            token = newToken
            services.keychain.saveToken(newToken, key: tokenKey)
            await loadViewer()
            AppLog.debug(.auth, "auth sign in success")
        } catch {
            AppLog.error(.auth, "auth sign in failed \(error.localizedDescription)")
            token = nil
            user = nil
        }
    }

    func signOut() {
        AppLog.debug(.auth, "auth sign out")
        token = nil
        user = nil
        services.keychain.deleteToken(key: tokenKey)
    }

    func loadViewer() async {
        guard let token else { return }
        do {
            AppLog.debug(.auth, "auth viewer load start")
            let viewer = try await services.aniListClient.viewer(token: token)
            user = viewer
            AppLog.debug(.auth, "auth viewer load success")
        } catch {
            AppLog.error(.auth, "auth viewer load failed \(error.localizedDescription)")
            user = nil
        }
    }
}

