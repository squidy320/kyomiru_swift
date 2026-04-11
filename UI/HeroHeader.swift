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
    let media: AniListMedia?
    let pills: [HeroPill]
    let tags: [String]
    var height: CGFloat = 260
    @EnvironmentObject private var appState: AppState
    @State private var tmdbBackdropURL: URL?
    @State private var tmdbLookupComplete = false

    var body: some View {
        let useComfortableLayout = appState.settings.useComfortableLayout
        let contentSpacing: CGFloat = useComfortableLayout ? 10 : 8
        let contentPadding: CGFloat = useComfortableLayout ? 22 : 18
        let resolvedURL = tmdbBackdropURL ?? (tmdbLookupComplete ? imageURL : nil)
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Theme.surface)
                .frame(height: height)
                .overlay(
                    Group {
                        if let resolved = resolvedURL {
                            CachedImage(
                                url: resolved,
                                targetSize: CGSize(width: UIScreen.main.bounds.width, height: height)
                            ) { img in
                                img
                                    .resizable()
                                    .scaledToFill()
                                    .frame(height: height, alignment: .bottom)
                            } placeholder: {
                                Theme.surface
                            }
                        }
                    }
                )
                .clipped()

            LinearGradient(
                colors: [Color.black.opacity(0.9), Color.black.opacity(0.5), Color.clear],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: height * 0.75)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

            VStack(alignment: .leading, spacing: contentSpacing) {
                Text(title)
                    .font(.system(size: useComfortableLayout ? 26 : 24, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: useComfortableLayout ? 14 : 13, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }

                VStack(alignment: .leading, spacing: contentSpacing) {
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
            .padding(contentPadding)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .transaction { transaction in
            if appState.settings.reduceMotion {
                transaction.animation = nil
            }
        }
        .task(id: media?.id ?? 0) {
            guard let media else { return }
            tmdbLookupComplete = false
            tmdbBackdropURL = await appState.services.metadataService.backdropURL(for: media)
            tmdbLookupComplete = true
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
