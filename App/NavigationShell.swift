import SwiftUI
import UIKit

struct NavigationShell: View {
    @EnvironmentObject private var appState: AppState
    var body: some View {
        ZStack {
            Theme.backgroundGradient
                .ignoresSafeArea()

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
                AlertsView()
                    .tabItem {
                        Image(systemName: "bell")
                        Text("Alerts")
                    }
                    .tag(AppTab.notifications)
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
        }
    }
}

