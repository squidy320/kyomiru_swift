import SwiftUI

struct HeroPill: Identifiable, Hashable {
    let id = UUID()
    let icon: String?
    let text: String
}

struct HeroHeader: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    let pills: [HeroPill]
    let tags: [String]
    var height: CGFloat = 260

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Theme.surface)
                .frame(height: height)
                .overlay(
                    Group {
                        if let imageURL {
                            CachedImage(url: imageURL) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                Theme.surface
                            }
                        }
                    }
                )
                .clipped()

            LinearGradient(
                colors: [Color.black.opacity(0.85), Color.black.opacity(0.35), Color.clear],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: height * 0.75)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(pills) { pill in
                            MetadataPill(icon: pill.icon, text: pill.text)
                        }
                    }
                    if !tags.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(tags, id: \.self) { tag in
                                TagPill(text: tag)
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }
}

struct MetadataPill: View {
    let icon: String?
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

struct TagPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
    }
}
