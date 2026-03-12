import SwiftUI

struct NavigationShell: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isPadLayout: Bool {
        horizontalSizeClass == .regular
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
                ZStack(alignment: .bottom) {
                    contentView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    FloatingTabBar(selectedTab: $appState.selectedTab)
                        .padding(.bottom, 10)
                }
                .padding(.horizontal, 10)
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

private struct FloatingTabBar: View {
    @Binding var selectedTab: AppTab

    private let items: [NavigationItem] = AppTab.navigationItems

    var body: some View {
        HStack(spacing: 26) {
            ForEach(items) { item in
                Button {
                    selectedTab = item.tab
                } label: {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(selectedTab == item.tab ? Theme.accent : Theme.textSecondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.45))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 8)
    }
}

private struct NavigationItem: Identifiable {
    let id = UUID()
    let tab: AppTab
    let systemImage: String
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
