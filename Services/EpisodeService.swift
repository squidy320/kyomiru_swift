import Foundation

final class EpisodeService {
    private let runtime = SoraRuntime()
    private let matchStore = MatchStore.shared
    private let tmdbMatcher: TMDBMatchingService

    init(tmdbMatcher: TMDBMatchingService = TMDBMatchingService(cacheStore: CacheStore())) {
        self.tmdbMatcher = tmdbMatcher
    }

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
            do {
                let episodes = try await runtime.episodes(for: storedMatch)
                let adjusted = await applySeasonOffsetIfNeeded(episodes: episodes, media: media)
                if !adjusted.isEmpty {
                    AppLog.debug(.network, "episodes load success mediaId=\(media.id) count=\(adjusted.count)")
                    return MatchLoadResult(match: storedMatch, episodes: adjusted, isManual: stored.isManual)
                }

                AppLog.debug(.matching, "stored match yielded no episodes mediaId=\(media.id) session=\(storedMatch.session) manual=\(stored.isManual)")
                matchStore.clear(mediaId: media.id)
                return try await loadAutoMatchedEpisodes(media: media, replaceExisting: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.error(.network, "stored match episodes failed mediaId=\(media.id) session=\(storedMatch.session) \(error.localizedDescription)")
                if Task.isCancelled {
                    throw CancellationError()
                }
                matchStore.clear(mediaId: media.id)
                return try await loadAutoMatchedEpisodes(media: media, replaceExisting: false)
            }
        }

        return try await loadAutoMatchedEpisodes(media: media, replaceExisting: true)
    }

    private func loadAutoMatchedEpisodes(media: AniListMedia, replaceExisting: Bool) async throws -> MatchLoadResult {
        if replaceExisting == false {
            AppLog.debug(.matching, "stored match fallback to auto mediaId=\(media.id)")
        }

        guard let match = try await runtime.autoMatch(media: media) else {
            AppLog.error(.network, "episodes auto match failed mediaId=\(media.id)")
            throw AniListError.invalidResponse
        }
        matchStore.set(match: match, mediaId: media.id, isManual: false)
        let episodes: [SoraEpisode]
        do {
            episodes = try await runtime.episodes(for: match)
        } catch is CancellationError {
            throw CancellationError()
        }
        let adjusted = await applySeasonOffsetIfNeeded(episodes: episodes, media: media)
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

    private func applySeasonOffsetIfNeeded(episodes: [SoraEpisode], media: AniListMedia) async -> [SoraEpisode] {
        guard !episodes.isEmpty else { return episodes }

        let sorted = episodes.sorted { lhs, rhs in
            if lhs.sourceNumber == rhs.sourceNumber {
                return lhs.id < rhs.id
            }
            return lhs.sourceNumber < rhs.sourceNumber
        }
        let expected = media.episodes ?? 0
        let rawMin = sorted.first?.sourceNumber ?? 1
        let rawMax = sorted.last?.sourceNumber ?? rawMin
        let seasonMarker = TitleMatcher.extractSeasonMarkerNumber(from: media.title.best) ?? 1
        let hasPartMarker = TitleMatcher.extractPartMarkerNumber(from: media.title.best) != nil

        // Only use TMDB for season-local slicing. Absolute franchise offsets can hide
        // valid AnimePahe episode lists when the provider already points at a season page.
        let tmdbMatch = await withThrowingTaskGroup(of: TMDBSeasonMatch?.self) { group in
            group.addTask {
                await self.tmdbMatcher.matchShowAndSeason(media: media)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                return nil
            }
            return (try? await group.next()!) ?? nil
        }

        if let tmdbMatch, expected > 0 {
            let offset = tmdbMatch.episodeOffset
            let seasonStart = offset + 1
            let canApplySeasonSlice =
                seasonStart > 1 &&
                rawMin == 1 &&
                rawMax >= seasonStart &&
                sorted.count > offset

            if canApplySeasonSlice {
                let slice = Array(sorted.dropFirst(offset).prefix(expected))
                if !slice.isEmpty {
                    AppLog.debug(.matching, "TMDB season-local offset applied mediaId=\(media.id) season=\(tmdbMatch.seasonNumber) offset=\(offset) count=\(slice.count)")
                    return enumerateDisplayNumbers(slice)
                }
            } else if offset > 0 {
                AppLog.debug(.matching, "TMDB offset skipped for episode shaping mediaId=\(media.id) season=\(tmdbMatch.seasonNumber) offset=\(offset) min=\(rawMin) max=\(rawMax)")
            }
        }

        // Fallback to heuristic slicing if TMDB fails or offset is 0

        if expected > 0, seasonMarker > 1, rawMin == 1 {
            let offset = expected * (seasonMarker - 1)
            if sorted.count > offset {
                let slice = Array(sorted.dropFirst(offset).prefix(expected))
                if !slice.isEmpty {
                    AppLog.debug(.matching, "Heuristic season offset applied mediaId=\(media.id) season=\(seasonMarker) offset=\(offset)")
                    return enumerateDisplayNumbers(slice)
                }
            }
        }

        if expected > 0 {
            let needsRenumber = rawMin > 1 || rawMax > expected || hasPartMarker
            if needsRenumber {
                AppLog.debug(.matching, "episode renumber applied mediaId=\(media.id) min=\(rawMin) max=\(rawMax) expected=\(expected)")
                return enumerateDisplayNumbers(sorted)
            }
        } else if rawMin > 1 {
            return enumerateDisplayNumbers(sorted)
        }

        return sorted.map {
            SoraEpisode(id: $0.id, sourceNumber: $0.sourceNumber, displayNumber: $0.sourceNumber, playURL: $0.playURL)
        }
    }

    private func enumerateDisplayNumbers(_ episodes: [SoraEpisode]) -> [SoraEpisode] {
        episodes.enumerated().map { index, episode in
            SoraEpisode(
                id: episode.id,
                sourceNumber: episode.sourceNumber,
                displayNumber: index + 1,
                playURL: episode.playURL
            )
        }
    }
}
