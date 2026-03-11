import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            Theme.baseBackground.ignoresSafeArea()
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Settings")
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundColor(.white)

                        VStack(spacing: 12) {
                            GlassCard {
                                HStack(spacing: 12) {
                                    if let url = appState.authState.user?.avatarURL {
                                        AsyncImage(url: url) { image in
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
                                NavigationLink {
                                    LogsView()
                                } label: {
                                    HStack {
                                        Text("Logs")
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                    }
                                    .foregroundColor(.white)
                                }
                            }

                            GlassCard {
                                Button(action: {
                                    AppLog.debug(.cache, "settings clear cache tapped")
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
                        .frame(maxWidth: 750)
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 120)
                }
            }
        }
        .onAppear {
            AppLog.debug(.ui, "settings view appear")
        }
    }
}

