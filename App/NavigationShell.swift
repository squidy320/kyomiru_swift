import SwiftUI
import UIKit

struct NavigationShell: View {
    @EnvironmentObject private var appState: AppState
    private var isPadLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        ZStack {
            Theme.backgroundGradient
                .ignoresSafeArea()

            if isPadLayout {
                HStack(spacing: 20) {
                    SidebarNavigation(selectedTab: $appState.selectedTab)
                        .padding(.leading, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 12)

                    contentView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.trailing, 18)
                        .padding(.vertical, 12)
                }
            } else {
                contentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top) {
                        TopNavigationBar(selectedTab: $appState.selectedTab)
                            .padding(.top, 8)
                            .padding(.horizontal, 14)
                    }
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch appState.selectedTab {
        case .search:
            SearchView()
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

private struct SidebarNavigation: View {
    @Binding var selectedTab: AppTab

    private let items: [NavigationItem] = AppTab.navigationItems

    var body: some View {
        VStack(spacing: 14) {
            ForEach(items) { item in
                Button {
                    selectedTab = item.tab
                } label: {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(selectedTab == item.tab ? Theme.accent : Theme.textSecondary)
                        .frame(width: 42, height: 42)
                        .background(
                            Circle()
                                .fill(selectedTab == item.tab ? Theme.accent.opacity(0.18) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 18)
        .frame(width: 70)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.black.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }
}

private struct NavigationItem: Identifiable {
    let id = UUID()
    let tab: AppTab
    let systemImage: String
}

private struct TopNavigationBar: View {
    @Binding var selectedTab: AppTab
    private let items: [NavigationItem] = AppTab.navigationItems

    var body: some View {
        HStack(spacing: 12) {
            ForEach(items) { item in
                Button {
                    selectedTab = item.tab
                } label: {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(selectedTab == item.tab ? Theme.accent : Theme.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(selectedTab == item.tab ? Theme.accent.opacity(0.18) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.5))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }
}

private extension AppTab {
    static var navigationItems: [NavigationItem] {
        [
            NavigationItem(tab: .search, systemImage: "magnifyingglass"),
            NavigationItem(tab: .home, systemImage: "house"),
            NavigationItem(tab: .library, systemImage: "books.vertical"),
            NavigationItem(tab: .notifications, systemImage: "bell"),
            NavigationItem(tab: .downloads, systemImage: "arrow.down.circle"),
            NavigationItem(tab: .settings, systemImage: "gearshape")
        ]
    }
}

