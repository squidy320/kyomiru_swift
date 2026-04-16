import SwiftUI

struct RootView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        ZStack {
            NavigationShell()
                .environmentObject(appState)
                .environmentObject(appState.authState)
                .tint(appState.settings.accentColor)
                .background(Theme.baseBackground.ignoresSafeArea())
                .preferredColorScheme(appState.settings.appearanceThemeMode.colorScheme)
                .task {
                    AppLog.debug(.ui, "root view task start")
                    await appState.bootstrap()
                    TrackingSyncService.shared.start(auth: appState.authState, client: appState.services.aniListClient)
                    AppLog.debug(.ui, "root view task complete")
                }

            if appState.shouldShowLaunchScreen {
                LaunchLoadingView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
    }
}

private struct LaunchLoadingView: View {
    var body: some View {
        ZStack {
            Theme.baseBackground
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .tint(Theme.accent)
                    .scaleEffect(1.15)

                Text("Loading your discovery and library...")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
            }
            .padding(28)
        }
    }
}

