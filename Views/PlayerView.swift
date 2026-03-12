import SwiftUI

struct PlayerView: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    let mediaId: Int
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = MPVPlayerModel()
    @State private var controlsVisible = true
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var autoHideTask: Task<Void, Never>?
    private let progressTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            MPVVideoView(player: player)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if !player.isReady {
                loadingOverlay
            }

            if controlsVisible {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .onAppear(perform: startPlayback)
        .onDisappear(perform: stopPlayback)
        .onReceive(progressTimer) { _ in
            syncProgress()
        }
        .onChange(of: player.isPlaying) { _, _ in
            scheduleAutoHide()
        }
        .alert("Playback Error", isPresented: Binding(
            get: { player.errorMessage != nil },
            set: { _ in player.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? "Unknown error")
        }
        .statusBar(hidden: true)
    }

    private var loadingOverlay: some View {
        Color.black.opacity(0.45).ignoresSafeArea()
            .overlay(
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("Loading player...")
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.75))
                )
            )
    }

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            centerControls
            Spacer()
            bottomBar
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.75), Color.black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 140)
                Spacer()
                LinearGradient(
                    colors: [Color.black.opacity(0), Color.black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 180)
            }
            .ignoresSafeArea()
        )
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Episode \(episode.number)")
                    .font(.system(size: 15, weight: .semibold))
                Text(episode.id)
                    .font(.system(size: 11))
                    .opacity(0.65)
            }

            Spacer()

            Menu {
                ForEach(speedOptions, id: \.self) { value in
                    Button("\(String(format: "%.2gx", value))") {
                        player.setRate(value)
                        showControls()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "speedometer")
                    Text("\(String(format: "%.2gx", player.rate))")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
            }
        }
    }

    private var centerControls: some View {
        HStack(spacing: 28) {
            Button {
                player.seekBy(-10)
                showControls()
            } label: {
                controlCircle(icon: "gobackward.10")
            }

            Button {
                player.togglePlay()
                showControls()
            } label: {
                controlCircle(icon: player.isPlaying ? "pause.fill" : "play.fill", size: 20)
            }

            Button {
                player.seekBy(10)
                showControls()
            } label: {
                controlCircle(icon: "goforward.10")
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : player.position },
                    set: { newValue in
                        scrubValue = newValue
                    }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        showControls()
                    } else {
                        player.seek(to: scrubValue)
                        showControls()
                    }
                }
            )

            HStack {
                Text(formatTime(isScrubbing ? scrubValue : player.position))
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.85)

                Spacer()

                Text(formatTime(player.duration))
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.85)
            }
        }
    }

    private var speedOptions: [Double] {
        [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    }

    private func controlCircle(icon: String, size: CGFloat = 18) -> some View {
        Image(systemName: icon)
            .font(.system(size: size, weight: .semibold))
            .frame(width: 54, height: 54)
            .background(Color.white.opacity(0.12))
            .clipShape(Circle())
    }

    private func startPlayback() {
        AppLog.debug(.player, "player appear episode=\(episode.id)")
        PlaybackHistoryStore.shared.saveLastEpisode(
            mediaId: mediaId,
            episodeId: episode.id,
            episodeNumber: episode.number
        )
        if let source = sources.first {
            let saved = PlaybackHistoryStore.shared.position(for: episode.id)
            player.load(url: source.url, headers: source.headers, startTime: saved)
        }
        scheduleAutoHide()
#if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
#endif
    }

    private func stopPlayback() {
        if player.position.isFinite {
            PlaybackHistoryStore.shared.save(position: player.position, for: episode.id)
        }
        if player.duration.isFinite {
            PlaybackHistoryStore.shared.saveDuration(player.duration, for: episode.id)
        }
        player.shutdown()
        AppLog.debug(.player, "player disappear episode=\(episode.id)")
#if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
#endif
    }

    private func syncProgress() {
        guard player.duration.isFinite, player.duration > 0 else { return }
        let current = player.position
        if current.isFinite {
            appState.services.playbackEngine.updateProgress(
                for: String(mediaId),
                currentTime: current,
                duration: player.duration
            )
            appState.services.playbackEngine.updateProgress(
                for: "episode:\(episode.id)",
                currentTime: current,
                duration: player.duration
            )
            PlaybackHistoryStore.shared.saveDuration(player.duration, for: episode.id)
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            controlsVisible.toggle()
        }
        scheduleAutoHide()
    }

    private func showControls() {
        if !controlsVisible {
            withAnimation(.easeInOut(duration: 0.2)) {
                controlsVisible = true
            }
        }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if player.isPlaying {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        controlsVisible = false
                    }
                }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(Int(seconds.rounded()), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
