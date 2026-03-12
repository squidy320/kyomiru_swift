import SwiftUI

enum AppTab: Hashable {
    case search
    case home
    case library
    case notifications
    case downloads
    case settings
}

final class AppState: ObservableObject {
    @Published var selectedTab: AppTab = .home
    @Published var settings = SettingsState()
    let services: AppServices
    @Published var authState: AuthState

    init() {
        let services = AppServices()
        self.services = services
        self.authState = AuthState(services: services)
    }

    @MainActor
    func bootstrap() async {
        AppLog.debug(.ui, "app bootstrap start")
        await authState.bootstrap()
        AppLog.debug(.ui, "app bootstrap complete")
    }
}

