import SwiftUI

enum StreamSourcePreferenceResolver {
    static func audioKey(_ value: String) -> String {
        let normalized = value.lowercased()
        if normalized.contains("dub") || normalized.contains("eng") {
            return "dub"
        }
        return "sub"
    }

    static func normalizedAudioLabel(_ value: String) -> String {
        audioKey(value) == "dub" ? "Dub" : "Sub"
    }

    static func qualityRank(_ quality: String) -> Int {
        let digits = quality.filter { $0.isNumber }
        return Int(digits) ?? 0
    }

    static func sortedSources(_ sources: [SoraSource]) -> [SoraSource] {
        sources.sorted { lhs, rhs in
            let leftRank = qualityRank(lhs.quality)
            let rightRank = qualityRank(rhs.quality)
            if leftRank == rightRank {
                return lhs.subOrDub.localizedCaseInsensitiveCompare(rhs.subOrDub) == .orderedAscending
            }
            return leftRank > rightRank
        }
    }

    static func audioOptions(for sources: [SoraSource]) -> [String] {
        let options = Set(sources.map { normalizedAudioLabel($0.subOrDub) })
        return options.isEmpty ? ["Sub"] : Array(options).sorted()
    }

    static func qualityOptions(for sources: [SoraSource], selectedAudio: String) -> [String] {
        let key = audioKey(selectedAudio)
        let filtered = sources.filter { audioKey($0.subOrDub) == key }
        let pool = filtered.isEmpty ? sources : filtered
        var qualities = Set(pool.map { $0.quality.isEmpty ? "Auto" : $0.quality })
        qualities.insert("Auto")
        return qualities.sorted { lhs, rhs in
            if lhs == "Auto" { return true }
            if rhs == "Auto" { return false }
            return qualityRank(lhs) > qualityRank(rhs)
        }
    }

    static func filteredSources(
        from sources: [SoraSource],
        selectedAudio: String,
        selectedQuality: String
    ) -> [SoraSource] {
        let key = audioKey(selectedAudio)
        var filtered = sources.filter { audioKey($0.subOrDub) == key }
        if filtered.isEmpty {
            filtered = sources
        }
        if selectedQuality.lowercased() != "auto" {
            filtered = filtered.filter {
                !$0.quality.isEmpty && $0.quality.lowercased().contains(selectedQuality.lowercased())
            }
        }
        return sortedSources(filtered)
    }

    static func preferredSource(
        in sources: [SoraSource],
        preferredAudio: String,
        preferredQuality: String
    ) -> SoraSource? {
        let audioMatches = sources.filter { audioKey($0.subOrDub) == audioKey(preferredAudio) }
        guard !audioMatches.isEmpty else { return nil }
        if preferredQuality.lowercased() == "auto" {
            return sortedSources(audioMatches).first
        }
        return sortedSources(audioMatches).first {
            !$0.quality.isEmpty && $0.quality.lowercased().contains(preferredQuality.lowercased())
        }
    }
}

struct StreamSourcePickerSheet: View {
    let media: AniListMedia
    let episode: SoraEpisode?
    let sources: [SoraSource]
    let preferredAudio: String
    let preferredQuality: String
    let onPlay: (SoraSource) -> Void
    let onDownload: (SoraSource) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedAudio: String
    @State private var selectedQuality: String
    @State private var selectedSourceID: String?

    init(
        media: AniListMedia,
        episode: SoraEpisode?,
        sources: [SoraSource],
        preferredAudio: String,
        preferredQuality: String,
        onPlay: @escaping (SoraSource) -> Void,
        onDownload: @escaping (SoraSource) -> Void
    ) {
        self.media = media
        self.episode = episode
        self.sources = sources
        self.preferredAudio = preferredAudio
        self.preferredQuality = preferredQuality
        self.onPlay = onPlay
        self.onDownload = onDownload
        _selectedAudio = State(initialValue: preferredAudio)
        _selectedQuality = State(initialValue: preferredQuality)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Saved Preference") {
                    Picker("Audio", selection: $selectedAudio) {
                        ForEach(audioOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    Picker("Quality", selection: $selectedQuality) {
                        ForEach(qualityOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    if exactPreferredSource == nil {
                        Text("Your saved \(preferredAudio) / \(preferredQuality) preference is not available for this episode.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                Section("Sources") {
                    if filteredSources.isEmpty {
                        Text("No sources match these filters.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(filteredSources) { source in
                            Button {
                                selectedSourceID = source.id
                            } label: {
                                HStack(spacing: UIConstants.interCardSpacing) {
                                    VStack(alignment: .leading, spacing: UIConstants.tinyPadding) {
                                        Text("\(source.quality) - \(source.subOrDub)")
                                            .foregroundColor(.primary)
                                        Text(source.format.uppercased())
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if selectedSourceID == source.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.white)
                                    } else if exactPreferredSource?.id == source.id {
                                        Text("Preferred")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, UIConstants.tinyPadding)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Button("Play") {
                        guard let source = currentSource else { return }
                        dismiss()
                        onPlay(source)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(currentSource == nil)

                    if let source = currentSource,
                       source.format.lowercased() == "mp4" || source.format.lowercased() == "m3u8" {
                        Button("Download") {
                            onDownload(source)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Text("Download only for MP4/HLS")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("\(media.title.best) - Ep \(episode?.number ?? 0)")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear(perform: refreshSelection)
            .onChange(of: selectedAudio) { _, _ in
                refreshSelection()
            }
            .onChange(of: selectedQuality) { _, _ in
                refreshSelection()
            }
        }
    }

    private var audioOptions: [String] {
        StreamSourcePreferenceResolver.audioOptions(for: sources)
    }

    private var qualityOptions: [String] {
        StreamSourcePreferenceResolver.qualityOptions(for: sources, selectedAudio: selectedAudio)
    }

    private var filteredSources: [SoraSource] {
        StreamSourcePreferenceResolver.filteredSources(
            from: sources,
            selectedAudio: selectedAudio,
            selectedQuality: selectedQuality
        )
    }

    private var exactPreferredSource: SoraSource? {
        StreamSourcePreferenceResolver.preferredSource(
            in: sources,
            preferredAudio: preferredAudio,
            preferredQuality: preferredQuality
        )
    }

    private var currentSource: SoraSource? {
        if let selectedSourceID,
           let selected = filteredSources.first(where: { $0.id == selectedSourceID }) {
            return selected
        }
        return filteredSources.first
    }

    private func refreshSelection() {
        if !audioOptions.contains(selectedAudio) {
            selectedAudio = audioOptions.first ?? preferredAudio
            return
        }

        let validQualities = qualityOptions
        if !validQualities.contains(selectedQuality) {
            selectedQuality = validQualities.contains(preferredQuality) ? preferredQuality : (validQualities.first ?? "Auto")
            return
        }

        if let selectedSourceID,
           filteredSources.contains(where: { $0.id == selectedSourceID }) {
            return
        }

        if let exact = exactPreferredSource,
           filteredSources.contains(where: { $0.id == exact.id }) {
            selectedSourceID = exact.id
        } else {
            selectedSourceID = filteredSources.first?.id
        }
    }
}
