import SwiftUI

struct MediaPosterCard: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    let media: AniListMedia?
    let score: Int?
    let isWatched: Bool
    @EnvironmentObject private var appState: AppState
    @State private var imdbPosterURL: URL?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.06))

                if let resolved = imdbPosterURL ?? imageURL {
                    CachedImage(url: resolved) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.white.opacity(0.08)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous))
                }

                LinearGradient(
                    colors: [Color.black.opacity(0.85), Color.clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(height: 120)

                VStack(alignment: .leading, spacing: UIConstants.tinyPadding) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .padding(UIConstants.rowPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: UIConstants.posterCardHeight)
            .clipShape(RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous))

            RatingBadge(score: score)
                .padding(UIConstants.mediumPadding)

            if isWatched {
                Text("Watched")
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
        }
        .frame(width: UIConstants.posterCardWidth, height: UIConstants.posterCardHeight)
        .clipShape(RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous))
        .task(id: media?.id) {
            guard let media else { return }
            imdbPosterURL = await appState.services.metadataService.posterURL(for: media)
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
    @EnvironmentObject private var appState: AppState
    @State private var imdbImageURL: URL?
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.06))

            if let resolved = imdbImageURL ?? imageURL {
                CachedImage(url: resolved) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous))
            }

            LinearGradient(
                colors: [Color.black.opacity(0.85), Color.clear],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: 90)
            .clipShape(RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: UIConstants.tinyPadding) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(episodeText)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Theme.textSecondary)

                ProgressView(value: progress)
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)

                Text(timeRemainingText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(UIConstants.rowPadding)
        }
        .frame(width: UIConstants.continueCardWidth, height: UIConstants.continueCardHeight)
        .clipShape(RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if let episodeBadge {
                Text(episodeBadge)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, UIConstants.microPadding)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.6))
                    )
                    .padding(UIConstants.mediumPadding)
            }
        }
        .task(id: media?.id) {
            guard let media else { return }
            imdbImageURL = await appState.services.metadataService.backdropURL(for: media)
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
    @State private var isExpanded = false

    var body: some View {
        Button(action: {
            onTap?()
            isExpanded.toggle()
        }) {
            HStack(alignment: .top, spacing: UIConstants.interCardSpacing) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: UIConstants.cornerRadiusSmall, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: UIConstants.episodeThumbWidth, height: UIConstants.episodeThumbHeight)
                    if let thumbnailURL {
                        CachedImage(url: thumbnailURL) { img in
                            img.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.white.opacity(0.08)
                        }
                        .frame(width: UIConstants.episodeThumbWidth, height: UIConstants.episodeThumbHeight)
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
                    HStack(spacing: 8) {
                        Text("Episode \(episodeNumber)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                        if let ratingText {
                            Text(ratingText)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .opacity(isWatched ? 0.45 : 1.0)
                        .lineLimit(isExpanded ? 3 : 2)
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(isExpanded ? 4 : 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(UIConstants.rowPadding)
            .background(
                RoundedRectangle(cornerRadius: UIConstants.cornerRadiusLarge, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }
}

struct RelationsCarouselView: View {
    let sections: [AniListRelatedSection]

    var body: some View {
        let items = flattened()
        if items.isEmpty { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: UIConstants.interCardSpacing) {
                Text("Relations")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
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
    @EnvironmentObject private var appState: AppState
    @State private var imdbPosterURL: URL?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.06))

            if let url = imdbPosterURL ?? media.coverURL {
                CachedImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .clipShape(RoundedRectangle(cornerRadius: UIConstants.cardCornerRadius, style: .continuous))
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
        .frame(width: UIConstants.posterCardWidth, height: UIConstants.posterCardWidth * 1.5)
        .task(id: media.id) {
            imdbPosterURL = await appState.services.metadataService.posterURL(for: media)
        }
    }
}
