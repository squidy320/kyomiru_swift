import SwiftUI

struct MediaPosterCard: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    let score: Int?
    private let cardHeight: CGFloat = 220
    private let cardWidth: CGFloat = 150

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.06))

                if let imageURL {
                    CachedImage(url: imageURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.white.opacity(0.08)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                LinearGradient(
                    colors: [Color.black.opacity(0.85), Color.clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(height: 120)

                VStack(alignment: .leading, spacing: 6) {
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
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            RatingBadge(score: score)
                .padding(10)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct ContinueWatchingCard: View {
    let title: String
    let episodeText: String
    let progress: Double
    let timeRemainingText: String
    let imageURL: URL?
    let episodeBadge: String?
    private let cardWidth: CGFloat = 260
    private let cardHeight: CGFloat = 140

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))

            if let imageURL {
                CachedImage(url: imageURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            LinearGradient(
                colors: [Color.black.opacity(0.85), Color.clear],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
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
            .padding(12)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if let episodeBadge {
                Text(episodeBadge)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.6))
                    )
                    .padding(10)
            }
        }
    }
}
