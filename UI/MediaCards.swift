import SwiftUI

struct MediaPosterCard: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    let media: AniListMedia?
    let score: Int?
    let statusBadge: String?
    let cornerBadge: String?
    let size: CGSize?
    let overlayOpacity: Double
    let allowFallbackWhileLoading: Bool
    let enablesTMDBArtworkLookup: Bool
    @EnvironmentObject private var appState: AppState
    @State private var tmdbPosterURL: URL?
    @State private var tmdbLookupComplete = false

    init(
        title: String,
        subtitle: String?,
        imageURL: URL?,
        media: AniListMedia?,
        score: Int?,
        statusBadge: String?,
        cornerBadge: String?,
        size: CGSize? = nil,
        overlayOpacity: Double = 0.85,
        allowFallbackWhileLoading: Bool = false,
        enablesTMDBArtworkLookup: Bool = true
    ) {
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.media = media
        self.score = score
        self.statusBadge = statusBadge
        self.cornerBadge = cornerBadge
        self.size = size
        self.overlayOpacity = overlayOpacity
        self.allowFallbackWhileLoading = allowFallbackWhileLoading
        self.enablesTMDBArtworkLookup = enablesTMDBArtworkLookup
    }

    var body: some View {
        let useComfortableLayout = appState.settings.useComfortableLayout
        let cardWidth = size?.width ?? UIConstants.posterCardWidth
        let cardHeight = size?.height ?? UIConstants.posterCardHeight
        let rowPadding = UIConstants.rowPadding + (useComfortableLayout ? 2 : 0)
        let textSpacing = UIConstants.tinyPadding + (useComfortableLayout ? 1 : 0)
        let resolvedURL: URL? = {
            return imageURL
        }()
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.06))

                if let resolved = resolvedURL {
                    CachedImage(
                        url: resolved,
                        targetSize: CGSize(width: cardWidth, height: cardHeight)
                    ) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.white.opacity(0.08)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous))
                }

                LinearGradient(
                    colors: [Color.black.opacity(overlayOpacity), Color.clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(height: 120)

                VStack(alignment: .leading, spacing: textSpacing) {
                    Text(title)
                        .font(.system(size: useComfortableLayout ? 15 : 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: useComfortableLayout ? 13 : 12, weight: .regular))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .padding(rowPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous))

            RatingBadge(score: score)
                .padding(UIConstants.mediumPadding)

            if let statusBadge {
                Text(statusBadge)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.6))
                    )
                    .padding(.leading, UIConstants.mediumPadding)
                    .padding(.top, UIConstants.mediumPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let cornerBadge {
                Text(cornerBadge)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.blue.opacity(0.9))
                    )
                    .padding(.leading, UIConstants.mediumPadding)
                    .padding(.top, UIConstants.mediumPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous))
        .transaction { transaction in
            if appState.settings.reduceMotion {
                transaction.animation = nil
            }
        }
        .task(id: media?.id ?? 0) {
            guard media != nil else { return }
            tmdbPosterURL = nil
            tmdbLookupComplete = true
        }
    }
}

struct ContinueWatchingCard: View {
    let title: String
    let episodeText: String
    let progress: Double
    let timeRemainingText: String
    let imageURL: URL?
    let episodeBadge: String?
    let media: AniListMedia?
    let enablesTMDBArtworkLookup: Bool
    @EnvironmentObject private var appState: AppState
    @State private var tmdbImageURL: URL?
    @State private var tmdbLookupComplete = false

    var body: some View {
        let useComfortableLayout = appState.settings.useComfortableLayout
        let rowPadding = UIConstants.rowPadding + (useComfortableLayout ? 2 : 0)
        let cardWidth = UIConstants.continueCardWidth
        let cardHeight = UIConstants.continueCardHeight
        let resolvedURL: URL? = {
            return imageURL
        }()
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.06))

            if let resolved = resolvedURL {
                CachedImage(
                    url: resolved,
                    targetSize: CGSize(width: cardWidth, height: cardHeight)
                ) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipped()
            }

            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.18), Color.black.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: UIConstants.tinyPadding) {
                HStack(alignment: .top, spacing: UIConstants.smallPadding) {
                    VStack(alignment: .leading, spacing: UIConstants.microPadding) {
                        Text(title)
                            .font(.system(size: useComfortableLayout ? 15 : 14, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        Text(episodeText)
                            .font(.system(size: useComfortableLayout ? 13 : 12, weight: .regular))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 0)

                    if let episodeBadge {
                        Text(episodeBadge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, UIConstants.microPadding)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.black.opacity(0.42))
                            )
                    }
                }

                ProgressView(value: progress)
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)

                Text(timeRemainingText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(rowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: UIConstants.cornerRadiusLarge, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIConstants.cornerRadiusLarge, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(rowPadding)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        }
        .transaction { transaction in
            if appState.settings.reduceMotion {
                transaction.animation = nil
            }
        }
        .task(id: media?.id ?? 0) {
            guard media != nil else { return }
            tmdbImageURL = nil
            tmdbLookupComplete = true
        }
    }
}

struct EpisodeRowView: View {
    let episodeNumber: Int
    let title: String
    let ratingText: String?
    let description: String?
    let thumbnailURL: URL?
    let isPlayable: Bool
    let isWatched: Bool
    let isDownloaded: Bool
    let isNew: Bool
    let onTap: (() -> Void)?
    @EnvironmentObject private var appState: AppState
    @State private var isExpanded = false

    var body: some View {
        let useComfortableLayout = appState.settings.useComfortableLayout
        let isiPad = UIDevice.current.userInterfaceIdiom == .pad
        let thumbWidth = UIConstants.episodeThumbWidth + (useComfortableLayout ? 12 : 0)
        let thumbHeight = thumbWidth * 0.57
        let rowPadding = UIConstants.rowPadding + (useComfortableLayout ? 2 : 0)
        Button(action: {
            onTap?()
            isExpanded.toggle()
        }) {
            HStack(alignment: .top, spacing: UIConstants.interCardSpacing + (useComfortableLayout ? 2 : 0)) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: UIConstants.cornerRadiusSmall, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: thumbWidth, height: thumbHeight)
                    if let thumbnailURL {
                        CachedImage(
                            url: thumbnailURL,
                            targetSize: CGSize(width: thumbWidth, height: thumbHeight)
                        ) { img in
                            img.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.white.opacity(0.08)
                        }
                        .frame(width: thumbWidth, height: thumbHeight)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: UIConstants.cornerRadiusSmall, style: .continuous))
                    }
                    if isPlayable {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .padding(6)
                    }
                    if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                            .padding(6)
                    }
                    if isNew {
                        Text("NEW")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.blue.opacity(0.9))
                            )
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }

                VStack(alignment: .leading, spacing: UIConstants.tinyPadding) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("Episode \(episodeNumber)")
                            .font(.system(size: useComfortableLayout ? 13 : 12, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)

                        if !isiPad, let ratingText {
                            Text(ratingText)
                                .font(.system(size: useComfortableLayout ? 13 : 12, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                        if isiPad, let ratingText {
                            episodeRatingBadge(text: ratingText, comfortable: useComfortableLayout)
                        }
                    }
                    Text(title)
                        .font(.system(size: useComfortableLayout ? 15 : 14, weight: .semibold))
                        .foregroundColor(.white)
                        .opacity(isWatched ? 0.45 : 1.0)
                        .lineLimit(isExpanded ? 3 : 2)
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: useComfortableLayout ? 13 : 12))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(isExpanded ? 4 : 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(rowPadding)
            .background(
                RoundedRectangle(cornerRadius: UIConstants.cornerRadiusLarge, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .transaction { transaction in
            if appState.settings.reduceMotion {
                transaction.animation = nil
            }
        }
    }

    @ViewBuilder
    private func episodeRatingBadge(text: String, comfortable: Bool) -> some View {
        Text(text)
            .font(.system(size: comfortable ? 12 : 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, comfortable ? 10 : 8)
            .padding(.vertical, comfortable ? 6 : 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.45))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
    }
}

struct RelationsCarouselView: View {
    let sections: [AniListRelatedSection]

    var body: some View {
        let items = flattened()
        return AnyView(
            VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
                Text("Relations")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                if items.isEmpty {
                    Text("No related titles found.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, UIConstants.tinyPadding)
                        .padding(.vertical, UIConstants.smallPadding)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: UIConstants.interCardSpacing) {
                            ForEach(items, id: \.id) { item in
                                NavigationLink {
                                    DetailsView(media: item.media)
                                } label: {
                                    RelationCard(media: item.media, badge: item.badge)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, UIConstants.tinyPadding)
                        .padding(.vertical, UIConstants.heroTopPadding)
                    }
                    .scrollClipDisabled()
                }
            }
        )
    }

    private func flattened() -> [RelationItem] {
        sections.flatMap { section in
            let badge = relationLabel(section.title)
            return section.items.map { media in
                RelationItem(id: "\(section.id)-\(media.id)", media: media, badge: badge)
            }
        }
    }

    private func relationLabel(_ title: String) -> String {
        let lower = title.lowercased()
        if lower.contains("prequel") { return "Prequel" }
        if lower.contains("sequel") { return "Sequel" }
        if lower.contains("side") { return "Spin-off" }
        if lower.contains("alternative") { return "Alternative" }
        if lower.contains("adaptation") { return "Adaptation" }
        return title
    }
}

private struct RelationItem: Identifiable {
    let id: String
    let media: AniListMedia
    let badge: String
}

private struct RelationCard: View {
    let media: AniListMedia
    let badge: String

    var body: some View {
        let resolvedURL: URL? = media.coverURL
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.06))

            if let url = resolvedURL {
                CachedImage(
                    url: url,
                    targetSize: CGSize(width: UIConstants.posterCardWidth, height: UIConstants.posterCardHeight)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .clipShape(RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous))
                .clipped()
            }

            Text(badge)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.65))
                )
                .padding(8)
        }
        .frame(height: UIConstants.posterCardHeight)
        .aspectRatio(2 / 3, contentMode: .fit)
        .frame(maxWidth: UIConstants.posterCardWidth)
        .contentShape(Rectangle())
    }
}
