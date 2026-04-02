import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            DiscoveryView()
                .tabItem {
                    Image(systemName: "house")
                    Text("Home")
                }
                .tag(AppTab.home)
            LibraryView()
                .tabItem {
                    Image(systemName: "books.vertical")
                    Text("Library")
                }
                .tag(AppTab.library)
            DownloadsView()
                .tabItem {
                    Image(systemName: "arrow.down.circle")
                    Text("Downloads")
                }
                .tag(AppTab.downloads)
            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape")
                    Text("Settings")
                }
                .tag(AppTab.settings)
        }
        .environmentObject(appState)
        .environmentObject(appState.authState)
        .accentColor(Theme.accent)
        .background(Theme.baseBackground.ignoresSafeArea())
        .task {
            AppLog.debug(.ui, "root view task start")
            await appState.bootstrap()
            TrackingSyncService.shared.start(auth: appState.authState, client: appState.services.aniListClient)
            AppLog.debug(.ui, "root view task complete")
        }
    }
}
