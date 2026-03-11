import SwiftUI

struct RootView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }
                .tag(AppTab.library)

            DiscoveryView()
                .tabItem {
                    Label("Discovery", systemImage: "sparkles")
                }
                .tag(AppTab.discovery)

            AlertsView()
                .tabItem {
                    Label("Alerts", systemImage: "bell")
                }
                .tag(AppTab.alerts)

            DownloadsView()
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                .tag(AppTab.downloads)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(AppTab.settings)
        }
        .environmentObject(appState)
        .environmentObject(appState.authState)
        .accentColor(Theme.accent)
        .background(Theme.baseBackground.ignoresSafeArea())
        .task {
            AppLog.ui.debug("root view task start")
            TrackingSyncService.shared.start(auth: appState.authState, client: appState.services.aniListClient)
            AppLog.ui.debug("root view task complete")
        }
    }
}
