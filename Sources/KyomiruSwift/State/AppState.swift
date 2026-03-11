import SwiftUI

enum AppTab: Hashable {
    case library
    case discovery
    case alerts
    case downloads
    case settings
}

final class AppState: ObservableObject {
    @Published var selectedTab: AppTab = .library
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
        AppLog.ui.debug("app bootstrap start")
        await authState.bootstrap()
        AppLog.ui.debug("app bootstrap complete")
    }
}
