import Foundation
import AuthenticationServices
import UIKit

final class AniListAuthService: NSObject {
    private let redirectURI = "kyomiru://auth"

    @MainActor
    func signIn() async throws -> String {
        guard let clientId = Bundle.main.object(forInfoDictionaryKey: "ANILIST_CLIENT_ID") as? String,
              !clientId.isEmpty else {
            AppLog.auth.error("missing AniList client id")
            throw AniListError.invalidResponse
        }
        AppLog.auth.debug("auth start")
        let url = URL(string: "https://anilist.co/api/v2/oauth/authorize?client_id=\(clientId)&response_type=token&redirect_uri=\(redirectURI)")!
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "kyomiru") { callbackURL, error in
                if let error {
                    AppLog.auth.error("auth failed \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL,
                      let fragment = callbackURL.fragment,
                      let token = fragment.split(separator: "&")
                        .map({ $0.split(separator: "=") })
                        .first(where: { $0.first == "access_token" })?.last else {
                    AppLog.auth.error("auth token parse failed")
                    continuation.resume(throwing: AniListError.invalidResponse)
                    return
                }
                AppLog.auth.debug("auth success")
                continuation.resume(returning: String(token))
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
    }
}

extension AniListAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? UIWindow()
    }
}
