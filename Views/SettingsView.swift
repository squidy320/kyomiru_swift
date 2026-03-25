import SwiftUI
import UIKit

private enum SettingsTab: String, CaseIterable, Identifiable {
    case player
    case appearance
    case account
    case storage
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .player: return "Player"
        case .appearance: return "Appearance"
        case .account: return "Account"
        case .storage: return "Storage"
        case .advanced: return "Advanced"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    @State private var cacheSizeText: String = "--"
    @State private var selectedTab: SettingsTab = .player

    var body: some View {
        let horizontalPadding: CGFloat = appState.settings.useComfortableLayout ? 18 : 14
        let verticalSpacing: CGFloat = appState.settings.useComfortableLayout ? 14 : 10

        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: verticalSpacing) {
                        if !isPad {
                            Text("Settings")
                                .font(.system(size: 28, weight: .heavy))
                                .foregroundColor(.white)
                        }

                        settingsOverview

                        Picker("Settings Tab", selection: $selectedTab) {
                            ForEach(SettingsTab.allCases) { tab in
                                Text(tab.title).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)

                        currentTabContent
                    }
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .navigationTitle(isPad ? "Settings" : "")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: tabBarInset)
        }
        .onAppear {
            AppLog.debug(.ui, "settings view appear")
            Task { await refreshCacheSize() }
        }
    }

    @ViewBuilder
    private var currentTabContent: some View {
        switch selectedTab {
        case .player:
            playerTab
        case .appearance:
            appearanceTab
        case .account:
            accountTab
        case .storage:
            storageTab
        case .advanced:
            advancedTab
        }
    }

    private var settingsOverview: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Preferences")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Text("Playback defaults, appearance, sync, storage, and debug controls are grouped by category.")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                HStack(spacing: 8) {
                    settingsTag(appState.settings.playerBackend.title)
                    settingsTag("Audio \(appState.settings.defaultAudio)")
                    settingsTag("Quality \(appState.settings.defaultQuality)")
                    settingsTag(appState.settings.appearanceThemeMode.title)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var playerTab: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            SettingsSectionCard(title: "Streaming Defaults", subtitle: "Applied automatically when a matching source exists.") {
                Picker("Playback Engine", selection: Binding(
                    get: { appState.settings.playerBackend },
                    set: { appState.settings.playerBackend = $0 }
                )) {
                    ForEach(PlayerBackend.allCases) { backend in
                        Text(backend.title).tag(backend)
                    }
                }
                .pickerStyle(.segmented)

                Text(appState.settings.playerBackend.summary)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)

                settingsPickerRow(
                    title: "Default Audio",
                    selection: Binding(
                        get: { appState.settings.defaultAudio },
                        set: { appState.settings.defaultAudio = $0 }
                    ),
                    options: ["Sub", "Dub", "Any"]
                )
                settingsPickerRow(
                    title: "Default Quality",
                    selection: Binding(
                        get: { appState.settings.defaultQuality },
                        set: { appState.settings.defaultQuality = $0 }
                    ),
                    options: ["Auto", "1080p", "720p", "360p"]
                )
            }

            SettingsSectionCard(title: "Gesture Hold Speed", subtitle: "Long-press in the player temporarily uses this playback speed.") {
                Picker("Hold Speed", selection: Binding(
                    get: { appState.settings.playerHoldSpeed },
                    set: { appState.settings.playerHoldSpeed = $0 }
                )) {
                    ForEach(PlayerHoldSpeed.allCases) { speed in
                        Text(speed.title).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            SettingsSectionCard(title: "Theme", subtitle: "Controls the app color scheme.") {
                Picker("Theme", selection: Binding(
                    get: { appState.settings.appearanceThemeMode },
                    set: { appState.settings.appearanceThemeMode = $0 }
                )) {
                    ForEach(AppearanceThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            SettingsSectionCard(title: "Cards & Images", subtitle: "Choose the preferred image source for anime cards.") {
                Picker("Anime Card Images", selection: Binding(
                    get: { appState.settings.cardImageSource },
                    set: { appState.settings.cardImageSource = $0 }
                )) {
                    ForEach(CardImageSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
            }

            SettingsSectionCard(title: "Display", subtitle: "Practical UI preferences.") {
                Toggle("Reduce Motion", isOn: Binding(
                    get: { appState.settings.reduceMotion },
                    set: { appState.settings.reduceMotion = $0 }
                ))
                .foregroundColor(.white)

                Toggle("Comfortable Layout", isOn: Binding(
                    get: { appState.settings.useComfortableLayout },
                    set: { appState.settings.useComfortableLayout = $0 }
                ))
                .foregroundColor(.white)
            }
        }
    }

    private var accountTab: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            GlassCard {
                HStack(spacing: 12) {
                    if let url = appState.authState.user?.avatarURL {
                        CachedImage(
                            url: url,
                            targetSize: CGSize(width: 42, height: 42)
                        ) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.white.opacity(0.1)
                        }
                        .frame(width: 42, height: 42)
                        .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 42, height: 42)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .foregroundColor(.white)
                            )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.authState.isSignedIn ? "AniList Connected" : "AniList")
                            .foregroundColor(.white)
                        Text(appState.authState.user?.name ?? "Sign in to sync your library")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                    Button(appState.authState.isSignedIn ? "Sign Out" : "Sign In") {
                        Task {
                            if appState.authState.isSignedIn {
                                appState.authState.signOut()
                            } else {
                                await appState.authState.signIn()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            SettingsSectionCard(title: "Sync", subtitle: "Control account-backed library behavior.") {
                Toggle("Auto Sync AniList", isOn: Binding(
                    get: { appState.settings.autoSyncAniList },
                    set: { appState.settings.autoSyncAniList = $0 }
                ))
                .foregroundColor(.white)
            }
        }
    }

    private var storageTab: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            SettingsSectionCard(title: "Cache", subtitle: "Stored images and metadata.") {
                Button(action: {
                    AppLog.debug(.cache, "settings clear cache tapped")
                    Task {
                        await CacheService.shared.clearAll()
                        await refreshCacheSize()
                    }
                }) {
                    HStack {
                        Text("Clear Cache")
                        Text(cacheSizeText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                        Spacer()
                        Image(systemName: "trash")
                    }
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }

            SettingsSectionCard(title: "Downloads", subtitle: "Only removes downloaded media files.") {
                Button(action: {
                    AppLog.debug(.cache, "settings clear downloads tapped")
                    Task { await CacheService.shared.clearDownloadsOnly() }
                }) {
                    HStack {
                        Text("Clear Downloads Only")
                        Spacer()
                        Image(systemName: "folder.badge.minus")
                    }
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            SettingsSectionCard(title: "Player Diagnostics", subtitle: "Developer-facing playback helpers.") {
                Toggle("Show Player Debug Overlay", isOn: Binding(
                    get: { appState.settings.showPlayerDebugOverlay },
                    set: { appState.settings.showPlayerDebugOverlay = $0 }
                ))
                .foregroundColor(.white)
            }

            SettingsSectionCard(title: "Logs", subtitle: "Inspect runtime diagnostics and export a text log.") {
                NavigationLink {
                    LogsView()
                } label: {
                    HStack {
                        Text("Open Logs")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .foregroundColor(.white)
                }
            }
        }
    }

    private func settingsPickerRow(title: String, selection: Binding<String>, options: [String]) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.white)
            Spacer()
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
        }
    }

    private func settingsTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private var tabBarInset: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 12 : 80
    }

    private var sectionSpacing: CGFloat {
        appState.settings.useComfortableLayout ? 14 : 10
    }

    private func refreshCacheSize() async {
        let size = await CacheService.shared.cacheSizeString()
        await MainActor.run {
            cacheSizeText = size
        }
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
