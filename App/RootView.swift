import SwiftUI

struct RootView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        NavigationShell()
        .environmentObject(appState)
        .environmentObject(appState.authState)
        .accentColor(Theme.accent)
        .background(Theme.baseBackground.ignoresSafeArea())
        .preferredColorScheme(appState.settings.appearanceThemeMode.colorScheme)
        .task {
            AppLog.debug(.ui, "root view task start")
            await appState.bootstrap()
            TrackingSyncService.shared.start(auth: appState.authState, client: appState.services.aniListClient)
            AppLog.debug(.ui, "root view task complete")
        }
    }
}

