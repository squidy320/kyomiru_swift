import Foundation
import AuthenticationServices
import UIKit

final class AniListAuthService: NSObject {
    private let redirectURI = "kyomiru://auth"
    private var currentSession: ASWebAuthenticationSession?

    @MainActor
    func signIn() async throws -> String {
        guard let clientId = Bundle.main.object(forInfoDictionaryKey: "ANILIST_CLIENT_ID") as? String,
              !clientId.isEmpty else {
            AppLog.error(.auth, "missing AniList client id")
            throw AniListError.invalidResponse
        }
        guard let clientSecret = Bundle.main.object(forInfoDictionaryKey: "ANILIST_CLIENT_SECRET") as? String,
              !clientSecret.isEmpty else {
            AppLog.error(.auth, "missing AniList client secret")
            throw AniListError.invalidResponse
        }
        AppLog.debug(.auth, "auth start")
        let url = URL(string: "https://anilist.co/api/v2/oauth/authorize?client_id=\(clientId)&response_type=code&redirect_uri=\(redirectURI)")!
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "kyomiru") { [weak self] callbackURL, error in
                defer { self?.currentSession = nil }
                if let error {
                    AppLog.error(.auth, "auth failed \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    AppLog.error(.auth, "auth code parse failed")
                    continuation.resume(throwing: AniListError.invalidResponse)
                    return
                }
                Task { [weak self] in
                    do {
                        guard let self else { return }
                        let token = try await self.exchangeCodeForToken(
                            code: code,
                            clientId: clientId,
                            clientSecret: clientSecret,
                            redirectURI: self.redirectURI
                        )
                        AppLog.debug(.auth, "auth success")
                        continuation.resume(returning: token)
                    } catch {
                        AppLog.error(.auth, "auth token exchange failed \(error.localizedDescription)")
                        continuation.resume(throwing: error)
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.currentSession = session
            session.start()
        }
    }

    private func exchangeCodeForToken(
        code: String,
        clientId: String,
        clientSecret: String,
        redirectURI: String
    ) async throws -> String {
        let url = URL(string: "https://anilist.co/api/v2/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "code": code,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let payload = String(data: data, encoding: .utf8) ?? "no response body"
            AppLog.error(.auth, "auth token exchange http error \(payload)")
            throw AniListError.invalidResponse
        }
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = json as? [String: Any],
              let token = dict["access_token"] as? String else {
            AppLog.error(.auth, "auth token exchange parse failed")
            throw AniListError.invalidResponse
        }
        return token
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

