import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        ZStack {
            Theme.backgroundGradient
                .ignoresSafeArea()
            mainContent
        }
        .safeAreaInset(edge: .bottom) {
            BottomNavigationBar(
                selection: $appState.selectedTab
            )
            .frame(height: UIConstants.bottomBarHeight)
        }
        .environmentObject(appState)
        .environmentObject(appState.authState)
        .accentColor(Theme.accent)
        .background(Theme.baseBackground.ignoresSafeArea())
        .task {
            AppLog.debug(.ui, "root view task start")
            TrackingSyncService.shared.start(auth: appState.authState, client: appState.services.aniListClient)
            AppLog.debug(.ui, "root view task complete")
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch appState.selectedTab {
        case .home:
            DiscoveryView()
        case .library:
            LibraryView()
        case .notifications:
            AlertsView()
        case .downloads:
            DownloadsView()
        case .settings:
            SettingsView()
        }
    }
}

private struct BottomNavigationBar: View {
    @Binding var selection: AppTab

    var body: some View {
        ZStack {
            Theme.baseBackground
                .ignoresSafeArea()
            HStack(spacing: UIConstants.interCardSpacing) {
                navItem(title: "Home", systemImage: "house", tab: .home)
                navItem(title: "Library", systemImage: "books.vertical", tab: .library)
                navItem(title: "Alerts", systemImage: "bell", tab: .notifications)
                navItem(title: "Downloads", systemImage: "arrow.down.circle", tab: .downloads)
                navItem(title: "Settings", systemImage: "gearshape", tab: .settings)
            }
            .padding(.horizontal, UIConstants.standardPadding)
            .padding(.vertical, UIConstants.standardPadding)
        }
    }

    private func navItem(title: String, systemImage: String, tab: AppTab) -> some View {
        let isSelected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: UIConstants.interCardSpacing) {
                Image(systemName: systemImage)
                Text(title)
            }
            .foregroundColor(isSelected ? Theme.accent : Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }
}
