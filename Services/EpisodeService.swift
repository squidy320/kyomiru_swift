import Foundation

final class EpisodeService {
    private let runtime = SoraRuntime()

    func loadEpisodes(media: AniListMedia) async throws -> (SoraAnimeMatch, [SoraEpisode]) {
        AppLog.debug(.network, "episodes load start mediaId=\(media.id)")
        guard let match = try await runtime.autoMatch(media: media) else {
            AppLog.error(.network, "episodes auto match failed mediaId=\(media.id)")
            throw AniListError.invalidResponse
        }
        let episodes = try await runtime.episodes(for: match)
        let adjusted = applySeasonOffsetIfNeeded(episodes: episodes, media: media)
        AppLog.debug(.network, "episodes load success mediaId=\(media.id) count=\(adjusted.count)")
        return (match, adjusted)
    }

    func loadSources(for episode: SoraEpisode) async throws -> [SoraSource] {
        AppLog.debug(.network, "sources load start episode=\(episode.number)")
        let sources = try await runtime.sources(for: episode)
        AppLog.debug(.network, "sources load success count=\(sources.count)")
        return sources
    }

    private func applySeasonOffsetIfNeeded(episodes: [SoraEpisode], media: AniListMedia) -> [SoraEpisode] {
        guard let expected = media.episodes, expected > 0 else { return episodes }
        let season = TitleMatcher.extractSeasonNumber(from: media.title.best) ?? 1
        guard season > 1 else { return episodes }
        let minTotal = expected * season
        guard episodes.count >= minTotal else { return episodes }
        let offset = expected * (season - 1)
        let slice = Array(episodes.dropFirst(offset).prefix(expected))
        if slice.isEmpty { return episodes }
        AppLog.debug(.matching, "season offset applied mediaId=\(media.id) season=\(season) offset=\(offset)")
        return slice.enumerated().map { idx, ep in
            SoraEpisode(id: ep.id, number: idx + 1, playURL: ep.playURL)
        }
    }
}

