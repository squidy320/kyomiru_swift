import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Settings")
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundColor(.white)

                    VStack(spacing: 12) {
                        GlassCard {
                            HStack {
                                Text("Default Audio")
                                    .foregroundColor(.white)
                                Spacer()
                                Picker("", selection: $appState.settings.defaultAudio) {
                                    Text("Sub").tag("Sub")
                                    Text("Dub").tag("Dub")
                                    Text("Any").tag("Any")
                                }
                                .labelsHidden()
                            }
                        }

                        GlassCard {
                            HStack {
                                Text("Default Quality")
                                    .foregroundColor(.white)
                                Spacer()
                                Picker("", selection: $appState.settings.defaultQuality) {
                                    Text("Auto").tag("Auto")
                                    Text("1080p").tag("1080p")
                                    Text("720p").tag("720p")
                                    Text("360p").tag("360p")
                                }
                                .labelsHidden()
                            }
                        }

                        GlassCard {
                            Toggle("Auto Sync AniList", isOn: $appState.settings.autoSyncAniList)
                                .foregroundColor(.white)
                        }

                        GlassCard {
                            Toggle("OLED Black", isOn: $appState.settings.isOledBlack)
                                .foregroundColor(.white)
                        }

                        GlassCard {
                            Button(action: {
                                AppLog.cache.debug("settings clear cache tapped")
                                Task { await CacheService.shared.clearAll() }
                            }) {
                                HStack {
                                    Text("Clear Cache")
                                    Spacer()
                                    Image(systemName: "trash")
                                }
                                .foregroundColor(.white)
                            }
                            .buttonStyle(.plain)
                        }
                        GlassCard {
                            Button(action: {
                                AppLog.cache.debug("settings clear downloads tapped")
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
                    .frame(maxWidth: 750)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 120)
            }
        }
        .onAppear {
            AppLog.ui.debug("settings view appear")
        }
    }
}
