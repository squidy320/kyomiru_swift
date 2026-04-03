import SwiftUI
import UIKit

private enum SettingsDestination: Hashable {
    case player
    case appearance
    case account
    case storage
    case advanced
}

private struct SettingsRowItem: Identifiable {
    let id: String
    let icon: String
    let iconColor: Color
    let title: String
    let value: String?
    let destination: SettingsDestination
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    private var isPad: Bool { PlatformSupport.prefersTabletLayout }
    @State private var cacheSizeText: String = "--"
    @State private var extensionRecords: [StreamingExtensionRecord] = []
    @State private var isRefreshingExtensions = false
    @State private var extensionStatusMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                settingsBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: sectionSpacing) {
                        settingsHeader

                        LunaSettingsSection(title: "Playback") {
                            ForEach(Array(playbackRows.enumerated()), id: \.element.id) { index, row in
                                NavigationLink(value: row.destination) {
                                    LunaSettingsRow(
                                        icon: row.icon,
                                        iconColor: row.iconColor,
                                        title: row.title,
                                        value: row.value
                                    )
                                }
                                .buttonStyle(.plain)

                                if index < playbackRows.count - 1 {
                                    LunaSettingsDivider()
                                }
                            }
                        }

                        LunaSettingsSection(title: "App") {
                            ForEach(Array(appRows.enumerated()), id: \.element.id) { index, row in
                                NavigationLink(value: row.destination) {
                                    LunaSettingsRow(
                                        icon: row.icon,
                                        iconColor: row.iconColor,
                                        title: row.title,
                                        value: row.value
                                    )
                                }
                                .buttonStyle(.plain)

                                if index < appRows.count - 1 {
                                    LunaSettingsDivider()
                                }
                            }
                        }

                        LunaSettingsSection(title: "Data") {
                            ForEach(Array(dataRows.enumerated()), id: \.element.id) { index, row in
                                NavigationLink(value: row.destination) {
                                    LunaSettingsRow(
                                        icon: row.icon,
                                        iconColor: row.iconColor,
                                        title: row.title,
                                        value: row.value
                                    )
                                }
                                .buttonStyle(.plain)

                                if index < dataRows.count - 1 {
                                    LunaSettingsDivider()
                                }
                            }
                        }

                        LunaSettingsSection(title: "Support") {
                            NavigationLink(value: SettingsDestination.advanced) {
                                LunaSettingsRow(
                                    icon: "wrench.and.screwdriver.fill",
                                    iconColor: .yellow,
                                    title: "Advanced",
                                    value: "Logs and diagnostics"
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        settingsFooter
                    }
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle(isPad ? "Settings" : "")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .player:
                    PlayerSettingsScreen(
                        extensionRecords: $extensionRecords,
                        isRefreshingExtensions: $isRefreshingExtensions,
                        onRefreshExtensions: { force in
                            await refreshExtensions(force: force)
                        },
                        onApplyExtensionUpdate: { provider in
                            await applyExtensionUpdate(for: provider)
                        }
                    )
                    .environmentObject(appState)
                case .appearance:
                    AppearanceSettingsScreen()
                        .environmentObject(appState)
                case .account:
                    AccountSettingsScreen()
                        .environmentObject(appState)
                case .storage:
                    StorageSettingsScreen(
                        cacheSizeText: cacheSizeText,
                        onRefreshCacheSize: {
                            await refreshCacheSize()
                        }
                    )
                    .environmentObject(appState)
                case .advanced:
                    AdvancedSettingsScreen()
                        .environmentObject(appState)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: tabBarInset)
        }
        .task {
            AppLog.debug(.ui, "settings view appear")
            await refreshCacheSize()
            await refreshExtensionsIfNeeded()
        }
        .alert("Streaming Extensions", isPresented: Binding(
            get: { extensionStatusMessage != nil },
            set: { _ in extensionStatusMessage = nil }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(extensionStatusMessage ?? "")
        }
    }

    private var horizontalPadding: CGFloat {
        appState.settings.useComfortableLayout ? 18 : 14
    }

    private var sectionSpacing: CGFloat {
        appState.settings.useComfortableLayout ? 18 : 14
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isPad {
                Text("Settings")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundColor(.white)
            }

            Text("Playback, account, storage, and app behavior in one place.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textSecondary)

            HStack(spacing: 8) {
                settingsTag(appState.settings.streamingProvider.title)
                settingsTag(appState.settings.playerBackend.title)
                settingsTag(appState.settings.appearanceThemeMode.title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsFooter: some View {
        Text("Kyomiru")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white.opacity(0.28))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
    }

    private var playbackRows: [SettingsRowItem] {
        [
            SettingsRowItem(
                id: "player",
                icon: "play.fill",
                iconColor: .white,
                title: "Player",
                value: "\(appState.settings.streamingProvider.title) / \(appState.settings.playerBackend.title)",
                destination: .player
            )
        ]
    }

    private var appRows: [SettingsRowItem] {
        [
            SettingsRowItem(
                id: "appearance",
                icon: "paintbrush.fill",
                iconColor: .purple,
                title: "Appearance",
                value: appState.settings.appearanceThemeMode.title,
                destination: .appearance
            ),
            SettingsRowItem(
                id: "account",
                icon: "person.crop.circle.fill",
                iconColor: .blue,
                title: "Account",
                value: appState.authState.user?.name ?? "Not connected",
                destination: .account
            )
        ]
    }

    private var dataRows: [SettingsRowItem] {
        [
            SettingsRowItem(
                id: "storage",
                icon: "internaldrive.fill",
                iconColor: .gray,
                title: "Storage",
                value: cacheSizeText,
                destination: .storage
            )
        ]
    }

    private var settingsBackground: some View {
        LinearGradient(
            colors: [
                Theme.surface.opacity(0.96),
                Theme.baseBackground,
                Theme.baseBackground
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.06),
                    Color.clear,
                    Color.black.opacity(0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
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
        PlatformSupport.prefersTabletLayout ? 12 : 80
    }

    private func refreshCacheSize() async {
        let size = await CacheService.shared.cacheSizeString()
        await MainActor.run {
            cacheSizeText = size
        }
    }

    private func refreshExtensionsIfNeeded() async {
        if extensionRecords.isEmpty {
            extensionRecords = appState.services.streamingExtensionManager.installedRecords()
        }
        extensionRecords = await appState.services.streamingExtensionManager.refreshAll(force: false)
    }

    private func refreshExtensions(force: Bool) async {
        isRefreshingExtensions = true
        extensionRecords = await appState.services.streamingExtensionManager.refreshAll(force: force)
        isRefreshingExtensions = false
    }

    private func applyExtensionUpdate(for provider: StreamingProvider) async {
        isRefreshingExtensions = true
        do {
            let updated = try await appState.services.streamingExtensionManager.update(provider: provider)
            extensionRecords = appState.services.streamingExtensionManager.installedRecords()
            extensionStatusMessage = "\(updated.provider.title) updated to \(updated.installedVersion)."
        } catch {
            extensionStatusMessage = "Failed to update \(provider.title)."
        }
        isRefreshingExtensions = false
    }
}

private struct PlayerSettingsScreen: View {
    @EnvironmentObject private var appState: AppState
    @Binding var extensionRecords: [StreamingExtensionRecord]
    @Binding var isRefreshingExtensions: Bool
    let onRefreshExtensions: (Bool) async -> Void
    let onApplyExtensionUpdate: (StreamingProvider) async -> Void

    var body: some View {
        SettingsDetailScroll(title: "Player") {
            LunaSettingsSection(title: "Streaming Defaults", subtitle: "Applied automatically when a matching source exists.") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Streaming Source", selection: Binding(
                        get: { appState.settings.streamingProvider },
                        set: { appState.settings.streamingProvider = $0 }
                    )) {
                        ForEach(StreamingProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(appState.settings.streamingProvider.summary)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)

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

                    Toggle("Auto-Skip Segments", isOn: Binding(
                        get: { appState.settings.autoSkipSegments },
                        set: { appState.settings.autoSkipSegments = $0 }
                    ))
                    .foregroundColor(.white)
                }
            }

            LunaSettingsSection(title: "Gesture Hold Speed", subtitle: "Long-press in the player temporarily uses this playback speed.") {
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

            LunaSettingsSection(title: "Extensions", subtitle: "Installed Luna source manifests and script updates.") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(isRefreshingExtensions ? "Checking for updates..." : "Installed Sources")
                            .foregroundColor(.white)
                        Spacer()
                        Button(isRefreshingExtensions ? "Checking..." : "Check Updates") {
                            Task { await onRefreshExtensions(true) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRefreshingExtensions)
                    }

                    ForEach(extensionRecords) { record in
                        StreamingExtensionCard(
                            record: record,
                            isRefreshingExtensions: isRefreshingExtensions,
                            isActive: appState.settings.streamingProvider == record.provider,
                            onApply: {
                                Task { await onApplyExtensionUpdate(record.provider) }
                            }
                        )
                    }
                }
            }
        }
    }
}

private struct AppearanceSettingsScreen: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsDetailScroll(title: "Appearance") {
            LunaSettingsSection(title: "Theme", subtitle: "Controls the app color scheme.") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Theme", selection: Binding(
                        get: { appState.settings.appearanceThemeMode },
                        set: { appState.settings.appearanceThemeMode = $0 }
                    )) {
                        ForEach(AppearanceThemeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    ColorPicker(
                        "Accent Color",
                        selection: Binding(
                            get: { appState.settings.accentColor },
                            set: { appState.settings.accentColor = $0 }
                        ),
                        supportsOpacity: false
                    )
                    .foregroundColor(.white)
                }
            }

            LunaSettingsSection(title: "Display", subtitle: "Practical UI preferences.") {
                VStack(alignment: .leading, spacing: 12) {
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
    }
}

private struct AccountSettingsScreen: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsDetailScroll(title: "Account") {
            LunaSettingsSection(title: "AniList") {
                accountCard
            }

            LunaSettingsSection(title: "Sync", subtitle: "Control account-backed library behavior.") {
                Toggle("Auto Sync AniList", isOn: Binding(
                    get: { appState.settings.autoSyncAniList },
                    set: { appState.settings.autoSyncAniList = $0 }
                ))
                .foregroundColor(.white)
            }
        }
    }

    private var accountCard: some View {
        HStack(spacing: 12) {
            if let url = appState.authState.user?.avatarURL {
                CachedImage(
                    url: url,
                    targetSize: CGSize(width: 48, height: 48)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.1)
                }
                .frame(width: 48, height: 48)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "person.fill")
                            .foregroundColor(.white)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(appState.authState.isSignedIn ? "AniList Connected" : "AniList")
                    .font(.system(size: 15, weight: .semibold))
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
}

private struct StorageSettingsScreen: View {
    @EnvironmentObject private var appState: AppState
    let cacheSizeText: String
    let onRefreshCacheSize: () async -> Void

    var body: some View {
        SettingsDetailScroll(title: "Storage") {
            LunaSettingsSection(title: "Cache", subtitle: "Stored images and metadata.") {
                Button {
                    AppLog.debug(.cache, "settings clear cache tapped")
                    Task {
                        await CacheService.shared.clearAll()
                        await onRefreshCacheSize()
                    }
                } label: {
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

            LunaSettingsSection(title: "Downloads", subtitle: "Only removes downloaded media files.") {
                Button {
                    AppLog.debug(.cache, "settings clear downloads tapped")
                    Task { await CacheService.shared.clearDownloadsOnly() }
                } label: {
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
}

private struct AdvancedSettingsScreen: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsDetailScroll(title: "Advanced") {
            LunaSettingsSection(title: "Player Diagnostics", subtitle: "Developer-facing playback helpers.") {
                Toggle("Show Player Debug Overlay", isOn: Binding(
                    get: { appState.settings.showPlayerDebugOverlay },
                    set: { appState.settings.showPlayerDebugOverlay = $0 }
                ))
                .foregroundColor(.white)
            }

            LunaSettingsSection(title: "Logs", subtitle: "Inspect runtime diagnostics and export a text log.") {
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
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SettingsDetailScroll<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Theme.surface.opacity(0.96),
                    Theme.baseBackground,
                    Theme.baseBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LunaSettingsSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .textCase(.uppercase)

            GlassCard(cornerRadius: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct LunaSettingsRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String?
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(iconColor.opacity(0.18))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(iconColor)
            }

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)

            Spacer()

            if let value {
                Text(value)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.28))
        }
        .contentShape(Rectangle())
        .platformHoverLift(reduceMotion: appState.settings.reduceMotion)
    }
}

private struct LunaSettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }
}

private struct StreamingExtensionCard: View {
    let record: StreamingExtensionRecord
    let isRefreshingExtensions: Bool
    let isActive: Bool
    let onApply: () -> Void
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(record.provider.title)
                            .foregroundColor(.white)
                        if isActive {
                            statusTag("Active")
                        }
                        if record.hasUpdate {
                            statusTag("Update")
                        }
                    }
                    Text("Installed \(record.installedVersion)" + (record.remoteVersion.map { " - Remote \($0)" } ?? ""))
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }

                Spacer()

                Button(record.hasUpdate ? "Update" : "Reinstall", action: onApply)
                    .buttonStyle(.bordered)
                    .disabled(isRefreshingExtensions)
            }

            Text(record.scriptURL.absoluteString)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .platformHoverLift(reduceMotion: appState.settings.reduceMotion)
    }

    private func statusTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.08)))
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
