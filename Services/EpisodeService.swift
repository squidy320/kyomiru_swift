import Foundation

final class EpisodeService {
    private let runtime = SoraRuntime()
    private let matchStore = MatchStore.shared

    struct MatchLoadResult {
        let match: SoraAnimeMatch
        let episodes: [SoraEpisode]
        let isManual: Bool
    }

    func loadEpisodes(media: AniListMedia) async throws -> MatchLoadResult {
        AppLog.debug(.network, "episodes load start mediaId=\(media.id)")

        if let stored = matchStore.match(for: media.id),
           let storedMatch = stored.asSoraMatch() {
            AppLog.debug(.matching, "using stored match mediaId=\(media.id) session=\(storedMatch.session) manual=\(stored.isManual)")
            let episodes = try await runtime.episodes(for: storedMatch)
            let adjusted = applySeasonOffsetIfNeeded(episodes: episodes, media: media)
            AppLog.debug(.network, "episodes load success mediaId=\(media.id) count=\(adjusted.count)")
            return MatchLoadResult(match: storedMatch, episodes: adjusted, isManual: stored.isManual)
        }

        guard let match = try await runtime.autoMatch(media: media) else {
            AppLog.error(.network, "episodes auto match failed mediaId=\(media.id)")
            throw AniListError.invalidResponse
        }
        matchStore.set(match: match, mediaId: media.id, isManual: false)
        let episodes = try await runtime.episodes(for: match)
        let adjusted = applySeasonOffsetIfNeeded(episodes: episodes, media: media)
        AppLog.debug(.network, "episodes load success mediaId=\(media.id) count=\(adjusted.count)")
        return MatchLoadResult(match: match, episodes: adjusted, isManual: false)
    }

    func loadSources(for episode: SoraEpisode) async throws -> [SoraSource] {
        AppLog.debug(.network, "sources load start episode=\(episode.number)")
        let sources = try await runtime.sources(for: episode)
        AppLog.debug(.network, "sources load success count=\(sources.count)")
        return sources
    }

    func searchCandidates(media: AniListMedia) async throws -> [SoraAnimeMatch] {
        let queries = TitleMatcher.buildQueries(for: media)
        AppLog.debug(.matching, "manual match search start mediaId=\(media.id) queries=\(queries.count)")
        var all: [SoraAnimeMatch] = []
        for q in queries {
            let matches = try await runtime.searchAnime(query: q)
            all.append(contentsOf: matches)
        }
        let deduped = Dictionary(grouping: all, by: { $0.session })
            .compactMap { $0.value.first }
        AppLog.debug(.matching, "manual match search complete mediaId=\(media.id) candidates=\(deduped.count)")
        return deduped
    }

    func searchCandidates(query: String) async throws -> [SoraAnimeMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        AppLog.debug(.matching, "manual match search start query=\(trimmed)")
        let matches = try await runtime.searchAnime(query: trimmed)
        let deduped = Dictionary(grouping: matches, by: { $0.session })
            .compactMap { $0.value.first }
        AppLog.debug(.matching, "manual match search complete query=\(trimmed) candidates=\(deduped.count)")
        return deduped
    }

    func setManualMatch(media: AniListMedia, match: SoraAnimeMatch) {
        matchStore.set(match: match, mediaId: media.id, isManual: true)
    }

    func clearManualMatch(media: AniListMedia) {
        matchStore.clear(mediaId: media.id)
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
        return slice
    }
}
